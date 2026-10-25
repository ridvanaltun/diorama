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
        subcommands: [Install.self, Uninstall.self, Status.self, RunHook.self])

    struct ConfigOptions: ParsableArguments {
        @Option(help: "Profile (global rules) to apply, by name or id.") var profile: String?
        @Option(help: "Session-specific rewrite prompt.") var prompt: String?
        @Option(help: "Tools the session prompt applies to (comma-separated globs).") var promptTools: String = SessionPrompt.defaultTools.joined(separator: ",")
        @Option(help: "Extra context for the session prompt: none or task.") var promptContext: ContextMode = .none
        @Option(help: "Rewrite model for the session prompt.") var promptModel: String?

        var config: HookConfig {
            HookConfig(
                profile: profile,
                prompt: prompt.map { SessionPrompt(text: $0, tools: promptTools.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }, context: promptContext, model: promptModel) })
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
            let url = try HookInstaller.install(command: command, settings: target.settingsURL)
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
        static let configuration = CommandConfiguration(abstract: "Remove Diorama's hook from a project (or from ~/.claude/settings.json with --user).")
        @OptionGroup var target: Target

        func run() async throws {
            let url = target.settingsURL
            if try HookInstaller.uninstall(settings: url) {
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
            let cli = command.split(separator: " ").first.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'")) } ?? ""
            if !FileManager.default.isExecutableFile(atPath: cli) {
                print("  ⚠ \(cli) doesn't exist any more (was Diorama moved?). Run `diorama hook install` again.")
            }
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
            // Sessions started with `diorama run` are handled by the gateway; acting here too would rewrite twice.
            if env["DIORAMA_SESSION"] != nil { return }
            let input = FileHandle.standardInput.readDataToEndOfFile()
            do {
                guard let event = try Self.event(from: input, config: options.config, client: env["CLAUDE_CODE_ENTRYPOINT"]) else { return }
                let client = try await ControlClient.connect(paths: global.paths, autostart: true, timeout: 10)
                let reply = try await client.hook(event)
                if let output = reply.updatedToolOutput, event.event == "PostToolUse" {
                    print(#"{"hookSpecificOutput":{"hookEventName":"PostToolUse","updatedToolOutput":"# + output + "}}")
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
