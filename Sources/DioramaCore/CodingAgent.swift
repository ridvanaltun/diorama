import Foundation

/// The coding agent a `diorama run` session starts.
public enum CodingAgent: String, Codable, Sendable, CaseIterable {
    case claude
    case opencode

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .opencode: "OpenCode"
        }
    }

    /// The executable's name on PATH.
    public var executableName: String { rawValue }
}

/// Tool names that mean the same tool in Claude Code and OpenCode. Rules written for one agent
/// (`WebFetch`) also match the other's tool (`webfetch`), so existing profiles keep working.
public enum ToolNames {
    private static let groups: [[String]] = [
        ["WebFetch", "webfetch"],
        ["WebSearch", "websearch"],
        ["Read", "read"],
        // OpenCode 2 calls its shell tool `shell`; OpenCode 1 called it `bash`.
        ["Bash", "shell", "bash"],
        ["Grep", "grep"],
        ["Glob", "glob"],
        ["Edit", "edit"],
        ["Write", "write"],
        ["Skill", "skill"],
    ]

    private static let index: [String: [String]] = {
        var out: [String: [String]] = [:]
        for g in groups { for name in g { out[name] = g.filter { $0 != name } } }
        return out
    }()

    /// The other agents' names for `name` (empty when there are none).
    public static func equivalents(_ name: String) -> [String] { index[name] ?? [] }

    /// `name` followed by its equivalents.
    public static func allNames(_ name: String) -> [String] { [name] + equivalents(name) }

    /// Whether `name` is a shell tool (`Bash`, `shell`, `bash`).
    public static func isShell(_ name: String) -> Bool { allNames(name).contains("Bash") }
}

/// The configuration Diorama hands OpenCode through `OPENCODE_CONFIG_CONTENT` for a gateway
/// session. OpenCode merges it over every configuration file (it wins over a project's own
/// `baseURL`), and no file on disk changes.
public enum OpenCodeLaunch {
    /// The environment variable OpenCode reads inline configuration from.
    public static let configVariable = "OPENCODE_CONFIG_CONTENT"

    /// Routes the Anthropic provider through `gatewayBase` (`http://127.0.0.1:port/s/token`).
    /// OpenCode's Anthropic package appends `/messages` to its base URL, so it ends in `/v1`.
    public static func configuration(gatewayBase: String, lockdown: LockdownPreset) -> [String: Any] {
        var config: [String: Any] = ["providers": ["anthropic": ["settings": ["baseURL": gatewayBase + "/v1"]]]]
        let deny = lockdown.openCodePermissions
        if !deny.isEmpty { config["permissions"] = deny }
        return config
    }

    public struct ArgumentProblem: Error, CustomStringConvertible, Sendable {
        public var description: String
    }

    /// Subcommands that talk to OpenCode's model service and take `--standalone` after their name.
    static let routedSubcommands: Set<String> = ["run", "mini"]
    /// Subcommands that don't run a session through this launch (or manage the shared service).
    static let otherSubcommands: Set<String> = [
        "upgrade", "update", "uninstall", "acp", "api", "debug", "auth", "mcp", "plugin", "models", "stats",
        "session", "service", "reload", "pair", "serve",
    ]

    /// The OpenCode command line: the user's arguments with Diorama's (`--standalone`) placed where
    /// OpenCode accepts them, after `run` or `mini`, or first for the TUI.
    public static func arguments(user: [String], launch: [String]) -> Result<[String], ArgumentProblem> {
        if user.contains(where: { $0 == "--server" || $0.hasPrefix("--server=") }) {
            return .failure(ArgumentProblem(description: "--server connects OpenCode to another server, which would bypass Diorama; leave it out"))
        }
        let extra = launch.filter { !user.contains($0) }
        guard let first = user.first, !first.hasPrefix("-") else { return .success(extra + user) }
        if routedSubcommands.contains(first) { return .success([first] + extra + user.dropFirst()) }
        if otherSubcommands.contains(first) {
            return .failure(ArgumentProblem(description: "`opencode \(first)` doesn't run a routed session; use the TUI, `run` or `mini`"))
        }
        // A directory to open the TUI in.
        return .success(extra + user)
    }

    /// `overlay` deep-merged over `base`: objects merge key by key, Diorama's values win, and
    /// `permissions` arrays are concatenated (OpenCode uses the last matching rule, so Diorama's
    /// rules, appended last, take effect).
    public static func merge(_ base: [String: Any], _ overlay: [String: Any]) -> [String: Any] {
        var out = base
        for (key, value) in overlay {
            if let a = out[key] as? [String: Any], let b = value as? [String: Any] {
                out[key] = merge(a, b)
            } else if key == "permissions", let a = out[key] as? [Any], let b = value as? [Any] {
                out[key] = a + b
            } else {
                out[key] = value
            }
        }
        return out
    }

    /// The `OPENCODE_CONFIG_CONTENT` value: Diorama's configuration merged over the one already in
    /// the environment, if any. An existing value that isn't a JSON object is replaced, and
    /// `replacedInvalid` says so.
    public static func environmentValue(existing: String?, overlay: [String: Any]) -> (value: String, replacedInvalid: Bool) {
        var base: [String: Any] = [:]
        var replaced = false
        if let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let obj = (try? JSONSerialization.jsonObject(with: Data(existing.utf8))) as? [String: Any] {
                base = obj
            } else {
                replaced = true
            }
        }
        let merged = merge(base, overlay)
        let data = (try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return (String(decoding: data, as: UTF8.self), replaced)
    }
}

extension LockdownPreset {
    /// OpenCode permission rules that deny the preset's network programs in the shell tool.
    /// OpenCode's shell scanner checks every subcommand of a compound command against them.
    public var openCodePermissions: [[String: String]] {
        blockedPrograms.sorted().map { ["action": "shell", "resource": "\($0) *", "effect": "deny"] }
    }
}
