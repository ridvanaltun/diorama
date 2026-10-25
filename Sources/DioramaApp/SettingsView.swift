import AppKit
import DioramaClient
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
                BudgetField(label: "Daily rewrite budget", value: $draft.dailyBudgetUSD)
                if let s = model.spend {
                    Text("Spent today: \(Fmt.money(s.todayUSD))" + (s.dailyBudgetUSD.map { " of \(Fmt.money($0))" } ?? "") + (s.isOverBudget ? " — used up; matching results pass through unchanged until tomorrow." : ". Covers interactive sessions, the playground and what-if; experiments use their own approved estimate."))
                        .font(.caption).foregroundStyle(s.isOverBudget ? .orange : .secondary)
                }
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
            SpendHistorySection()
            Section("Steering") {
                Toggle("Pause steering everywhere", isOn: Binding(
                    get: { model.settings.steeringPaused },
                    set: { on in Task { if let s = await model.perform({ try await $0.setSteeringPaused(on) }) { model.settings = s; draft.steeringPaused = s.steeringPaused } } }))
                Text("While paused, tool results reach Claude unchanged in every session: no AI rewrites or input changes. Redaction keeps working, and experiment runs aren't affected. Pause a single session from its header.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("App") {
                Toggle("Show Diorama in the menu bar", isOn: Binding(
                    get: { AppDelegate.menuBarEnabled },
                    set: {
                        UserDefaults.standard.set($0, forKey: AppDelegate.menuBarKey)
                        if !$0 { NSApp.setActivationPolicy(.regular) }
                    }))
                Text("With the menu bar icon, closing the window keeps Diorama running there. Without it, closing the window quits the app. Either way the daemon, and your routed sessions, keep running.")
                    .font(.caption).foregroundStyle(.secondary)
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
            NotificationSettingsSection()
            MCPSettingsSection()
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
            await model.refreshSessions()
            doctor = await model.perform { try await $0.doctor() }
        }
    }
}

/// Opens the "Connect to Claude" panel (MCP).
struct MCPSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            LabeledContent {
                Button("Connect to Claude…") { model.showMCPConnect = true }
            } label: {
                Text("Let Claude Code or the Claude desktop app inspect and control Diorama through MCP.")
            }
        } header: {
            Text("AI control (MCP)")
        }
    }
}

/// A dollar amount that may be empty (no limit).
struct BudgetField: View {
    let label: String
    @Binding var value: Double?
    @State private var text = ""

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                Text("$").foregroundStyle(.secondary)
                TextField(label, text: $text, prompt: Text("No limit")).labelsHidden().textFieldStyle(.roundedBorder).lineLimit(1).frame(width: 120).multilineTextAlignment(.trailing)
                    .onSubmit(commit)
                    .onChange(of: text) { commit() }
            }
        }
        // Follows outside changes (settings loading after the field appears) without fighting the user's typing.
        .onChange(of: value, initial: true) { if parsed != value { text = value.map { String(format: "%.2f", $0) } ?? "" } }
    }

    var parsed: Double? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        return t.isEmpty ? nil : Double(t).flatMap { $0 >= 0 ? $0 : nil }
    }

    func commit() {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { value = nil } else if let d = parsed { value = d }
    }
}

/// Which events notify (stored per user), plus a test button and the permission state.
struct NotificationSettingsSection: View {
    @AppStorage(NotificationPolicy.Prefs.runsKey) private var runs = true
    @AppStorage(NotificationPolicy.Prefs.budgetKey) private var budget = true
    @AppStorage(NotificationPolicy.Prefs.failuresKey) private var failures = true
    @AppStorage(NotificationPolicy.Prefs.reviewsKey) private var reviews = true
    @State private var denied = false

    var body: some View {
        Section {
            Toggle("An experiment run finishes", isOn: $runs)
            Toggle("The rewrite budget is used up", isOn: $budget)
            Toggle("Rewrites start failing in a session", isOn: $failures)
            Toggle("A rewrite is waiting for review", isOn: $reviews)
            HStack {
                Button("Send a test notification") {
                    Notifier.shared.post(.init(id: "test-\(Date().timeIntervalSince1970)", title: "Diorama notifications work",
                                               body: "You'll hear from Diorama here while it's in the background.", target: nil))
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        denied = await Notifier.shared.authorization() == .denied
                    }
                }
                .disabled(!Notifier.shared.isAvailable)
                Spacer()
            }
            if denied {
                Label("Notifications are turned off for Diorama in System Settings → Notifications.", systemImage: "bell.slash").font(.caption).foregroundStyle(.orange)
            }
            Text("Shown only while Diorama is in the background. Clicking one opens the run or session. Rewrite failures notify at most once per session every 10 minutes; the budget once a day.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Notifications")
        }
        .task { denied = await Notifier.shared.authorization() == .denied }
    }
}
