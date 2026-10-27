import DioramaCore
import AppKit
import DioramaClient
import SwiftUI

/// "Connect to Claude": registers Diorama's MCP server with Claude Code and/or the Claude
/// desktop app in one click, and shows where it's registered.
struct MCPConnectPanel: View {
    @Environment(AppModel.self) private var model
    @State private var claudeCode = MCPInstaller.registration(in: MCPInstaller.claudeCodeConfig())
    @State private var desktop = MCPInstaller.registration(in: MCPInstaller.desktopConfig())
    @State private var readOnly = false
    @State private var busy = false
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect Diorama to Claude").font(.title3.bold())
                Text("Claude can then list your sessions, explain rewrites, write profiles, connect projects and run experiments for you. Runs that cost money always need your approval of the estimate.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ClientRow(
                icon: "terminal", name: "Claude Code", detail: "Terminal and the Code tab of the desktop app. New sessions pick it up.",
                registration: claudeCode, cliPath: model.cliPath, busy: busy,
                add: { Task { await run(["mcp", "install", "--claude-code"] + flags, done: "Added to Claude Code. Start a new session to use it.") } },
                remove: { Task { await run(["mcp", "uninstall", "--claude-code"], done: "Removed from Claude Code.") } })
            ClientRow(
                icon: "bubble.left.and.text.bubble.right", name: "Claude desktop chat", detail: "The desktop app's chat. Quit and reopen Claude afterwards.",
                registration: desktop, cliPath: model.cliPath, busy: busy,
                add: {
                    do {
                        try MCPInstaller.installDesktop(cli: model.cliPath, readOnly: readOnly)
                        finish("Added to the Claude desktop app. Quit and reopen Claude to load it.")
                    } catch { finish(String(describing: error), failed: true) }
                },
                remove: {
                    do {
                        try MCPInstaller.uninstallDesktop()
                        finish("Removed from the Claude desktop app. Restart Claude to unload it.")
                    } catch { finish(String(describing: error), failed: true) }
                })
            Toggle("Read-only: Claude can look, but not change or start anything", isOn: $readOnly).font(.callout)
            if let message {
                Label(message, systemImage: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(failed ? .orange : .green).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    var flags: [String] {
        var f = readOnly ? ["--read-only"] : []
        if let claude = model.settings.claudePath { f += ["--claude", claude] }
        return f
    }

    func refresh() {
        claudeCode = MCPInstaller.registration(in: MCPInstaller.claudeCodeConfig())
        desktop = MCPInstaller.registration(in: MCPInstaller.desktopConfig())
    }

    func finish(_ text: String, failed: Bool = false) {
        message = text
        self.failed = failed
        refresh()
    }

    /// Runs the bundled CLI (which finds and drives `claude mcp`).
    func run(_ args: [String], done: String) async {
        busy = true
        defer { busy = false }
        let cli = model.cliPath
        let (status, output) = await offloadBlocking { () -> (Int32, String) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cli)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do {
                try p.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                return (p.terminationStatus, String(decoding: data, as: UTF8.self))
            } catch {
                return (-1, "Couldn't run \(cli): \(error)")
            }
        }
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // The CLI prints the manual command when it can't find `claude`; show that as a problem.
        let ok = status == 0 && !text.contains("Couldn't find")
        finish(ok ? done : (text.isEmpty ? "Failed (exit \(status))." : text), failed: !ok)
    }
}

private struct ClientRow: View {
    let icon: String
    let name: String
    let detail: String
    let registration: MCPInstaller.Registration?
    let cliPath: String
    let busy: Bool
    let add: () -> Void
    let remove: () -> Void

    var status: (String, Color) {
        guard let r = registration else { return ("Not connected", .secondary) }
        if r.isStale || r.command != cliPath { return ("Connected to another copy of Diorama", .orange) }
        return (r.readOnly ? "Connected (read-only)" : "Connected", .green)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).frame(width: 26).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Label(status.0, systemImage: registration == nil ? "circle" : "checkmark.circle.fill")
                    .font(.caption.weight(.medium)).foregroundStyle(status.1)
                    .help(registration?.command ?? "")
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Button(registration == nil ? "Connect" : "Reconnect", action: add)
                    .buttonStyle(.borderedProminent).disabled(busy)
                if registration != nil {
                    Button("Disconnect", role: .destructive, action: remove).controlSize(.small).disabled(busy)
                }
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Sidebar entry point: one click opens the connect panel.
struct MCPConnectButton: View {
    @Environment(AppModel.self) private var model

    var connected: Bool {
        MCPInstaller.registration(in: MCPInstaller.claudeCodeConfig()) != nil || MCPInstaller.registration(in: MCPInstaller.desktopConfig()) != nil
    }

    var body: some View {
        @Bindable var model = model
        Button { model.showMCPConnect = true } label: {
            Label(connected ? "Connected to Claude" : "Connect to Claude…", systemImage: connected ? "sparkles" : "sparkles")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .foregroundStyle(connected ? Color.secondary : Color.accentColor)
        .help("Let Claude control Diorama (MCP)")
        .popover(isPresented: $model.showMCPConnect, arrowEdge: .trailing) { MCPConnectPanel().environment(model) }
    }
}
