import AppKit
import DioramaCore
import SwiftUI

@main
struct DioramaApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("Diorama") {
            RootView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 640)
                .task { await model.connect() }
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
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A SwiftPM-built executable starts as a background app; make it a regular app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
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
    @State private var section: SidebarSection? = .sessions

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $section) { s in
                Label(s.rawValue, systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
            .safeAreaInset(edge: .bottom) { ConnectionBadge().padding(8) }
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
                    switch section ?? .sessions {
                    case .sessions: SessionsView()
                    case .experiments: ExperimentsView()
                    case .profiles: ProfilesView()
                    case .settings: SettingsView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: model.connection) {
            guard let dir = model.snapshotDir, case .connected = model.connection else { return }
            await Snapshotter.run(dir: dir) { section = $0 }
        }
        .alert("Diorama", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("OK") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }
}

/// Renders the app's own window (no screen-recording permission needed) for each section.
@MainActor
enum Snapshotter {
    static func run(dir: URL, select: (SidebarSection) -> Void) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let w = NSApp.windows.first(where: { $0.isVisible }) {
            w.setContentSize(NSSize(width: 1500, height: 920))
            w.center()
        }
        for section in SidebarSection.allCases {
            select(section)
            try? await Task.sleep(for: .seconds(2.5))
            capture(dir.appendingPathComponent("\(section.rawValue.lowercased()).png"))
        }
        NSApp.terminate(nil)
    }

    static func capture(_ url: URL) {
        guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
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
