import AppKit
import DioramaCore
import SwiftUI

/// The menu bar panel: daemon state, running sessions, and quick actions. Diorama keeps
/// running here after its window is closed.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var active: [SessionInfo] { model.sessions.filter { $0.status == .active } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: MenuBarIcon.image(active: !active.isEmpty)).foregroundStyle(Color.accentColor)
                Text("Diorama").font(.headline)
                Spacer()
                status
            }
            .padding(12)
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                Text(active.isEmpty ? "No routed sessions running" : "Running sessions")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.bottom, 2)
                ForEach(active.prefix(6)) { s in
                    MenuRow {
                        open { model.section = .sessions; model.focusSessionId = s.id }
                    } content: {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Circle().fill(.green).frame(width: 6, height: 6)
                                Text(s.name).lineLimit(1)
                                Spacer(minLength: 4)
                                if s.kind == .trial { Badge(text: "trial", color: .blue) }
                                if s.stats.rewrites > 0 { Badge(text: Fmt.plural(s.stats.rewrites, "rewrite"), color: .purple) }
                            }
                            Text(Fmt.shortPath(s.cwd)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).padding(.leading, 12)
                        }
                    }
                }
                if active.count > 6 {
                    Text("and \(active.count - 6) more").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6)
                }
            }
            .padding(6)
            Divider()
            VStack(spacing: 0) {
                MenuRow(action: { open { model.section = .sessions; model.wantsNewSession = true } }) {
                    Label("New Session…", systemImage: "plus")
                }
                MenuRow(action: { open {} }) {
                    Label("Open Diorama", systemImage: "macwindow")
                }
                MenuRow(action: { open { model.showMCPConnect = true } }) {
                    Label("Connect to Claude…", systemImage: "sparkles")
                }
                if let u = model.update, u.isNewer, let url = URL(string: u.pageURL) {
                    MenuRow(action: { NSWorkspace.shared.open(url); dismiss() }) {
                        Label("Diorama \(u.latest) available", systemImage: "arrow.down.circle").foregroundStyle(Color.accentColor)
                    }
                }
            }
            .padding(6)
            Divider()
            MenuRow(action: { NSApp.terminate(nil) }) {
                HStack {
                    Text("Quit Diorama")
                    Spacer()
                    Text("⌘Q").foregroundStyle(.secondary)
                }
            }
            .keyboardShortcut("q")
            .padding(6)
            Text("Routed sessions keep working after you quit: the daemon runs on its own.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.bottom, 10)
        }
        .frame(width: 300)
        .task { await model.connectIfNeeded() }
    }

    @ViewBuilder var status: some View {
        switch model.connection {
        case .connected:
            Label(Fmt.plural(active.count, "session") + " live", systemImage: "circle.fill").labelStyle(StatusLabelStyle(color: .green))
        case .connecting:
            Label("Connecting…", systemImage: "circle.fill").labelStyle(StatusLabelStyle(color: .yellow))
        case .failed:
            Label("Daemon offline", systemImage: "circle.fill").labelStyle(StatusLabelStyle(color: .red))
        }
    }

    func open(_ then: () -> Void) {
        then()
        dismiss()
        AppDelegate.showMainWindow(openWindow)
    }
}

/// The diorama as an open box seen at a slight angle, every edge the same width, as a menu
/// bar template image. The dot inside fills while a routed session is running.
enum MenuBarIcon {
    static func image(active: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let lineWidth = 1.2
            let front = NSRect(x: 1.5, y: 1.5, width: 11.5, height: 10.5)
            let depth = NSPoint(x: 3.5, y: 3)
            let backCorner = NSPoint(x: front.minX + depth.x, y: front.minY + depth.y)
            let box = NSBezierPath()
            box.lineWidth = lineWidth
            box.lineJoinStyle = .round
            box.lineCapStyle = .round
            box.appendRect(front)
            // Top and right faces.
            box.move(to: NSPoint(x: front.minX, y: front.maxY))
            box.line(to: NSPoint(x: front.minX + depth.x, y: front.maxY + depth.y))
            box.line(to: NSPoint(x: front.maxX + depth.x, y: front.maxY + depth.y))
            box.line(to: NSPoint(x: front.maxX + depth.x, y: front.minY + depth.y))
            box.line(to: NSPoint(x: front.maxX, y: front.minY))
            box.move(to: NSPoint(x: front.maxX, y: front.maxY))
            box.line(to: NSPoint(x: front.maxX + depth.x, y: front.maxY + depth.y))
            // Inside, seen through the open front: the floor's left edge and the back wall.
            box.move(to: NSPoint(x: front.minX, y: front.minY))
            box.line(to: backCorner)
            box.line(to: NSPoint(x: backCorner.x, y: front.maxY))
            box.move(to: backCorner)
            box.line(to: NSPoint(x: front.maxX, y: backCorner.y))
            box.stroke()
            let dot = NSBezierPath(ovalIn: NSRect(x: 7.3, y: 5.7, width: 3.4, height: 3.4))
            if active {
                dot.fill()
            } else {
                dot.lineWidth = lineWidth
                dot.stroke()
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = active ? "Diorama, sessions running" : "Diorama"
        return img
    }
}

struct StatusLabelStyle: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 7)).foregroundStyle(color)
            configuration.title.font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A full-width, highlight-on-hover row, like a menu item.
struct MenuRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6).padding(.vertical, 5)
                .background(hovering ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
