import DioramaCore
import Foundation

/// Adds and removes Diorama's Claude Code hooks (hook mode) in a settings file, leaving every
/// other setting and hook as it was. A project install goes in `<project>/.claude/settings.local.json`,
/// which Claude Code keeps out of version control; a user install in `~/.claude/settings.json`.
public enum HookInstaller {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        init(_ d: String) { description = d }
    }

    /// Events Diorama listens to: the session's start and end, and every tool result.
    static let events: [(name: String, matcher: String?, timeout: Int)] = [
        ("SessionStart", nil, 15),
        ("PreToolUse", "*", 180),
        ("PostToolUse", "*", 180),
        ("SessionEnd", nil, 15),
    ]

    public static func projectSettings(_ projectDir: String) -> URL {
        URL(fileURLWithPath: (projectDir as NSString).expandingTildeInPath, isDirectory: true)
            .appendingPathComponent(".claude/settings.local.json")
    }

    public static func userSettings(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".claude/settings.json")
    }

    /// The hook command: the `diorama` CLI with the session configuration as arguments.
    public static func command(cli: String, config: HookConfig) throws -> String {
        var parts = [shellQuote(cli), "hook", "run"]
        if let p = config.profile, !p.isEmpty { parts += ["--profile", shellQuote(p)] }
        if let prompt = config.prompt {
            guard prompt.stage != .page else { throw Failure("hook mode can't edit WebFetch pages before summarization; use `diorama run` for that") }
            parts += ["--prompt", shellQuote(prompt.text), "--prompt-tools", shellQuote(prompt.tools.joined(separator: ","))]
            if prompt.context == .task { parts += ["--prompt-context", "task"] }
            if let m = prompt.model { parts += ["--prompt-model", shellQuote(m)] }
        }
        return parts.joined(separator: " ")
    }

    /// True for a hook entry Diorama installed.
    static func isDiorama(_ hook: [String: Any]) -> Bool {
        guard let c = hook["command"] as? String else { return false }
        return c.contains("diorama") && c.contains(" hook run")
    }

    /// Installs (or replaces) Diorama's hooks in the settings file. Returns the file written.
    @discardableResult
    public static func install(command: String, settings url: URL) throws -> URL {
        var root = try read(url)
        var hooks = removeDiorama(from: root["hooks"] as? [String: Any] ?? [:])
        for e in events {
            var group: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": e.timeout]]]
            if let m = e.matcher { group["matcher"] = m }
            hooks[e.name] = (hooks[e.name] as? [[String: Any]] ?? []) + [group]
        }
        root["hooks"] = hooks
        try write(root, to: url)
        return url
    }

    /// Removes Diorama's hooks; returns false when none were installed.
    @discardableResult
    public static func uninstall(settings url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        var root = try read(url)
        let before = root["hooks"] as? [String: Any] ?? [:]
        let after = removeDiorama(from: before)
        guard installedCommand(in: before) != nil else { return false }
        if after.isEmpty { root["hooks"] = nil } else { root["hooks"] = after }
        try write(root, to: url)
        return true
    }

    /// The installed Diorama hook command, if any.
    public static func installedCommand(settings url: URL) -> String? {
        guard let root = try? read(url) else { return nil }
        return installedCommand(in: root["hooks"] as? [String: Any] ?? [:])
    }

    /// The hook events Diorama's hook is installed for (older installs lack PreToolUse).
    public static func installedEvents(settings url: URL) -> Set<String> {
        guard let hooks = (try? read(url))?["hooks"] as? [String: Any] else { return [] }
        return Set(hooks.compactMap { event, value in
            ((value as? [[String: Any]]) ?? []).contains { ($0["hooks"] as? [[String: Any]] ?? []).contains(where: isDiorama) } ? event : nil
        })
    }

    static func installedCommand(in hooks: [String: Any]) -> String? {
        for case let groups as [[String: Any]] in hooks.values {
            for g in groups {
                for h in g["hooks"] as? [[String: Any]] ?? [] where isDiorama(h) { return h["command"] as? String }
            }
        }
        return nil
    }

    static func removeDiorama(from hooks: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else {
                out[event] = value
                continue
            }
            let kept: [[String: Any]] = groups.compactMap { g in
                guard let list = g["hooks"] as? [[String: Any]] else { return g }
                let rest = list.filter { !isDiorama($0) }
                if rest.isEmpty { return nil }
                var copy = g
                copy["hooks"] = rest
                return copy
            }
            if !kept.isEmpty { out[event] = kept }
        }
        return out
    }

    public static func read(_ url: URL) throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: url.path), !data.isEmpty else { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data), let dict = obj as? [String: Any] else {
            throw Failure("\(url.path) is not a JSON object; fix or move it, then try again (it was left unchanged)")
        }
        return dict
    }

    public static func write(_ root: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
