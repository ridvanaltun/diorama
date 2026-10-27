import ArgumentParser
import DioramaClient
import DioramaCore
import Foundation

/// `diorama mcp`: lets an AI assistant (Claude Code, the Claude desktop app, any MCP client)
/// inspect and control Diorama through the Model Context Protocol.
struct MCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Let an AI assistant control Diorama (Model Context Protocol server).",
        discussion: """
            `diorama mcp install --claude-code` and/or `--claude-desktop` register the server. The assistant can then \
            list sessions and decisions, read audit records, manage profiles and hooks, and run experiments. Starting \
            an experiment run needs the confirmation token from its cost estimate, and your MCP client asks you \
            before each tool call it hasn't been allowed to make. Use --read-only to expose only the inspection tools.
            """,
        subcommands: [Serve.self, Install.self, Uninstall.self],
        defaultSubcommand: Serve.self)

    struct Serve: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Run the MCP server on stdio (what MCP clients launch).")
        @OptionGroup var global: GlobalOptions
        @Flag(help: "Expose only tools that read; nothing can be changed or started.") var readOnly = false

        func run() async throws {
            let paths = global.paths
            let server = MCPServer(cliPath: selfPath(), hookRegistry: HookRegistry(paths: paths), readOnly: readOnly) { try await ControlClient.connect(paths: paths, autostart: true) }
            await server.serve()
        }
    }

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Register Diorama's MCP server with Claude Code and/or the Claude desktop app.")
        @Flag(help: "Add it to Claude Code for your user (runs `claude mcp add --scope user`).") var claudeCode = false
        @Flag(help: "Add it to the Claude desktop app (claude_desktop_config.json); restart the app afterwards.") var claudeDesktop = false
        @Flag(help: "Expose only tools that read.") var readOnly = false
        @Option(help: "Path to the claude executable.") var claude: String?

        func run() async throws {
            guard claudeCode || claudeDesktop else { throw ValidationError("choose --claude-code, --claude-desktop, or both") }
            let cli = selfPath()
            if claudeDesktop {
                try MCPInstaller.installDesktop(cli: cli, readOnly: readOnly)
                print("✓ Added to the Claude desktop app (\(MCPInstaller.desktopConfig().path)). Quit and reopen Claude to load it.")
            }
            if claudeCode {
                let args = ["mcp", "add", "--scope", "user", MCPInstaller.serverName, "--", cli] + MCPInstaller.arguments(readOnly: readOnly)
                guard let claudePath = claude.map({ ($0 as NSString).expandingTildeInPath }) ?? findClaude(ProcessInfo.processInfo.environment) else {
                    print("Couldn't find `claude`. Run this yourself:\n  claude \(args.map(shellQuoted).joined(separator: " "))")
                    return
                }
                // Re-adding fails if it exists; remove first so the command also updates.
                _ = try? runProcess(claudePath, ["mcp", "remove", "--scope", "user", MCPInstaller.serverName])
                let (status, output) = try runProcess(claudePath, args)
                guard status == 0 else { throw ValidationError("`claude mcp add` failed: \(output)") }
                print("✓ Added to Claude Code for your user. New Claude Code sessions can use Diorama's tools (mcp__diorama__…).")
            }
        }
    }

    struct Uninstall: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove Diorama's MCP server from Claude Code and/or the Claude desktop app.")
        @Flag var claudeCode = false
        @Flag var claudeDesktop = false
        @Option(help: "Path to the claude executable.") var claude: String?

        func run() async throws {
            guard claudeCode || claudeDesktop else { throw ValidationError("choose --claude-code, --claude-desktop, or both") }
            if claudeDesktop {
                print(try MCPInstaller.uninstallDesktop() ? "✓ Removed from the Claude desktop app; restart it." : "Not registered in the Claude desktop app.")
            }
            if claudeCode {
                guard let claudePath = claude.map({ ($0 as NSString).expandingTildeInPath }) ?? findClaude(ProcessInfo.processInfo.environment) else {
                    print("Couldn't find `claude`. Run: claude mcp remove --scope user \(MCPInstaller.serverName)")
                    return
                }
                let (status, _) = try runProcess(claudePath, ["mcp", "remove", "--scope", "user", MCPInstaller.serverName])
                print(status == 0 ? "✓ Removed from Claude Code." : "Not registered in Claude Code.")
            }
        }
    }
}

func shellQuoted(_ s: String) -> String {
    s.allSatisfy { $0.isLetter || $0.isNumber || "-_./=".contains($0) } ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Runs a command and returns its exit status and combined output.
func runProcess(_ path: String, _ args: [String]) throws -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}
