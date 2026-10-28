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

    /// The hook command: the `diorama` CLI with only the id of its configuration, which lives in
    /// Diorama's data folder (`HookConfigStore`). The project's settings file is readable by
    /// Claude, so the prompt, profile and lockdown must not appear in it. It only runs while the
    /// CLI exists, so a project keeps working after Diorama is removed.
    public static func command(cli: String, configId: String) -> String {
        "[ -x \(shellQuote(cli)) ] && exec \(shellQuote(cli)) hook run --config \(configId) || true"
    }

    /// Installs Diorama's hook with `config` kept in Diorama's data folder, out of the settings
    /// file. Reinstalling into the same file keeps its configuration id.
    @discardableResult
    public static func install(cli: String, config: HookConfig, settings url: URL, registry: HookRegistry) throws -> URL {
        try validate(config)
        let id = installedCommand(settings: url).flatMap(configId(in:)) ?? HookConfigStore.newId()
        registry.configs.save(config, id: id)
        return try install(command: command(cli: cli, configId: id), settings: url, registry: registry)
    }

    static func validate(_ config: HookConfig) throws {
        if config.prompt?.stage == .page { throw Failure("hook mode can't edit WebFetch pages before summarization; use `diorama run` for that") }
    }

    /// The configuration id a hook command passes (`--config hk_…`), if it uses one.
    public static func configId(in command: String) -> String? {
        let words = shellWords(command)
        guard let i = words.firstIndex(of: "--config"), i + 1 < words.count else { return nil }
        return words[i + 1]
    }

    /// What a hook command applies: its stored configuration, or the options written into older
    /// commands. Nil when its id is unknown or the command isn't Diorama's.
    public static func resolvedConfig(in command: String, configs: HookConfigStore) -> HookConfig? {
        if let id = configId(in: command) { return configs.get(id) }
        return config(in: command)
    }

    /// Hooks installed by earlier versions carry their configuration as options in the command, where
    /// Claude can read it in the settings file. Moves it into `configs` and leaves an id,
    /// keeping each entry's events and every other setting. Returns true when the file changed.
    @discardableResult
    public static func moveConfigOut(settings url: URL, configs: HookConfigStore) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        var root = try read(url)
        guard var hooks = root["hooks"] as? [String: Any] else { return false }
        var replaced: [String: String] = [:]
        for (event, value) in hooks {
            guard var groups = value as? [[String: Any]] else { continue }
            for g in groups.indices {
                guard var list = groups[g]["hooks"] as? [[String: Any]] else { continue }
                for h in list.indices where isDiorama(list[h]) {
                    guard let old = list[h]["command"] as? String, configId(in: old) == nil, let cli = cliPath(in: old) else { continue }
                    if replaced[old] == nil {
                        let id = HookConfigStore.newId()
                        configs.save(config(in: old) ?? HookConfig(), id: id)
                        replaced[old] = command(cli: cli, configId: id)
                    }
                    list[h]["command"] = replaced[old]
                }
                groups[g]["hooks"] = list
            }
            hooks[event] = groups
        }
        guard !replaced.isEmpty else { return false }
        root["hooks"] = hooks
        try write(root, to: url)
        return true
    }

    /// The command older versions wrote, with the configuration as options (kept for reading and
    /// moving those hooks, and for tests).
    public static func inlineCommand(cli: String, config: HookConfig) throws -> String {
        var parts = [shellQuote(cli), "hook", "run"]
        if let p = config.profile, !p.isEmpty { parts += ["--profile", shellQuote(p)] }
        if let prompt = config.prompt {
            try validate(config)
            parts += ["--prompt", shellQuote(prompt.text), "--prompt-tools", shellQuote(prompt.tools.joined(separator: ","))]
            if prompt.context == .task { parts += ["--prompt-context", "task"] }
            if let m = prompt.model { parts += ["--prompt-model", shellQuote(m)] }
        }
        if let l = config.lockdown, l != .none { parts += ["--lockdown", l.rawValue] }
        return "[ -x \(shellQuote(cli)) ] && exec \(parts.joined(separator: " ")) || true"
    }

    /// The CLI a hook command runs (older installs call it directly, newer ones check it exists first).
    public static func cliPath(in command: String) -> String? {
        let words = shellWords(command)
        guard let i = words.indices.first(where: { $0 + 2 < words.count && words[$0 + 1] == "hook" && words[$0 + 2] == "run" }) else { return nil }
        return words[i]
    }

    /// The session configuration a hook command passes (nil when it isn't Diorama's).
    public static func config(in command: String) -> HookConfig? {
        let words = shellWords(command)
        guard let run = words.indices.first(where: { $0 >= 1 && words[$0 - 1] == "hook" && words[$0] == "run" }) else { return nil }
        var options: [String: String] = [:]
        var i = run + 1
        while i + 1 < words.count, words[i].hasPrefix("--") {
            options[String(words[i].dropFirst(2))] = words[i + 1]
            i += 2
        }
        var config = HookConfig(profile: options["profile"], lockdown: options["lockdown"].flatMap(LockdownPreset.init(rawValue:)))
        if let text = options["prompt"] {
            config.prompt = SessionPrompt(
                text: text, tools: (options["prompt-tools"] ?? "").split(separator: ",").map(String.init),
                context: options["prompt-context"] == "task" ? .task : .none, model: options["prompt-model"])
        }
        return config
    }

    /// Splits a command the way `sh` would for what `command(cli:config:)` writes: words, single
    /// quotes and `'\''`.
    static func shellWords(_ command: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false, quoted = false, escaped = false
        for ch in command {
            if escaped {
                current.append(ch)
                escaped = false
            } else if quoted {
                if ch == "'" { quoted = false } else { current.append(ch) }
            } else if ch == "'" {
                quoted = true
                inWord = true
            } else if ch == "\\" {
                escaped = true
                inWord = true
            } else if ch == " " {
                if inWord { words.append(current) }
                current = ""
                inWord = false
            } else {
                current.append(ch)
                inWord = true
            }
        }
        if inWord { words.append(current) }
        return words
    }

    /// True for a hook entry Diorama installed.
    static func isDiorama(_ hook: [String: Any]) -> Bool {
        guard let c = hook["command"] as? String else { return false }
        return c.contains("diorama") && c.contains(" hook run")
    }

    /// Installs (or replaces) Diorama's hooks in the settings file and notes it in `registry`.
    /// Returns the file written.
    @discardableResult
    public static func install(command: String, settings url: URL, registry: HookRegistry? = nil) throws -> URL {
        defer { registry?.add(url) }
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

    /// Removes Diorama's hooks (and the file's entry in `registry`); returns false when none were installed.
    @discardableResult
    public static func uninstall(settings url: URL, registry: HookRegistry? = nil) throws -> Bool {
        registry?.remove(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        var root = try read(url)
        let before = root["hooks"] as? [String: Any] ?? [:]
        let after = removeDiorama(from: before)
        guard let installed = installedCommand(in: before) else { return false }
        if let registry, let id = configId(in: installed) { registry.configs.remove(id) }
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

    // MARK: Connected projects

    /// Every settings file that has Diorama's hook: the ones in `registry` plus the user settings.
    /// Entries whose hook is gone (removed by hand, folder deleted) are dropped from the registry.
    public static func connected(registry: HookRegistry, userSettings user: URL = userSettings(), claudeConfig: URL = ClaudeTrust.configFile()) -> [HookedProject] {
        var found: [HookedProject] = []
        for path in Set(registry.files + [user.path]).sorted() {
            let url = URL(fileURLWithPath: path)
            guard let command = installedCommand(settings: url) else {
                if path != user.path { registry.remove(url) }
                continue
            }
            let cli = cliPath(in: command)
            let folder = path == user.path ? nil : projectFolder(of: url)
            found.append(HookedProject(
                settingsFile: path, folder: folder, command: command, config: resolvedConfig(in: command, configs: registry.configs),
                cliMissing: cli.map { !FileManager.default.isExecutableFile(atPath: $0) } ?? true,
                outdated: !installedEvents(settings: url).contains("PreToolUse"),
                notTrusted: folder.map { ClaudeTrust.isTrusted($0, config: claudeConfig) == false } ?? false))
        }
        return found
    }

    /// Removes Diorama's hook from every connected project and the user settings; returns the
    /// files changed. A file that can't be changed (not JSON any more) is reported in `failures`.
    public static func uninstallAll(registry: HookRegistry, userSettings user: URL = userSettings()) -> (removed: [URL], failures: [String]) {
        var removed: [URL] = [], failures: [String] = []
        for project in connected(registry: registry, userSettings: user) {
            let url = URL(fileURLWithPath: project.settingsFile)
            do {
                if try uninstall(settings: url, registry: registry) { removed.append(url) }
            } catch {
                failures.append("\(url.path): \(error)")
            }
        }
        return (removed, failures)
    }

    /// The settings files whose Diorama hook a session in `cwd` runs: the nearest project
    /// settings at or above `cwd`, and the user settings.
    public static func locate(cwd: String, userSettings user: URL = userSettings()) -> [URL] {
        var found: [URL] = []
        var dir = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        while true {
            let url = projectSettings(dir.path)
            if url.path != user.path, installedCommand(settings: url) != nil {
                found.append(url)
                break
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        if installedCommand(settings: user) != nil { found.append(user) }
        return found
    }

    /// `<folder>/.claude/settings.local.json` → `<folder>`.
    static func projectFolder(of settings: URL) -> String {
        settings.deletingLastPathComponent().deletingLastPathComponent().path
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

extension HookConfig {
    /// One line for lists: `profile "Docs steer" · lockdown network`.
    public var summary: String {
        var parts: [String] = []
        if let p = profile { parts.append("profile \"\(p)\"") }
        if let p = prompt { parts.append("prompt \"\(p.text.count > 40 ? p.text.prefix(40) + "…" : p.text)\"") }
        if let l = lockdown, l != .none { parts.append("lockdown \(l.rawValue)") }
        return parts.isEmpty ? "records only (no rules)" : parts.joined(separator: " · ")
    }
}

/// A settings file with Diorama's hook, as `HookInstaller.connected` lists it.
public struct HookedProject: Codable, Sendable, Hashable, Identifiable {
    public var id: String { settingsFile }
    public var settingsFile: String
    /// The project folder; nil for the user settings (every session on this account).
    public var folder: String?
    public var command: String
    public var config: HookConfig?
    /// The hook's CLI no longer exists (Diorama moved or removed): the hook does nothing.
    public var cliMissing: Bool
    /// Installed before input rules existed (no PreToolUse hook): install it again.
    public var outdated: Bool
    /// Claude Code hasn't trusted the project folder, so it doesn't run the hook yet (`ClaudeTrust`).
    public var notTrusted: Bool

    public init(settingsFile: String, folder: String?, command: String, config: HookConfig?, cliMissing: Bool, outdated: Bool, notTrusted: Bool = false) {
        self.notTrusted = notTrusted
        self.settingsFile = settingsFile
        self.folder = folder
        self.command = command
        self.config = config
        self.cliMissing = cliMissing
        self.outdated = outdated
    }
}

/// The settings files Diorama's hook was installed in, kept in `hooks.json` in the data
/// directory so they can be listed and removed later, even with the daemon stopped (as when
/// Diorama itself is uninstalled). The daemon adds the files its hook sessions run from.
public struct HookRegistry: Sendable {
    public let url: URL

    public init(paths: DioramaPaths) { url = paths.home.appendingPathComponent("hooks.json") }

    struct File: Codable { var settingsFiles: [String] }

    public var files: [String] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        return (try? JSONDecoder().decode(File.self, from: data))?.settingsFiles ?? []
    }

    public func add(_ settings: URL) { update { $0.insert(settings.path) } }
    public func remove(_ settings: URL) { update { $0.remove(settings.path) } }

    /// The hook configurations, next to this registry in the data folder.
    public var configs: HookConfigStore { HookConfigStore(url: url.deletingLastPathComponent().appendingPathComponent("hook-configs.json")) }

    /// Read-modify-write under an exclusive lock: the CLI, the app and the daemon all write it.
    private func update(_ change: (inout Set<String>) -> Void) {
        lockedWrite(url) { () -> File? in
            var set = Set(files)
            let before = set
            change(&set)
            guard set != before else { return nil }
            return File(settingsFiles: set.sorted())
        }
    }
}

/// The configuration of each installed hook (profile, prompt, lockdown), by id, in
/// `hook-configs.json` in the data folder: outside the project, where Claude can't read it.
public struct HookConfigStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    struct File: Codable { var configs: [String: HookConfig] }

    static func newId() -> String { "hk_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased() }

    var all: [String: HookConfig] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [:] }
        return (try? JSONDecoder().decode(File.self, from: data))?.configs ?? [:]
    }

    public func get(_ id: String) -> HookConfig? { all[id] }

    public func save(_ config: HookConfig, id: String) {
        lockedWrite(url) { () -> File? in
            var configs = all
            guard configs[id] != config else { return nil }
            configs[id] = config
            return File(configs: configs)
        }
    }

    public func remove(_ id: String) {
        lockedWrite(url) { () -> File? in
            var configs = all
            guard configs.removeValue(forKey: id) != nil else { return nil }
            return File(configs: configs)
        }
    }
}

/// Writes what `make` returns (nil: leave the file as it is) under an exclusive lock, atomically
/// and readable only by the user.
private func lockedWrite<T: Encodable>(_ url: URL, _ make: () -> T?) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let fd = open(url.path + ".lock", O_CREAT | O_RDWR, 0o600)
    if fd >= 0 { flock(fd, LOCK_EX) }
    defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
    guard let value = make() else { return }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value), (try? data.write(to: url, options: .atomic)) != nil else { return }
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}
