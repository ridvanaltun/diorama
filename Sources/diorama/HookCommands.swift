import ArgumentParser
import DioramaClient
import DioramaCore
import Foundation

/// Hook mode: Claude Code sessions Diorama can't route through its gateway (Claude desktop,
/// IDE extensions) report their tool results through Claude Code hooks instead.
struct Hook: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Use Diorama from Claude desktop and IDEs through Claude Code hooks.",
        discussion: """
            `diorama hook install` adds a hook to a project's .claude/settings.local.json. Every Claude Code \
            session in that folder, including the Claude desktop app's Code tab, then sends its tool results \
            to Diorama, which applies your profile or prompt and records each decision.

            Hook mode sees tool results only: no model requests, token usage or cache data, and no \
            pre-extraction (WebFetch pages). Use `diorama run` for full capture and for experiments.
            """,
        subcommands: [Install.self, Uninstall.self, List.self, Status.self, RunHook.self])

    struct ConfigOptions: ParsableArguments {
        @Option(help: "Profile (global rules) to apply, by name or id.") var profile: String?
        @Option(help: "Session-specific rewrite prompt.") var prompt: String?
        @Option(help: "Tools the session prompt applies to (comma-separated globs).") var promptTools: String = SessionPrompt.defaultTools.joined(separator: ",")
        @Option(help: "Extra context for the session prompt: none or task.") var promptContext: ContextMode = .none
        @Option(help: "Rewrite model for the session prompt.") var promptModel: String?
        @Option(help: "Block shell network tools (curl, wget, …) that could fetch a page around a rewrite: none or network.") var lockdown: LockdownPreset = .none

        var config: HookConfig {
            HookConfig(
                profile: profile,
                prompt: prompt.map { SessionPrompt(text: $0, tools: promptTools.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }, context: promptContext, model: promptModel) },
                lockdown: lockdown == .none ? nil : lockdown)
        }
    }

    struct Target: ParsableArguments {
        @Argument(help: "Project folder (default: the current folder).") var folder: String?
        @Flag(help: "Use ~/.claude/settings.json instead: every Claude Code session not started with `diorama run`.") var user = false

        var settingsURL: URL {
            user ? HookInstaller.userSettings() : HookInstaller.projectSettings(folder ?? FileManager.default.currentDirectoryPath)
        }
    }

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Install Diorama's hook for a project (or for every session with --user).",
            discussion: """
                Examples:
                  diorama hook install --profile "Web: subtle factual edit"
                  diorama hook install ~/code/app --prompt "Say the v1 API is deprecated" --prompt-tools WebFetch
                  diorama hook install --profile "Docs steer" --lockdown network   # also block curl, wget, …
                Run it again to change the configuration. Sessions already running keep the configuration they started with.
                """)
        @OptionGroup var global: GlobalOptions
        @OptionGroup var target: Target
        @OptionGroup var options: ConfigOptions

        func run() async throws {
            let config = options.config
            if let p = config.profile {
                let client = try await global.client()
                let profiles = try await client.profiles()
                guard profiles.contains(where: { $0.name == p || $0.id == p }) else { throw ValidationError("unknown profile '\(p)'") }
            }
            let command = try HookInstaller.command(cli: selfPath(), config: config)
            let url = try HookInstaller.install(command: command, settings: target.settingsURL, registry: HookRegistry(paths: global.paths))
            print("✓ Diorama hook installed in \(url.path)")
            if config.profile == nil && config.prompt == nil {
                print("  No profile or prompt: sessions are recorded but never changed. Re-run with --profile or --prompt to steer them.")
            }
            if target.user {
                print("  Every Claude Code session on this account now reports to Diorama (sessions started with `diorama run` are handled by the gateway instead).")
            }
            print("  New Claude Code sessions in this folder use it, in the terminal and in the Claude desktop app. Remove it with `diorama hook uninstall`.")
        }
    }

    struct Uninstall: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove Diorama's hook from a project (or from ~/.claude/settings.json with --user).",
            discussion: "`diorama hook uninstall --all` removes it from every project `diorama hook list` shows. Other settings and hooks stay as they are.")
        @OptionGroup var global: GlobalOptions
        @OptionGroup var target: Target
        @Flag(help: "Remove it from every connected project and from your user settings.") var all = false

        func validate() throws {
            if all, target.folder != nil || target.user { throw ValidationError("--all can't be combined with a folder or --user") }
        }

        func run() async throws {
            let registry = HookRegistry(paths: global.paths)
            if all {
                let (removed, failures) = HookInstaller.uninstallAll(registry: registry)
                for url in removed { print("✓ Removed Diorama's hook from \(url.path)") }
                for f in failures { eprint("✗ Could not change \(f)") }
                if removed.isEmpty && failures.isEmpty { print("No project has Diorama's hook.") }
                if !failures.isEmpty { throw ExitCode(1) }
                return
            }
            let url = target.settingsURL
            if try HookInstaller.uninstall(settings: url, registry: registry) {
                print("✓ Removed Diorama's hook from \(url.path)")
            } else {
                print("No Diorama hook in \(url.path)")
            }
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show whether a project (or your user settings) has Diorama's hook.")
        @OptionGroup var target: Target

        func run() async throws {
            let url = target.settingsURL
            guard let command = HookInstaller.installedCommand(settings: url) else {
                print("No Diorama hook in \(url.path)")
                return
            }
            print("Diorama hook installed in \(url.path)")
            print("  \(command)")
            let cli = HookInstaller.cliPath(in: command) ?? ""
            if !HookInstaller.installedEvents(settings: url).contains("PreToolUse") {
                print("  ⚠ Installed before input rules existed: run `diorama hook install` again to let them work here.")
            }
            if !FileManager.default.isExecutableFile(atPath: cli) {
                print("  ⚠ \(cli) doesn't exist any more (was Diorama moved?). Run `diorama hook install` again.")
            }
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the projects (and user settings) that have Diorama's hook.")
        @OptionGroup var global: GlobalOptions
        @Flag(help: "Print JSON.") var json = false

        func run() async throws {
            let projects = HookInstaller.connected(registry: HookRegistry(paths: global.paths))
            if json { return try printJSON(projects) }
            guard !projects.isEmpty else { return print("No project has Diorama's hook. Add one with `diorama hook install`.") }
            for p in projects {
                print("\(p.folder.map(abbreviatingHome) ?? "All sessions (~/.claude/settings.json)")  ·  \(p.config?.summary ?? "unknown configuration")")
                if p.cliMissing { print("  ⚠ Its diorama command no longer exists, so the hook does nothing. Install it again or remove it.") }
                if p.outdated { print("  ⚠ Installed before input rules existed: run `diorama hook install` there again.") }
            }
            print("\nRemove one with `diorama hook uninstall <folder>`, or all with `diorama hook uninstall --all`.")
        }
    }

    /// Called by Claude Code with one hook event on stdin. Never blocks the session: on any
    /// problem it prints nothing and exits 0, so the original tool result is used.
    struct RunHook: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "run", abstract: "Handle one hook event from Claude Code (used by the installed hook).", shouldDisplay: false)
        @OptionGroup var global: GlobalOptions
        @OptionGroup var options: ConfigOptions

        func run() async throws {
            let env = ProcessInfo.processInfo.environment
            let input = FileHandle.standardInput.readDataToEndOfFile()
            do {
                guard var event = try Self.event(from: input, config: options.config, client: env["CLAUDE_CODE_ENTRYPOINT"]) else { return }
                // Sessions started with `diorama run`: the gateway handles their results (acting here too would
                // rewrite twice); only tool inputs come through the hook.
                if let gateway = env["DIORAMA_SESSION"] {
                    guard event.event == "PreToolUse" else { return }
                    event.dioramaSessionId = gateway
                }
                let client = try await ControlClient.connect(paths: global.paths, autostart: true, timeout: 10)
                let reply = try await client.hook(event)
                if let output = reply.updatedToolOutput, event.event == "PostToolUse" {
                    print(#"{"hookSpecificOutput":{"hookEventName":"PostToolUse","updatedToolOutput":"# + output + "}}")
                }
                if let reason = reply.deny, event.event == "PreToolUse" {
                    let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": reason]]
                    if let data = try? JSONSerialization.data(withJSONObject: out, options: [.withoutEscapingSlashes]) { print(String(decoding: data, as: UTF8.self)) }
                    return
                }
                if let changed = reply.updatedInput, event.event == "PreToolUse",
                   let newInput = try? JSONSerialization.jsonObject(with: Data(changed.utf8)) {
                    // Always "ask": the user approves every call whose input Diorama changed.
                    let out: [String: Any] = ["hookSpecificOutput": [
                        "hookEventName": "PreToolUse", "permissionDecision": "ask", "updatedInput": newInput,
                        "permissionDecisionReason": "Diorama changed this call's input: \(reply.reason ?? "rewritten by a rule")",
                    ]]
                    if let data = try? JSONSerialization.data(withJSONObject: out, options: [.withoutEscapingSlashes]) { print(String(decoding: data, as: UTF8.self)) }
                }
            } catch {
                log("hook failed, tool result left unchanged: \(error)")
            }
        }

        static func event(from data: Data, config: HookConfig, client: String?) throws -> HookEvent? {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = obj["hook_event_name"] as? String, let sessionId = obj["session_id"] as? String
            else { return nil }
            func json(_ v: Any?) -> String? {
                guard let v, !(v is NSNull) else { return nil }
                return (try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed, .withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) }
            }
            return HookEvent(
                event: name, claudeSessionId: sessionId, cwd: obj["cwd"] as? String ?? FileManager.default.currentDirectoryPath,
                transcriptPath: obj["transcript_path"] as? String, client: client, toolName: obj["tool_name"] as? String,
                toolUseId: obj["tool_use_id"] as? String, toolInput: json(obj["tool_input"]), toolResponse: json(obj["tool_response"]), config: config)
        }

        func log(_ message: String) {
            let url = global.paths.logs.appendingPathComponent("hook.log")
            try? FileManager.default.createDirectory(at: global.paths.logs, withIntermediateDirectories: true)
            let line = Data("[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n".utf8)
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(line)
                try? h.close()
            } else {
                try? line.write(to: url)
            }
        }
    }
}

/// This executable's absolute path (what the installed hook runs).
func selfPath() -> String {
    Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
}
