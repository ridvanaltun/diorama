import Foundation

/// Whether Claude Code trusts a folder (workspace trust). Claude Code skips a project's hooks
/// until the folder is trusted, and the Claude desktop app can then stall without asking.
/// Read-only: Diorama never records trust itself; that is the user's decision, made in
/// Claude Code's own trust dialog.
public enum ClaudeTrust {
    /// Claude Code's global config: `$CLAUDE_CONFIG_DIR/.claude.json`, else `~/.claude.json`.
    public static func configFile(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).appendingPathComponent(".claude.json")
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
    }

    /// Mirrors Claude Code 2.1's check: the folder, or a parent up to its git repository's root
    /// (any parent outside a repository), has `projects[path].hasTrustDialogAccepted`. Nil when
    /// the config can't be read, so callers don't warn on a guess.
    public static func isTrusted(_ folder: String, config: URL = configFile()) -> Bool? {
        guard let data = FileManager.default.contents(atPath: config.path),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let projects = root["projects"] as? [String: Any] ?? [:]
        func trusted(_ path: String) -> Bool { (projects[path] as? [String: Any])?["hasTrustDialogAccepted"] as? Bool == true }
        var dir = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL.path
        let repo = gitRoot(of: dir)
        while true {
            if trusted(dir) { return true }
            if dir == repo { return false }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { return false }
            dir = parent
        }
    }

    /// The nearest folder at or above `dir` with a `.git` entry (a repository or worktree).
    static func gitRoot(of dir: String) -> String? {
        var d = dir
        while true {
            if FileManager.default.fileExists(atPath: (d as NSString).appendingPathComponent(".git")) { return d }
            let parent = (d as NSString).deletingLastPathComponent
            if parent == d || parent.isEmpty { return nil }
            d = parent
        }
    }

    /// What to tell someone connecting an untrusted folder.
    public static func advice(for folder: String) -> String {
        "Claude Code hasn't trusted \((folder as NSString).abbreviatingWithTildeInPath) yet, and it doesn't run a project's hooks until "
            + "it does. The Claude desktop app can then say \"If you trust this workspace…\" without ever asking. Trust it first: "
            + "run `claude` in that folder in Terminal and accept the trust question (or open the folder once in Claude desktop "
            + "before connecting it), then start a new session."
    }
}
