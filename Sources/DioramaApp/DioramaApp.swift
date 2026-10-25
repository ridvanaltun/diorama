import AppKit
import DioramaCore
import SwiftUI

@main
struct DioramaApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @AppStorage(AppDelegate.menuBarKey) private var showMenuBar = true

    var body: some Scene {
        Window("Diorama", id: AppDelegate.mainWindowId) {
            RootView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 640)
                .task {
                    await model.connectIfNeeded()
                    await model.checkForUpdates()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Session") {
                Button("Refresh") { Task { await model.refreshAll() } }.keyboardShortcut("r")
            }
        }
        Settings {
            SettingsView().environment(model).frame(width: 560, height: 520)
        }
        // Snapshot mode renders windows only; no status item there. It shares the user's
        // defaults, so it must not write the hidden state back to the preference.
        MenuBarExtra(isInserted: Binding(get: { showMenuBar && model.snapshotDir == nil }, set: { if model.snapshotDir == nil { showMenuBar = $0 } })) {
            MenuBarPanel().environment(model)
        } label: {
            Image(nsImage: MenuBarIcon.image(active: model.sessions.contains { $0.status == .active }))
                .task { await model.connectIfNeeded() }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let mainWindowId = "main"
    static let menuBarKey = "showMenuBarIcon"
    static var menuBarEnabled: Bool { UserDefaults.standard.object(forKey: menuBarKey) as? Bool ?? true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A SwiftPM-built executable starts as a background app; make it a regular app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            let closing = note.object as? NSWindow
            MainActor.assumeIsolated { Self.windowWillClose(closing) }
        }
        // However a window comes back (menu bar, reopening the app from Finder), the Dock icon
        // comes back with it.
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                if window?.canBecomeMain == true, NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
            }
        }
    }

    /// With the menu bar icon on, closing the last window keeps Diorama running there and
    /// hides it from the Dock; without it, closing the window quits as before.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !Self.menuBarEnabled }

    @MainActor
    static func windowWillClose(_ closing: NSWindow?) {
        guard menuBarEnabled, ProcessInfo.processInfo.environment["DIORAMA_SNAPSHOT_DIR"] == nil else { return }
        let others = NSApp.windows.filter { $0 !== closing && $0.isVisible && $0.canBecomeMain }
        if others.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }

    /// Brings the main window back (and the Dock icon with it).
    @MainActor
    static func showMainWindow(_ openWindow: OpenWindowAction) {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: mainWindowId)
        NSApp.activate()
    }
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case sessions = "Sessions", experiments = "Experiments", profiles = "Profiles", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .sessions: return "rectangle.stack"
        case .experiments: return "flask"
        case .profiles: return "slider.horizontal.3"
        case .settings: return "gearshape"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $model.section) { s in
                Label(s.rawValue, systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    MCPConnectButton()
                    if let u = model.update, u.isNewer {
                        Link(destination: URL(string: u.pageURL) ?? URL(string: "https://github.com")!) {
                            Label("Diorama \(u.latest) available", systemImage: "arrow.down.circle.fill")
                        }
                        .font(.caption)
                    }
                    ConnectionBadge()
                }
                .padding(8)
            }
        } detail: {
            Group {
                switch model.connection {
                case .connecting:
                    ProgressView("Connecting to the Diorama daemon…")
                case .failed(let msg):
                    ContentUnavailableView {
                        Label("Daemon unavailable", systemImage: "bolt.horizontal.circle")
                    } description: {
                        Text(msg)
                    } actions: {
                        Button("Retry") { Task { await model.connect() } }
                    }
                case .connected:
                    switch model.section ?? .sessions {
                    case .sessions: SessionsView()
                    case .experiments: ExperimentsView()
                    case .profiles: ProfilesView()
                    case .settings: SettingsView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) { ReviewBanner() }
        }
        .sheet(isPresented: $model.showReviews) { ReviewSheet() }
        .onAppear {
            Notifier.shared.start()
            Notifier.shared.open = { [model] target in
                NSApp.setActivationPolicy(.regular)
                NSApp.activate()
                switch target {
                case .run(let id):
                    model.section = .experiments
                    model.focusRunId = id
                case .session(let id):
                    model.section = .sessions
                    model.focusSessionId = id
                case .reviews:
                    model.showReviews = true
                }
            }
        }
        .task(id: model.connection) {
            guard let dir = model.snapshotDir, case .connected = model.connection else { return }
            await Snapshotter.run(dir: dir, model: model) { model.section = $0 }
        }
        .alert("Diorama", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("OK") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }
}

/// Renders the app's own windows (no screen-recording permission needed): every sidebar
/// section, then each sheet. Used for screenshots and as a UI smoke test in CI. With
/// DIORAMA_SNAPSHOT_OFFSCREEN set, windows stay off-screen.
@MainActor
enum Snapshotter {
    static var offscreen: Bool { ProcessInfo.processInfo.environment["DIORAMA_SNAPSHOT_OFFSCREEN"] != nil }

    static func run(dir: URL, model: AppModel, select: (SidebarSection) -> Void) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let main = NSApp.windows.first(where: { $0.isVisible })
        if let w = main {
            w.setContentSize(NSSize(width: 1500, height: 920))
            if offscreen { w.setFrameOrigin(NSPoint(x: -30_000, y: -30_000)) } else { w.center() }
        }
        for section in SidebarSection.allCases {
            select(section)
            try? await Task.sleep(for: .seconds(2.5))
            if let view = main?.contentView { capture(view, dir.appendingPathComponent("\(section.rawValue.lowercased()).png")) }
        }
        var sheets: [(String, AnyView)] = [
            ("sheet-new-session", AnyView(NewSessionSheet().environment(model))),
            ("sheet-new-session-desktop", AnyView(NewSessionSheet(mode: .desktop).environment(model))),
            ("sheet-new-profile", AnyView(NewProfileSheet(selection: .constant(nil)).environment(model))),
            ("sheet-new-experiment", AnyView(NewExperimentSheet(created: { _ in }).environment(model))),
            ("menu-bar-panel", AnyView(MenuBarPanel().environment(model))),
            ("mcp-connect", AnyView(MCPConnectPanel().environment(model))),
            ("sheet-export-data", AnyView(ExportDataSheet().environment(model))),
            ("sheet-review", AnyView(ReviewSheet(sample: [ReviewSheet.demo]).environment(model))),
            ("menu-review", AnyView(MenuReviewRow(review: ReviewSheet.demo, more: 1) {}.frame(width: 320).environment(model))),
            ("sheet-profile-compare", AnyView(ProfileCompareSheet(
                from: Profile(name: "Docs steer", rules: [Rule(id: "r1", name: "Rename the domain", match: RuleMatch(tools: ["WebFetch"]), instructions: "Replace 'Example Domain' with 'Morph Test Domain'."),
                                                          Rule(id: "r2", name: "Old search steer", match: RuleMatch(tools: ["WebSearch"]), instructions: "Prefer v2 docs.")]),
                fromLabel: "v2",
                to: Profile(name: "Docs steer", rules: [Rule(id: "r1", name: "Rename the domain", match: RuleMatch(tools: ["WebFetch", "Read"]), instructions: "Replace 'Example Domain' with 'Morph Test Domain' in headings only."),
                                                        Rule(id: "r3", name: "Redact secrets", match: RuleMatch(tools: ["*"]), instructions: "", redact: RedactSpec())],
                            defaults: ProfileDefaults(review: true)),
                toLabel: "v3"))),
            ("sheet-playground", AnyView(PlaygroundSheet(draft: Profile(name: "Docs steer", rules: [Rule(name: "Rename the domain", match: RuleMatch(tools: ["WebFetch"]), instructions: "Rename it")])).environment(model))),
        ]
        // With data (the demo), also the what-if sheet for a session that rewrote something.
        if let s = model.sessions.first(where: { $0.stats.rewrites > 0 && !$0.isHook && $0.kind == .interactive }) {
            sheets.append(("sheet-whatif", AnyView(WhatIfSheet(session: s).environment(model))))
            if let draft = try? await model.client?.experimentDraft(sessionId: s.id) {
                sheets.append(("sheet-experiment-from-session", AnyView(NewExperimentSheet(draft: draft, created: { _ in }).environment(model))))
            }
        }
        if let run = model.experiments.first?.runs.first, let c = try? await model.client?.comparison(run.id), c.trials.filter({ $0.facts != nil }).count >= 2 {
            sheets.append(("sheet-compare-trials", AnyView(TrialCompareSheet(trials: c.trials.filter { $0.facts != nil }).environment(model))))
        }
        for (name, view) in sheets {
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 700, height: 780), styleMask: [.titled], backing: .buffered, defer: false)
            // Code-created windows default to releasedWhenClosed = true, which double-releases
            // under ARC; with the close animation that crashed (EXC_BAD_ACCESS in objc_release).
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            window.contentView = host
            window.orderFrontRegardless()
            try? await Task.sleep(for: .seconds(1))
            // Size the window to the sheet's natural size so nothing is clipped.
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(300))
            capture(host, dir.appendingPathComponent("\(name).png"))
            window.close()
        }
        NSApp.terminate(nil)
    }

    static func capture(_ view: NSView, _ url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

struct ConnectionBadge: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack(spacing: 6) {
            switch model.connection {
            case .connected(let h):
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("Daemon \(h.version) · :\(String(h.port))").font(.caption).foregroundStyle(.secondary)
            case .connecting:
                Circle().fill(.yellow).frame(width: 8, height: 8)
                Text("Connecting…").font(.caption).foregroundStyle(.secondary)
            case .failed:
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("Disconnected").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
