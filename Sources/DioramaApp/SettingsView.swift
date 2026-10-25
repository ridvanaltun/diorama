import AppKit
import DioramaCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var keyInput = ""
    @State private var draft = DioramaSettings()
    @State private var doctor: DoctorReport?
    @State private var maintenance: String?

    var body: some View {
        Form {
            Section("Rewrite agent API key") {
                if let k = model.keyStatus {
                    Label(k.configured ? "Configured — \(k.source ?? "unknown source")\(k.hint.map { " · \($0)" } ?? "")" : "Not configured — rewrites will fail and the original is forwarded", systemImage: k.configured ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(k.configured ? .green : .orange)
                }
                SecureField("Anthropic API key (sk-ant-…)", text: $keyInput)
                HStack {
                    Button("Save to Keychain") {
                        Task {
                            if let s = await model.perform({ try await $0.setKey(keyInput) }) { model.keyStatus = s }
                            keyInput = ""
                        }
                    }
                    .disabled(keyInput.isEmpty)
                    Button("Remove", role: .destructive) {
                        Task { if let s = await model.perform({ try await $0.deleteKey() }) { model.keyStatus = s } }
                    }
                    .disabled(model.keyStatus?.source?.hasPrefix("environment") ?? true)
                }
                Text("Used only for rewrite-agent calls, billed to this key. Diorama never reuses Claude Code's own sign-in.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Defaults") {
                TextField("Default rewrite model", text: $draft.defaultModel)
                Stepper("Keep raw request/response capture for \(draft.retentionDays) days", value: $draft.retentionDays, in: 1...3650)
                Toggle("Capture raw request and response bodies", isOn: $draft.captureRawBodies)
                TextField("Ollama URL (for ollama: models)", text: $draft.ollamaURL)
                TextField("claude executable (blank = auto-detect)", text: Binding(get: { draft.claudePath ?? "" }, set: { draft.claudePath = $0.isEmpty ? nil : $0 }))
                HStack {
                    Button("Save settings") { Task { if let s = await model.perform({ try await $0.saveSettings(draft) }) { model.settings = s } } }
                        .disabled(draft == model.settings)
                    Button("Apply retention now") {
                        Task {
                            if let r = await model.perform({ try await $0.applyRetention() }) {
                                maintenance = "Cleared \(r.exchangesCleared) old captures, removed \(r.blobsRemoved) blobs; storage \(ByteCountFormatter.string(fromByteCount: r.blobBytes, countStyle: .file))."
                            }
                        }
                    }
                }
                if let m = maintenance { Text(m).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Updates") {
                Toggle("Check for updates daily", isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: "autoUpdateCheck") as? Bool ?? true },
                    set: { UserDefaults.standard.set($0, forKey: "autoUpdateCheck") }))
                HStack {
                    Button("Check now") { Task { await model.checkForUpdates(force: true) } }
                    if let u = model.update {
                        Text(u.isNewer ? "Diorama \(u.latest) is available" : "Up to date (\(u.current))").foregroundStyle(u.isNewer ? .blue : .secondary)
                        if u.isNewer, let url = URL(string: u.pageURL) { Link("Open release", destination: url) }
                    } else if let e = model.updateError {
                        Text(e).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Updates are downloaded manually; Diorama never replaces itself. `diorama update --download` fetches and verifies the zip.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Command-line tool") {
                Text("Link the bundled `diorama` command into your PATH (asks for your password):").font(.callout)
                CommandLineInstall()
                Text("Then run `diorama run` in any project folder to start a routed Claude Code session.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Data") {
                LabeledContent("Data folder") {
                    HStack {
                        Text(Fmt.shortPath(DioramaPaths.default().home.path)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([DioramaPaths.default().home]) }
                    }
                }
                Text("Sessions, decisions, experiment runs and captured bodies live here. API keys are in the Keychain, not in this folder.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Diagnostics") {
                if let d = doctor {
                    ForEach(d.checks, id: \.self) { c in
                        Label {
                            VStack(alignment: .leading) {
                                Text(c.name).bold()
                                Text(c.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        } icon: {
                            Image(systemName: c.status == .ok ? "checkmark.circle.fill" : c.status == .warning ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(c.status == .ok ? .green : c.status == .warning ? .orange : .red)
                        }
                    }
                }
                Button("Run diagnostics") { Task { doctor = await model.perform { try await $0.doctor() } } }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task {
            await model.refreshSettings()
            draft = model.settings
            doctor = await model.perform { try await $0.doctor() }
        }
    }
}
