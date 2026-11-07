import Foundation

/// Diorama's OpenCode plugin (hook mode for OpenCode): a small server plugin that hands every
/// tool result to `diorama hook run`, the command Claude Code's hooks run, and applies the
/// rewrite it returns. It works with every OpenCode provider, not only Anthropic, but sees no
/// model traffic.
///
/// A project install is `<project>/.opencode/plugins/diorama/index.ts`, a user install
/// `~/.config/opencode/plugins/diorama/index.ts`; OpenCode loads both automatically. The file
/// holds only the CLI path, the configuration id (D46) and where to write transcripts. Its first
/// line is the equivalent hook command, so `HookInstaller` reads its id and CLI the same way as a
/// Claude Code hook's.
///
/// OpenCode keeps no transcript file, so the plugin writes one per session in Claude Code's JSONL
/// shape (user and assistant lines with text and tool calls) and sends its path with every event,
/// as Claude Code's hooks do: impact labels, "what Claude did next", reports, task context and
/// experiment drafts then work as in Claude Code's hook mode.
public enum OpenCodePlugin {
    static let relativeFile = "plugins/diorama/index.ts"
    static let marker = "// Diorama hook plugin: "

    public static func projectFile(_ projectDir: String) -> URL {
        URL(fileURLWithPath: (projectDir as NSString).expandingTildeInPath, isDirectory: true)
            .appendingPathComponent(".opencode").appendingPathComponent(relativeFile)
    }

    public static func userFile(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let config = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? ((environment["HOME"] ?? NSHomeDirectory()) + "/.config")
        return URL(fileURLWithPath: config, isDirectory: true).appendingPathComponent("opencode").appendingPathComponent(relativeFile)
    }

    /// Whether `url` is where Diorama's OpenCode plugin lives (installed or not).
    public static func isPluginFile(_ url: URL) -> Bool { url.path.hasSuffix("/" + relativeFile) }

    /// `<project>/.opencode/plugins/diorama/index.ts` → `<project>`.
    static func projectFolder(of file: URL) -> String {
        var url = file
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.path
    }

    /// The hook command the plugin runs, as words.
    static func commandLine(cli: String, configId: String) -> String {
        "\(HookInstaller.shellQuote(cli)) hook run --config \(configId) --client opencode"
    }

    /// The installed plugin's hook command (from its first line), if the file is Diorama's.
    public static func installedCommand(file: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: file.path) else { return nil }
        let first = String(decoding: data.prefix(4096), as: UTF8.self).split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        guard first.hasPrefix(marker) else { return nil }
        return String(first.dropFirst(marker.count))
    }

    /// Where plugins write OpenCode transcripts, in Diorama's data folder.
    public static func transcriptsDirectory(home: URL) -> URL { home.appendingPathComponent("opencode-transcripts", isDirectory: true) }

    public static func write(cli: String, configId: String, lockdown: Bool, transcripts: URL, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(source(cli: cli, configId: configId, lockdown: lockdown, transcripts: transcripts).utf8).write(to: file, options: .atomic)
    }

    /// Rewrites an installed plugin with the current template (same CLI, id and lockdown), so
    /// plugins installed by earlier versions get new behavior. True when the file changed.
    @discardableResult
    public static func refresh(file: URL, configs: HookConfigStore, transcripts: URL) -> Bool {
        guard let command = installedCommand(file: file), let id = HookInstaller.configId(in: command),
              let cli = HookInstaller.cliPath(in: command), let config = configs.get(id),
              let current = FileManager.default.contents(atPath: file.path)
        else { return false }
        let fresh = source(cli: cli, configId: id, lockdown: (config.lockdown ?? .none) != .none, transcripts: transcripts)
        guard Data(fresh.utf8) != current else { return false }
        return (try? Data(fresh.utf8).write(to: file, options: .atomic)) != nil
    }

    /// Deletes the plugin file, and the folders installing it created when nothing else is in them
    /// (`diorama/`, `plugins/`, and a project's `.opencode/`). False when it wasn't installed.
    @discardableResult
    public static func remove(file: URL) throws -> Bool {
        guard installedCommand(file: file) != nil else { return false }
        try FileManager.default.removeItem(at: file)
        var dir = file.deletingLastPathComponent()
        for _ in 0..<3 {
            guard dir.lastPathComponent == "diorama" || dir.lastPathComponent == "plugins" || dir.lastPathComponent == ".opencode",
                  (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true,
                  (try? FileManager.default.removeItem(at: dir)) != nil
            else { break }
            dir.deleteLastPathComponent()
        }
        return true
    }

    /// The plugin's TypeScript. It never breaks a session: when the CLI is missing (Diorama moved
    /// or removed), fails or times out, the original result is used.
    static func source(cli: String, configId: String, lockdown: Bool, transcripts: URL) -> String {
        """
        \(marker)\(commandLine(cli: cli, configId: configId))
        // Installed by `diorama hook install --opencode`; remove it with `diorama hook uninstall --opencode`.
        // Each tool result goes to Diorama, which applies the profile or prompt of this configuration
        // (kept in Diorama's data folder) and records the decision.
        import { spawn, spawnSync } from "node:child_process"
        import { appendFileSync, existsSync, mkdirSync, writeFileSync } from "node:fs"
        import { join } from "node:path"

        const CLI = \(jsString(cli))
        const TRANSCRIPTS = \(jsString(transcripts.path))
        const ARGS = ["hook", "run", "--config", \(jsString(configId)), "--client", "opencode"]
        const LOCKDOWN = \(lockdown ? "true" : "false")
        const SHELL_TOOLS = new Set(["shell", "bash"])

        function diorama(payload: unknown): Promise<any> {
          if (!existsSync(CLI)) return Promise.resolve(undefined)
          return new Promise((resolve) => {
            let out = ""
            let done = false
            const finish = (value: any) => {
              if (done) return
              done = true
              clearTimeout(timer)
              resolve(value)
            }
            const child = spawn(CLI, ARGS, { stdio: ["pipe", "pipe", "ignore"] })
            const timer = setTimeout(() => {
              child.kill()
              finish(undefined)
            }, 175_000)
            child.stdout.on("data", (chunk) => (out += chunk))
            child.on("error", () => finish(undefined))
            child.on("close", () => {
              try {
                finish(out.trim() ? JSON.parse(out) : undefined)
              } catch {
                finish(undefined)
              }
            })
            child.stdin.on("error", () => {})
            child.stdin.end(JSON.stringify(payload))
          })
        }

        // Ends the Diorama sessions of OpenCode sessions this server saw, when it stops (a session that
        // reports again later is reopened). Synchronous: the server may exit right after cleanup.
        function endSessions(ids: Iterable<string>, cwd: string) {
          if (!existsSync(CLI)) return
          for (const id of ids) {
            try {
              spawnSync(CLI, ARGS, { input: JSON.stringify({ hook_event_name: "SessionEnd", session_id: id, cwd, transcript_path: transcriptPath(id) }), stdio: ["pipe", "ignore", "ignore"], timeout: 5_000 })
            } catch {}
          }
        }

        // The session's transcript, in Claude Code's JSONL shape, so Diorama can read the model's replies.
        const transcriptPath = (id: string) => join(TRANSCRIPTS, id.replace(/[^A-Za-z0-9_-]/g, "_") + ".jsonl")
        const stamp = (ms: unknown) => new Date(typeof ms === "number" ? ms : Date.now()).toISOString()

        // One message as transcript lines. Like Claude Code's, tool results follow as a user line
        // (without their content), which separates one response from the next.
        function transcriptLines(m: any): object[] {
          if (m?.type === "user" && typeof m.text === "string") {
            return [{ type: "user", timestamp: stamp(m.time?.created), message: { role: "user", content: m.text } }]
          }
          if (m?.type !== "assistant" || !Array.isArray(m.content)) return []
          const tools = m.content.filter((c: any) => c?.type === "tool")
          const content = m.content.flatMap((c: any) =>
            c?.type === "text" && typeof c.text === "string" ? [{ type: "text", text: c.text }]
            : c?.type === "tool" ? [{ type: "tool_use", id: c.id, name: c.name, input: c.state?.input ?? {} }]
            : [])
          if (!content.length) return []
          const lines: object[] = [{ type: "assistant", timestamp: stamp(m.time?.created), message: { role: "assistant", content } }]
          if (tools.length) {
            const done = Math.max(...tools.map((c: any) => c.time?.completed ?? m.time?.completed ?? m.time?.created ?? 0))
            lines.push({ type: "user", timestamp: stamp(done || undefined), message: { role: "user", content: tools.map((c: any) => ({ type: "tool_result", tool_use_id: c.id, content: "" })) } })
          }
          return lines
        }

        // Lines are appended as events arrive (synchronously, so nothing is lost when OpenCode exits
        // right after a turn); when a turn ends the whole file is rewritten from the session's messages.
        // `diorama run --agent opencode`: the gateway sees everything, so the plugin keeps no transcript.
        const ROUTED = !!process.env.DIORAMA_SESSION

        function appendTranscript(id: string, line: object) {
          if (ROUTED) return
          try {
            mkdirSync(TRANSCRIPTS, { recursive: true, mode: 0o700 })
            appendFileSync(transcriptPath(id), JSON.stringify(line) + "\\n", { mode: 0o600 })
          } catch {}
        }

        async function writeTranscript(ctx: any, id: string) {
          if (ROUTED) return
          try {
            const messages = await ctx.session.context({ sessionID: id })
            const lines = (Array.isArray(messages) ? messages : []).flatMap(transcriptLines).map((l: object) => JSON.stringify(l) + "\\n")
            mkdirSync(TRANSCRIPTS, { recursive: true, mode: 0o700 })
            writeFileSync(transcriptPath(id), lines.join(""), { mode: 0o600 })
          } catch {}
        }

        export default {
          id: "diorama",
          async setup(ctx: any) {
            const cwd = ctx.location?.directory ?? process.cwd()
            const seen = new Set<string>()
            const controller = new AbortController()
            void (async () => {
              try {
                const types = ["session.deleted", "session.archived", "session.text.ended",
                               "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted"]
                for await (const ev of ctx.event.subscribe({ types, signal: controller.signal })) {
                  // Some OpenCode versions ignore `types` and deliver every event: check the type here.
                  const id = ev?.data?.sessionID ?? ev?.durable?.aggregateID
                  if (typeof id !== "string" || !seen.has(id) || !types.includes(ev?.type)) continue
                  if (ev.type === "session.text.ended") {
                    if (typeof ev.data?.text === "string" && ev.data.text) {
                      appendTranscript(id, { type: "assistant", timestamp: stamp(ev.created), message: { role: "assistant", content: [{ type: "text", text: ev.data.text }] } })
                    }
                  } else if (ev.type.startsWith("session.execution.")) {
                    await writeTranscript(ctx, id)
                  } else {
                    // Deleted or archived (`opencode run` archives its session when done): complete the
                    // transcript while the messages can still be read, then end the Diorama session.
                    seen.delete(id)
                    await writeTranscript(ctx, id)
                    endSessions([id], cwd)
                  }
                }
              } catch {}
            })()
            // The prompt goes in right away, so the session's task is known from its first tool result.
            await ctx.session.hook("prompt", (e: any) => {
              if (typeof e?.sessionID !== "string" || typeof e?.prompt?.text !== "string") return
              seen.add(e.sessionID)
              appendTranscript(e.sessionID, { type: "user", timestamp: stamp(undefined), message: { role: "user", content: e.prompt.text } })
            })
            const event = (name: string, e: any, extra: object) => ({
              hook_event_name: name,
              session_id: e.sessionID,
              cwd,
              transcript_path: transcriptPath(e.sessionID),
              tool_name: e.tool,
              tool_use_id: e.id,
              tool_input: e.input,
              ...extra,
            })
            await ctx.tool.hook("execute.before", async (e: any) => {
              if (typeof e.sessionID !== "string") return
              seen.add(e.sessionID)
              appendTranscript(e.sessionID, { type: "assistant", timestamp: stamp(undefined), message: { role: "assistant", content: [{ type: "tool_use", id: e.id, name: e.tool, input: e.input ?? {} }] } })
              if (!LOCKDOWN || !SHELL_TOOLS.has(e.tool)) return
              const out = (await diorama(event("PreToolUse", e, {})))?.hookSpecificOutput
              if (out?.permissionDecision === "deny") throw new Error(out.permissionDecisionReason ?? "Blocked by Diorama")
            })
            await ctx.tool.hook("execute.after", async (e: any) => {
              if (typeof e.sessionID === "string") seen.add(e.sessionID)
              if (e.status === "completed") {
                const updated = (await diorama(event("PostToolUse", e, { tool_response: e.result })))?.hookSpecificOutput?.updatedToolOutput
                if (updated && typeof updated === "object") e.result = updated
              }
              if (typeof e.sessionID === "string") {
                appendTranscript(e.sessionID, { type: "user", timestamp: stamp(undefined), message: { role: "user", content: [{ type: "tool_result", tool_use_id: e.id, content: "" }] } })
              }
            })
            // When OpenCode waits for cleanup, the transcripts are completed first (a one-shot
            // `opencode run` can exit before the last turn's events arrive).
            return async () => {
              controller.abort()
              for (const id of seen) await writeTranscript(ctx, id)
              endSessions(seen, cwd)
            }
          },
        }

        """
    }

    static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}
