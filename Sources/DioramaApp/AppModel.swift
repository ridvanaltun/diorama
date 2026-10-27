import AppKit
import DioramaClient
import DioramaCore
import Foundation
import Observation

/// App-wide state. The app holds no data of its own: everything comes from the daemon's
/// control API, and live events trigger targeted refreshes.
@MainActor
@Observable
final class AppModel {
    enum Connection: Equatable {
        case connecting
        case connected(HealthInfo)
        case failed(String)

        static func == (a: Connection, b: Connection) -> Bool {
            switch (a, b) {
            case (.connecting, .connecting): return true
            case (.connected(let x), .connected(let y)): return x.pid == y.pid && x.port == y.port
            case (.failed(let x), .failed(let y)): return x == y
            default: return false
            }
        }
    }

    var connection: Connection = .connecting
    var client: ControlClient?
    var sessions: [SessionInfo] = []
    var profiles: [ProfileSummary] = []
    var experiments: [ExperimentInfo] = []
    var keyStatus: KeyStatus?
    var settings = DioramaSettings()
    var lastError: String?
    /// Bumped whenever an event arrives; detail views observe it to refresh.
    var eventTick = 0
    var lastEvent: SessionEvent?
    var update: UpdateInfo?
    /// Sidebar selection (lifted here so views can navigate, e.g. "Open Settings").
    var section: SidebarSection? = .sessions
    /// Set by the getting-started guide to open the new-profile sheet.
    var wantsNewProfile = false
    /// Set by the menu bar panel: open the new-session sheet / select this session.
    var wantsNewSession = false
    /// Shows the "Connect to Claude" (MCP) panel.
    var showMCPConnect = false
    /// Today's rewrite spending against the caps.
    var spend: SpendSummary?
    /// Rewrites held for approval (review mode).
    var pendingReviews: [PendingReview] = []
    var showReviews = false
    var focusSessionId: String?
    /// Set after creating an experiment elsewhere (e.g. from a session) to select it.
    var focusExperimentId: String?
    /// Set when a notification about a run is clicked, to select that run.
    var focusRunId: String?
    /// Set by search results: the decision to open once its session's timeline appears.
    var focusDecisionId: String?
    var updateError: String?

    private var eventsTask: Task<Void, Never>?
    let paths = DioramaPaths.default()
    /// When set (DIORAMA_SNAPSHOT_DIR), the app renders each screen to PNG and quits. Used to
    /// verify the UI without screen-recording permission.
    let snapshotDir: URL? = ProcessInfo.processInfo.environment["DIORAMA_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }

    /// Connects once; reopening the window must not reset a live connection.
    func connectIfNeeded() async {
        if client == nil { await connect() }
    }

    private var connecting: Task<Void, Never>?

    /// Concurrent callers (window, menu bar) share one attempt, so only one daemon is spawned.
    func connect() async {
        if let connecting { return await connecting.value }
        let task = Task { await self.performConnect() }
        connecting = task
        await task.value
        connecting = nil
    }

    private func performConnect() async {
        connection = .connecting
        do {
            let c = try await ControlClient.connect(paths: paths, autostart: true)
            client = c
            connection = .connected(try await c.health())
            await refreshAll()
            subscribe()
        } catch {
            connection = .failed(String(describing: error))
        }
    }

    /// Stops the running daemon and starts this app's own (e.g. after an update left an older one running).
    func restartDaemon() async {
        guard let client else { return await connect() }
        eventsTask?.cancel()
        self.client = nil
        connection = .connecting
        await client.stopAndWait()
        await connect()
    }

    /// Checks GitHub Releases at most once a day (or immediately when `force`).
    func checkForUpdates(force: Bool = false) async {
        let defaults = UserDefaults.standard
        guard force || defaults.object(forKey: "autoUpdateCheck") as? Bool ?? true else { return }
        let last = defaults.double(forKey: "lastUpdateCheck")
        guard force || Date().timeIntervalSince1970 - last > 86_400 else { return }
        do {
            let info = try await UpdateChecker.check()
            update = info
            updateError = nil
            defaults.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
        } catch {
            updateError = (error as? ClientError)?.message ?? error.localizedDescription
        }
    }

    func subscribe() {
        eventsTask?.cancel()
        guard let client else { return }
        eventsTask = Task { [weak self] in
            var backoff = 1.0
            while !Task.isCancelled {
                do {
                    for try await ev in client.eventStream() {
                        backoff = 1
                        await self?.handle(ev)
                    }
                } catch {}
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, 15)
                // The daemon may have restarted with a new token/port: reconnect.
                if let self, (try? await client.health()) == nil {
                    await self.connect()
                    return
                }
            }
        }
    }

    func handle(_ ev: SessionEvent) async {
        lastEvent = ev
        eventTick += 1
        Notifier.shared.handle(ev, sessionName: ev.sessionId.flatMap { id in sessions.first { $0.id == id }?.name })
        switch ev.kind {
        case .sessionCreated, .sessionEnded: await refreshSessions()
        case .profileUpdated: await refreshProfiles()
        case .runStarted, .runFinished, .trialFinished: await refreshExperiments()
        case .reviewRequested, .reviewResolved:
            await refreshReviews()
            // Time-critical: open the review sheet right away if Diorama is in front.
            if ev.kind == .reviewRequested, NSApp.isActive, snapshotDir == nil { showReviews = true }
            if pendingReviews.isEmpty { showReviews = false }
        case .warning where ev.message.hasPrefix("Steering") || ev.message.hasPrefix("Rule "):
            // Paused or resumed from the CLI, MCP or another window.
            await refreshSessions()
            await refreshSettings()
        case .exchangeFinished, .decisionMade, .rewriteFailed:
            // Cheap: update just the counters for the list.
            if eventTick % 5 == 0 { await refreshSessions() }
        default: break
        }
    }

    func refreshAll() async {
        await refreshReviews()
        await refreshSessions()
        await refreshProfiles()
        await refreshExperiments()
        await refreshSettings()
    }

    func refreshSessions() async {
        guard let client else { return }
        do { sessions = try await client.sessions(limit: 300) } catch { report(error) }
        spend = try? await client.spend()
    }

    /// Starts a launcher's session in Terminal.
    func launch(_ l: Launcher) {
        do { try openInTerminal(FormLogic.launchCommand(l, cli: cliPath)) } catch { report(error) }
    }

    func saveLaunchers(_ list: [Launcher]) async {
        _ = await perform { try await $0.saveLaunchers(list) }
        await refreshSettings()
    }

    func refreshReviews() async {
        guard let client else { return }
        pendingReviews = (try? await client.pendingReviews()) ?? []
    }

    func resolveReview(_ r: PendingReview, approve: Bool) async {
        // A 409 means it was answered elsewhere or timed out; either way it's gone.
        try? await client?.resolveReview(r.id, approve: approve)
        pendingReviews.removeAll { $0.id == r.id }
        await refreshReviews()
        if pendingReviews.isEmpty { showReviews = false }
    }

    func refreshProfiles() async {
        guard let client else { return }
        do { profiles = try await client.profiles() } catch { report(error) }
    }

    func refreshExperiments() async {
        guard let client else { return }
        do { experiments = try await client.experiments() } catch { report(error) }
    }

    func refreshSettings() async {
        guard let client else { return }
        do {
            settings = try await client.settings()
            keyStatus = try await client.keyStatus()
        } catch { report(error) }
    }

    func report(_ error: Error) {
        lastError = (error as? ClientError)?.message ?? String(describing: error)
    }

    /// Runs an action against the client, surfacing errors in the UI.
    func perform<T>(_ action: (ControlClient) async throws -> T) async -> T? {
        guard let client else {
            lastError = "Not connected to the Diorama daemon."
            return nil
        }
        do { return try await action(client) } catch {
            report(error)
            return nil
        }
    }

    /// The `diorama` CLI bundled next to the app (falls back to PATH lookup).
    var cliPath: String {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/diorama").path,
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("diorama").path,
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) && !$0.hasSuffix("MacOS/diorama") } ?? "diorama"
    }
}
