import Foundation

// Shared domain and API types. Everything here is Codable so the daemon, CLI and app speak
// one vocabulary over the control API.

public enum DioramaVersion {
    public static let current = "1.8.0"
    /// GitHub repository checked for updates (override with DIORAMA_UPDATE_REPO).
    public static let repository = "ridvanaltun/diorama"
    /// Version of the rewrite-agent system prompt + output contract. Bump on any change.
    public static let rewritePromptVersion = "rewrite-v1"
}

// MARK: - Rules and profiles

public enum ContextMode: String, Codable, Sendable, CaseIterable {
    /// Rule instructions, tool name + input, original result only.
    case none
    /// Additionally the session's task (the first user message).
    case task
}

public enum FailurePolicy: String, Codable, Sendable, CaseIterable {
    /// Forward the original content and flag the session.
    case passOriginal
    /// Forward the original and mark the experiment trial invalid.
    case invalidateTrial
}

/// Where a rule applies.
public enum RuleStage: String, Codable, Sendable, CaseIterable {
    /// The tool result Claude receives (default).
    case result
    /// WebFetch only: the raw page, before WebFetch's summarizing model sees it ("pre-extraction").
    case page
    /// A tool call's input, before the tool runs (hook mode and `diorama run`; Claude Code asks the
    /// user to approve each changed call). Not applied in experiment trials.
    case input
}

/// A yes/no question a cheap model answers about the content, e.g. "Does this page announce a price change?"
public struct RuleClassifier: Codable, Sendable, Hashable {
    public var question: String
    /// Default: the profile's rewrite model.
    public var model: String?

    public init(question: String, model: String? = nil) {
        self.question = question
        self.model = model
    }
}

public struct RuleMatch: Codable, Sendable, Hashable {
    /// Tool-name glob patterns (`*` wildcard), e.g. `WebFetch`, `mcp__docs__*`.
    public var tools: [String]
    /// Regex per tool-input field path (dot-separated), e.g. `url: "docs\\.example\\.com"`.
    public var input: [String: String]
    /// Regex that must match somewhere in the tool result text.
    public var content: String?
    public var minChars: Int?
    public var maxChars: Int?
    /// Request classes from Claude Code's hint header (`main`, `subagent`, …). Nil = any.
    public var requestClasses: [String]?
    /// Whether tool results flagged `is_error` may be rewritten.
    public var includeErrors: Bool
    /// `result` (default) or `page` (WebFetch pre-extraction).
    public var stage: RuleStage
    /// Content-aware matching: after the conditions above, a cheap model answers a yes/no question
    /// about the content, and the rule applies only on "yes".
    public var classifier: RuleClassifier?
    /// Apply to only this share (0–1] of the tool results that match, chosen deterministically from
    /// each result's id: the same result is always in or out of the sample. Nil = all of them.
    public var sample: Double?

    public init(
        tools: [String], input: [String: String] = [:], content: String? = nil, minChars: Int? = nil,
        maxChars: Int? = nil, requestClasses: [String]? = nil, includeErrors: Bool = false, stage: RuleStage = .result,
        classifier: RuleClassifier? = nil, sample: Double? = nil
    ) {
        self.classifier = classifier
        self.sample = sample
        self.stage = stage
        self.tools = tools
        self.input = input
        self.content = content
        self.minChars = minChars
        self.maxChars = maxChars
        self.requestClasses = requestClasses
        self.includeErrors = includeErrors
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tools = try c.decodeIfPresent([String].self, forKey: .tools) ?? []
        input = try c.decodeIfPresent([String: String].self, forKey: .input) ?? [:]
        content = try c.decodeIfPresent(String.self, forKey: .content)
        minChars = try c.decodeIfPresent(Int.self, forKey: .minChars)
        maxChars = try c.decodeIfPresent(Int.self, forKey: .maxChars)
        requestClasses = try c.decodeIfPresent([String].self, forKey: .requestClasses)
        includeErrors = try c.decodeIfPresent(Bool.self, forKey: .includeErrors) ?? false
        stage = try c.decodeIfPresent(RuleStage.self, forKey: .stage) ?? .result
        classifier = try c.decodeIfPresent(RuleClassifier.self, forKey: .classifier)
        sample = try c.decodeIfPresent(Double.self, forKey: .sample)
    }
}

public struct Rule: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var match: RuleMatch
    public var instructions: String
    public var model: String?
    public var effort: String?
    public var context: ContextMode
    /// Set for a redaction rule: masks matches locally, without the rewrite agent (instructions unused).
    public var redact: RedactSpec?
    /// Set for a replacement rule: finds text and replaces it locally, without the rewrite agent.
    public var replace: [Replacement]?

    public var isRedaction: Bool { redact != nil }
    public var isReplacement: Bool { replace != nil }
    /// Runs locally, without a model (redaction or replacement).
    public var isLocal: Bool { isRedaction || isReplacement }

    public init(
        id: String = UUID().uuidString.lowercased(), name: String, enabled: Bool = true, match: RuleMatch,
        instructions: String, model: String? = nil, effort: String? = nil, context: ContextMode = .none, redact: RedactSpec? = nil,
        replace: [Replacement]? = nil
    ) {
        self.redact = redact
        self.replace = replace
        self.id = id
        self.name = name
        self.enabled = enabled
        self.match = match
        self.instructions = instructions
        self.model = model
        self.effort = effort
        self.context = context
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.lowercased()
        name = try c.decode(String.self, forKey: .name)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        match = try c.decode(RuleMatch.self, forKey: .match)
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model)
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        context = try c.decodeIfPresent(ContextMode.self, forKey: .context) ?? .none
        redact = try c.decodeIfPresent(RedactSpec.self, forKey: .redact)
        replace = try c.decodeIfPresent([Replacement].self, forKey: .replace)
    }
}

/// One find-and-replace of a replacement rule. Literal by default; every occurrence unless `firstOnly`.
public struct Replacement: Codable, Sendable, Hashable {
    public var find: String
    public var with: String
    /// `find` is a regular expression and `with` may use $1, $2, ….
    public var regex: Bool
    public var ignoreCase: Bool
    /// Only where `find` isn't part of a longer word ("30" doesn't match "300").
    public var wholeWord: Bool
    /// Only the first occurrence in the tool result.
    public var firstOnly: Bool

    public init(find: String, with: String, regex: Bool = false, ignoreCase: Bool = false, wholeWord: Bool = false, firstOnly: Bool = false) {
        self.find = find
        self.with = with
        self.regex = regex
        self.ignoreCase = ignoreCase
        self.wholeWord = wholeWord
        self.firstOnly = firstOnly
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        find = try c.decodeIfPresent(String.self, forKey: .find) ?? ""
        with = try c.decodeIfPresent(String.self, forKey: .with) ?? ""
        regex = try c.decodeIfPresent(Bool.self, forKey: .regex) ?? false
        ignoreCase = try c.decodeIfPresent(Bool.self, forKey: .ignoreCase) ?? false
        wholeWord = try c.decodeIfPresent(Bool.self, forKey: .wholeWord) ?? false
        firstOnly = try c.decodeIfPresent(Bool.self, forKey: .firstOnly) ?? false
    }

    /// The compiled pattern, or nil for an invalid regex or an empty `find`.
    public var expression: NSRegularExpression? {
        guard !find.isEmpty else { return nil }
        var p = regex ? find : NSRegularExpression.escapedPattern(for: find)
        if wholeWord { p = #"(?<![\p{L}\p{N}_])(?:"# + p + #")(?![\p{L}\p{N}_])"# }
        return try? NSRegularExpression(pattern: p, options: ignoreCase ? [.caseInsensitive] : [])
    }

    public var template: String { regex ? with : NSRegularExpression.escapedTemplate(for: with) }

    /// "“30 derece” → “5 derece”".
    public var summary: String { "“\(find)” → “\(with)”" + (regex ? " (regex)" : "") + (firstOnly ? " (first only)" : "") }
}

/// What a redaction rule masks: built-in pattern sets and/or custom regexes.
public struct RedactSpec: Codable, Sendable, Hashable {
    public enum Preset: String, Codable, Sendable, CaseIterable {
        /// API keys and tokens (Anthropic, OpenAI, AWS, GitHub, Slack, Stripe, Google), JWTs, bearer tokens, private keys.
        case secrets
        case emails
        case ipAddresses
    }

    public var presets: [Preset]
    /// Extra regexes; each match is replaced.
    public var patterns: [String]

    public init(presets: [Preset] = [.secrets], patterns: [String] = []) {
        self.presets = presets
        self.patterns = patterns
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        presets = try c.decodeIfPresent([Preset].self, forKey: .presets) ?? []
        patterns = try c.decodeIfPresent([String].self, forKey: .patterns) ?? []
    }

    public var summary: String {
        let names = presets.map { p -> String in
            switch p {
            case .secrets: "secrets"
            case .emails: "email addresses"
            case .ipAddresses: "IP addresses"
            }
        } + (patterns.isEmpty ? [] : [patterns.count == 1 ? "1 custom pattern" : "\(patterns.count) custom patterns"])
        return names.isEmpty ? "nothing" : names.joined(separator: ", ")
    }
}

public struct ProfileDefaults: Codable, Sendable, Hashable {
    public var model: String
    public var effort: String?
    public var onFailure: FailurePolicy
    /// Tool results longer than this are never sent to the rewrite agent.
    public var maxInputChars: Int
    public var timeoutSeconds: Double
    public var maxOutputTokens: Int
    /// Cap on this profile's rewrite spending per local calendar day (all its versions). Nil = no cap.
    public var dailyBudgetUSD: Double?
    /// Hold each AI rewrite until the user approves it; rejected or unanswered rewrites forward the original.
    public var review: Bool
    /// How long a rewrite waits for a review before the original is forwarded.
    public var reviewTimeoutSeconds: Double
    /// Shadow mode: run AI rewrites but never apply them. Claude gets the original; each decision
    /// records what would have changed. Not used in experiment trials.
    public var shadow: Bool

    public static let defaultModel = "claude-haiku-5-5"
    public static let reviewTimeoutRange: ClosedRange<Double> = 15...120

    public init(
        model: String = ProfileDefaults.defaultModel, effort: String? = nil, onFailure: FailurePolicy = .passOriginal,
        maxInputChars: Int = 200_000, timeoutSeconds: Double = 45, maxOutputTokens: Int = 16_000, dailyBudgetUSD: Double? = nil,
        review: Bool = false, reviewTimeoutSeconds: Double = 60, shadow: Bool = false
    ) {
        self.shadow = shadow
        self.dailyBudgetUSD = dailyBudgetUSD
        self.review = review
        self.reviewTimeoutSeconds = reviewTimeoutSeconds
        self.model = model
        self.effort = effort
        self.onFailure = onFailure
        self.maxInputChars = maxInputChars
        self.timeoutSeconds = timeoutSeconds
        self.maxOutputTokens = maxOutputTokens
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ProfileDefaults()
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        onFailure = try c.decodeIfPresent(FailurePolicy.self, forKey: .onFailure) ?? d.onFailure
        maxInputChars = try c.decodeIfPresent(Int.self, forKey: .maxInputChars) ?? d.maxInputChars
        timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? d.timeoutSeconds
        maxOutputTokens = try c.decodeIfPresent(Int.self, forKey: .maxOutputTokens) ?? d.maxOutputTokens
        dailyBudgetUSD = try c.decodeIfPresent(Double.self, forKey: .dailyBudgetUSD)
        review = try c.decodeIfPresent(Bool.self, forKey: .review) ?? false
        reviewTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .reviewTimeoutSeconds) ?? d.reviewTimeoutSeconds
        shadow = try c.decodeIfPresent(Bool.self, forKey: .shadow) ?? false
    }
}

/// A named, ordered set of rules. Stored as immutable, content-addressed versions.
public struct Profile: Codable, Sendable, Hashable {
    public var name: String
    public var description: String
    public var rules: [Rule]
    public var defaults: ProfileDefaults
    /// Rule tests: sample tool results and which rules should match them. Versioned with the
    /// profile. Nil when there are none (so profiles without tests keep their exact JSON).
    public var tests: [ProfileTestCase]?

    public init(name: String, description: String = "", rules: [Rule] = [], defaults: ProfileDefaults = .init(), tests: [ProfileTestCase]? = nil) {
        self.name = name
        self.description = description
        self.rules = rules
        self.defaults = defaults
        self.tests = tests?.isEmpty == true ? nil : tests
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        rules = try c.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        defaults = try c.decodeIfPresent(ProfileDefaults.self, forKey: .defaults) ?? .init()
        tests = try c.decodeIfPresent([ProfileTestCase].self, forKey: .tests).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// One rule test: a sample tool result (or tool input, or raw page) and the rules that should
/// match it. Every other rule is expected not to match. Checked without calling any model.
public struct ProfileTestCase: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var toolName: String
    /// Tool input JSON (rules can match on its fields).
    public var toolInput: String?
    public var text: String
    public var stage: RuleStage
    public var isError: Bool
    /// Ids of the rules that should match.
    public var expectMatch: [String]

    public init(id: String = "test-" + UUID().uuidString.prefix(8).lowercased(), name: String, toolName: String = "WebFetch", toolInput: String? = nil,
                text: String, stage: RuleStage = .result, isError: Bool = false, expectMatch: [String]) {
        self.id = id
        self.name = name
        self.toolName = toolName
        self.toolInput = toolInput
        self.text = text
        self.stage = stage
        self.isError = isError
        self.expectMatch = expectMatch
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? "test-" + UUID().uuidString.prefix(8).lowercased()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Test"
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName) ?? "WebFetch"
        toolInput = try c.decodeIfPresent(String.self, forKey: .toolInput)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        stage = try c.decodeIfPresent(RuleStage.self, forKey: .stage) ?? .result
        isError = try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        expectMatch = try c.decodeIfPresent([String].self, forKey: .expectMatch) ?? []
    }
}

/// The outcome of one rule test.
public struct ProfileTestResult: Codable, Sendable, Hashable, Identifiable {
    public var caseId: String
    public var name: String
    public var passed: Bool
    /// One line per rule that behaved differently than expected, with the matcher's reason.
    public var problems: [String]
    /// Rules that matched (by name), for display.
    public var matched: [String]
    public var id: String { caseId }

    public init(caseId: String, name: String, passed: Bool, problems: [String], matched: [String]) {
        self.caseId = caseId
        self.name = name
        self.passed = passed
        self.problems = problems
        self.matched = matched
    }
}

public struct ProfileVersionInfo: Codable, Sendable, Hashable, Identifiable {
    /// Content hash of the canonical profile JSON.
    public var id: String
    public var profileId: String
    public var number: Int
    public var createdAt: Date
    public var profile: Profile

    public init(id: String, profileId: String, number: Int, createdAt: Date, profile: Profile) {
        self.id = id
        self.profileId = profileId
        self.number = number
        self.createdAt = createdAt
        self.profile = profile
    }
}

public struct ProfileSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var currentVersionId: String
    public var currentVersionNumber: Int
    public var ruleCount: Int
    public var updatedAt: Date

    public init(id: String, name: String, currentVersionId: String, currentVersionNumber: Int, ruleCount: Int, updatedAt: Date) {
        self.id = id
        self.name = name
        self.currentVersionId = currentVersionId
        self.currentVersionNumber = currentVersionNumber
        self.ruleCount = ruleCount
        self.updatedAt = updatedAt
    }
}

/// An ad-hoc rule attached to one session, applied after the profile's rules.
public struct SessionPrompt: Codable, Sendable, Hashable {
    public var text: String
    public var tools: [String]
    public var context: ContextMode
    public var model: String?
    public var stage: RuleStage

    public static let defaultTools = ["WebFetch", "WebSearch"]

    public init(text: String, tools: [String] = SessionPrompt.defaultTools, context: ContextMode = .none, model: String? = nil, stage: RuleStage = .result) {
        self.stage = stage
        self.text = text
        self.tools = tools
        self.context = context
        self.model = model
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        tools = try c.decodeIfPresent([String].self, forKey: .tools) ?? SessionPrompt.defaultTools
        context = try c.decodeIfPresent(ContextMode.self, forKey: .context) ?? .none
        model = try c.decodeIfPresent(String.self, forKey: .model)
        stage = try c.decodeIfPresent(RuleStage.self, forKey: .stage) ?? .result
    }

    /// The session prompt expressed as a rule (id is stable per session-prompt content).
    public func asRule(id: String) -> Rule {
        Rule(id: id, name: "Session prompt", match: RuleMatch(tools: stage == .page ? ["WebFetch"] : tools, stage: stage), instructions: text, model: model, context: context)
    }
}

// MARK: - Lockdown

public enum LockdownPreset: String, Codable, Sendable, CaseIterable {
    case none
    /// Blocks shell network tools that let Claude bypass rewritten web results.
    case network

    public var disallowedTools: [String] {
        switch self {
        case .none: return []
        case .network:
            return ["Bash(curl:*)", "Bash(wget:*)", "Bash(http:*)", "Bash(nc:*)", "Bash(lynx:*)", "Bash(links:*)"]
        }
    }

    /// Programs the preset blocks.
    public var blockedPrograms: Set<String> {
        switch self {
        case .none: return []
        case .network: return ["curl", "wget", "http", "https", "nc", "ncat", "lynx", "links", "w3m", "aria2c", "xh"]
        }
    }

    /// The blocked program a shell command runs, if any: any simple command in it (after `;`, `&&`,
    /// `|`, `$(`, …), past environment assignments, `sudo`/`env`/`command`, and with any path
    /// ("/usr/bin/curl"). A deterrent, not a sandbox: an interpreter can still fetch pages.
    public func blockedProgram(in command: String) -> String? {
        let blocked = blockedPrograms
        guard !blocked.isEmpty else { return nil }
        var normalized = command
        for sep in ["&&", "||", ";", "|", "&", "$(", "`", "(", ")", "\n", "{", "}"] { normalized = normalized.replacingOccurrences(of: sep, with: "\n") }
        for part in normalized.split(separator: "\n") {
            var words = part.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            while let w = words.first, w.contains("=") && !w.hasPrefix("=") || ["sudo", "env", "command", "exec", "nohup", "time", "xargs"].contains(w) || w.hasPrefix("-") {
                words.removeFirst()
            }
            guard let first = words.first else { continue }
            let program = (first.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) as NSString).lastPathComponent
            if blocked.contains(program) { return program }
        }
        return nil
    }
}

// MARK: - Sessions

public enum SessionKind: String, Codable, Sendable { case interactive, trial }
public enum SessionStatus: String, Codable, Sendable { case active, ended }
/// How a session reaches Diorama: through the local gateway (`diorama run`, full capture) or
/// through Claude Code hooks (Claude desktop, IDEs; tool results only, no model traffic).
public enum SessionVia: String, Codable, Sendable { case gateway, hook }

public struct SessionSpec: Codable, Sendable, Hashable {
    public var name: String
    public var cwd: String
    /// Profile id or name. Nil = no global rules.
    public var profile: String?
    public var prompt: SessionPrompt?
    public var lockdown: LockdownPreset
    public var kind: SessionKind
    public var trialId: String?
    public var onFailure: FailurePolicy?
    /// Experiment runs set this so identical tool results reuse one rewrite across trials.
    public var treatmentScope: String?
    /// Nil means `.gateway`.
    public var via: SessionVia?

    public init(
        name: String, cwd: String, profile: String? = nil, prompt: SessionPrompt? = nil, lockdown: LockdownPreset = .none,
        kind: SessionKind = .interactive, trialId: String? = nil, onFailure: FailurePolicy? = nil, treatmentScope: String? = nil,
        via: SessionVia? = nil
    ) {
        self.via = via
        self.name = name
        self.cwd = cwd
        self.profile = profile
        self.prompt = prompt
        self.lockdown = lockdown
        self.kind = kind
        self.trialId = trialId
        self.onFailure = onFailure
        self.treatmentScope = treatmentScope
    }
}

public struct SessionStats: Codable, Sendable, Hashable {
    public var exchanges: Int = 0
    public var toolResults: Int = 0
    public var rewrites: Int = 0
    public var failures: Int = 0
    public var anomalies: Int = 0
    public var rewriteCostUSD: Double = 0
    public init() {}
}

public struct SessionInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var cwd: String
    public var kind: SessionKind
    public var status: SessionStatus
    public var createdAt: Date
    public var endedAt: Date?
    public var profileId: String?
    public var profileName: String?
    public var profileVersionId: String?
    public var profileVersionNumber: Int?
    public var prompt: SessionPrompt?
    public var lockdown: LockdownPreset
    public var trialId: String?
    public var claudeSessionIds: [String]
    public var flags: [String]
    public var stats: SessionStats
    /// Nil (older daemons) means `.gateway`.
    public var via: SessionVia?
    public var isHook: Bool { via == .hook }
    /// Steering paused for this session (nil from older daemons).
    public var paused: Bool?
    public var isPaused: Bool { paused == true }
    /// The user's own notes and tags (nil from older daemons).
    public var notes: String?
    public var tags: [String]?
    /// Hidden from the session list (nil from older daemons).
    public var archived: Bool?
    public var isArchived: Bool { archived == true }
    /// Rule ids switched off for this session only (nil from older daemons).
    public var disabledRules: [String]?

    public init(
        id: String, name: String, cwd: String, kind: SessionKind, status: SessionStatus, createdAt: Date, endedAt: Date?,
        profileId: String?, profileName: String?, profileVersionId: String?, profileVersionNumber: Int?,
        prompt: SessionPrompt?, lockdown: LockdownPreset, trialId: String?, claudeSessionIds: [String], flags: [String],
        stats: SessionStats, via: SessionVia? = nil, paused: Bool? = nil, notes: String? = nil, tags: [String]? = nil, archived: Bool? = nil, disabledRules: [String]? = nil
    ) {
        self.archived = archived
        self.disabledRules = disabledRules
        self.paused = paused
        self.notes = notes
        self.tags = tags
        self.via = via
        self.id = id
        self.name = name
        self.cwd = cwd
        self.kind = kind
        self.status = status
        self.createdAt = createdAt
        self.endedAt = endedAt
        self.profileId = profileId
        self.profileName = profileName
        self.profileVersionId = profileVersionId
        self.profileVersionNumber = profileVersionNumber
        self.prompt = prompt
        self.lockdown = lockdown
        self.trialId = trialId
        self.claudeSessionIds = claudeSessionIds
        self.flags = flags
        self.stats = stats
    }
}

// MARK: - Hook mode

/// What a hook-mode session applies, set when the hook is installed (the hook command's arguments).
public struct HookConfig: Codable, Sendable, Hashable {
    /// Profile id or name.
    public var profile: String?
    public var prompt: SessionPrompt?
    /// Blocks shell network commands (curl, wget, …) through the PreToolUse hook.
    public var lockdown: LockdownPreset?

    public init(profile: String? = nil, prompt: SessionPrompt? = nil, lockdown: LockdownPreset? = nil) {
        self.profile = profile
        self.prompt = prompt
        self.lockdown = lockdown
    }
}

/// One Claude Code hook event, forwarded by `diorama hook run` to the daemon.
public struct HookEvent: Codable, Sendable {
    /// `SessionStart`, `PostToolUse` or `SessionEnd`.
    public var event: String
    public var claudeSessionId: String
    public var cwd: String
    public var transcriptPath: String?
    /// `CLAUDE_CODE_ENTRYPOINT` of the hooked session (e.g. `claude-desktop`, `cli`).
    public var client: String?
    public var toolName: String?
    public var toolUseId: String?
    /// Raw JSON of `tool_input`.
    public var toolInput: String?
    /// Raw JSON of `tool_response`.
    public var toolResponse: String?
    public var config: HookConfig
    /// Set for a `diorama run` session (its gateway session id): only its tool inputs go through the hook.
    public var dioramaSessionId: String?

    public init(
        event: String, claudeSessionId: String, cwd: String, transcriptPath: String? = nil, client: String? = nil, toolName: String? = nil,
        toolUseId: String? = nil, toolInput: String? = nil, toolResponse: String? = nil, config: HookConfig = HookConfig(), dioramaSessionId: String? = nil
    ) {
        self.dioramaSessionId = dioramaSessionId
        self.event = event
        self.claudeSessionId = claudeSessionId
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.client = client
        self.toolName = toolName
        self.toolUseId = toolUseId
        self.toolInput = toolInput
        self.toolResponse = toolResponse
        self.config = config
    }
}

public struct HookReply: Codable, Sendable {
    public var sessionId: String?
    /// Raw JSON to return as `updatedToolOutput`; nil leaves the tool result unchanged.
    public var updatedToolOutput: String?
    /// Raw JSON of a changed tool input (PreToolUse); Claude Code asks the user to approve it.
    public var updatedInput: String?
    /// PreToolUse: refuse the call, with this reason shown to Claude (lockdown).
    public var deny: String?
    public var outcome: DecisionOutcome?
    public var reason: String?

    public init(sessionId: String? = nil, updatedToolOutput: String? = nil, updatedInput: String? = nil, outcome: DecisionOutcome? = nil, reason: String? = nil,
                deny: String? = nil) {
        self.deny = deny
        self.updatedInput = updatedInput
        self.sessionId = sessionId
        self.updatedToolOutput = updatedToolOutput
        self.outcome = outcome
        self.reason = reason
    }
}

// MARK: - Rule playground

/// Tries rules on one tool result without a session: which rules match (free) and, optionally,
/// what the rewrite agent would do. Nothing is recorded.
public struct PlaygroundRequest: Codable, Sendable {
    /// Rules to try, e.g. the editor's unsaved draft. Takes precedence over `profileRef`.
    public var profile: Profile?
    /// A saved profile, by name or id.
    public var profileRef: String?
    public var prompt: SessionPrompt?
    /// A past tool result to test on (its original, before any rewrite).
    public var toolUseId: String?
    /// Or pasted content, with the tool it pretends to come from.
    public var text: String?
    public var toolName: String?
    /// Raw JSON of the tool input (rules can match on its fields).
    public var toolInput: String?
    public var stage: RuleStage?
    /// False: only check which rules match (no API call, no cost).
    public var rewrite: Bool
    /// With `rewrite`: run the same rewrite on each of these models (at most 4) to compare them.
    public var models: [String]?

    public static let maxComparedModels = 4

    public init(
        profile: Profile? = nil, profileRef: String? = nil, prompt: SessionPrompt? = nil, toolUseId: String? = nil, text: String? = nil,
        toolName: String? = nil, toolInput: String? = nil, stage: RuleStage? = nil, rewrite: Bool = false, models: [String]? = nil
    ) {
        self.models = models
        self.profile = profile
        self.profileRef = profileRef
        self.prompt = prompt
        self.toolUseId = toolUseId
        self.text = text
        self.toolName = toolName
        self.toolInput = toolInput
        self.stage = stage
        self.rewrite = rewrite
    }
}

public struct RuleCheck: Codable, Sendable, Hashable {
    public var ruleId: String
    public var name: String
    public var matches: Bool
    /// Why it matches, or the first condition that failed.
    public var reason: String

    public init(ruleId: String, name: String, matches: Bool, reason: String) {
        self.ruleId = ruleId
        self.name = name
        self.matches = matches
        self.reason = reason
    }
}

public struct PlaygroundRewrite: Codable, Sendable, Hashable {
    public var status: RewriteAttemptStatus
    public var replacementText: String?
    public var explanation: String?
    public var edits: [ContentEdit]
    public var error: String?
    public var model: String
    public var costUSD: Double?
    public var latencyMs: Double

    public init(status: RewriteAttemptStatus, replacementText: String?, explanation: String?, edits: [ContentEdit], error: String?, model: String, costUSD: Double?, latencyMs: Double) {
        self.status = status
        self.replacementText = replacementText
        self.explanation = explanation
        self.edits = edits
        self.error = error
        self.model = model
        self.costUSD = costUSD
        self.latencyMs = latencyMs
    }
}

public struct PlaygroundResult: Codable, Sendable, Hashable {
    public var toolName: String
    public var toolInput: String?
    public var stage: RuleStage
    public var originalText: String
    public var checks: [RuleCheck]
    /// The model a rewrite would use (nil when no rule matches).
    public var model: String?
    /// Why no rewrite was attempted, when `rewrite` was requested but skipped.
    public var note: String?
    public var rewrite: PlaygroundRewrite?
    /// Model comparison: one rewrite per requested model, in the order asked.
    public var comparisons: [PlaygroundRewrite]?

    public init(toolName: String, toolInput: String?, stage: RuleStage, originalText: String, checks: [RuleCheck], model: String?, note: String? = nil, rewrite: PlaygroundRewrite? = nil) {
        self.toolName = toolName
        self.toolInput = toolInput
        self.stage = stage
        self.originalText = originalText
        self.checks = checks
        self.model = model
        self.note = note
        self.rewrite = rewrite
    }
}

// MARK: - What-if replay

/// Re-runs a session's recorded tool results (their originals) through other rules and compares
/// the outcome with what the session actually did. Without `rewrite` it only checks which rules
/// match and estimates the cost (free). Nothing is recorded.
public struct WhatIfRequest: Codable, Sendable {
    public var sessionId: String
    /// Rules to compare, e.g. an unsaved draft. Takes precedence over the saved references.
    public var profile: Profile?
    /// A saved profile (current version), by name or id.
    public var profileRef: String?
    /// A specific saved version (`pv_…`).
    public var profileVersionId: String?
    public var prompt: SessionPrompt?
    public var rewrite: Bool
    /// At most this many rewrite-agent calls (default 25, at most 60).
    public var maxRewrites: Int?

    public init(sessionId: String, profile: Profile? = nil, profileRef: String? = nil, profileVersionId: String? = nil, prompt: SessionPrompt? = nil, rewrite: Bool = false, maxRewrites: Int? = nil) {
        self.sessionId = sessionId
        self.profile = profile
        self.profileRef = profileRef
        self.profileVersionId = profileVersionId
        self.prompt = prompt
        self.rewrite = rewrite
        self.maxRewrites = maxRewrites
    }
}

public enum WhatIfChange: String, Codable, Sendable, CaseIterable {
    /// Unchanged before, and the new rules leave it unchanged too.
    case sameUnchanged
    /// Rewritten before; the new rewrite produced identical text.
    case sameRewrite
    case rewrittenDifferently
    case nowRewritten
    case noLongerRewritten
    /// Check only: the new rules match, so the rewrite agent would be called.
    case wouldRewrite
    /// Over `maxRewrites`: matched but not run.
    case skipped
    case failed

    public var label: String {
        switch self {
        case .sameUnchanged: "unchanged in both"
        case .sameRewrite: "same rewrite"
        case .rewrittenDifferently: "rewritten differently"
        case .nowRewritten: "newly rewritten"
        case .noLongerRewritten: "no longer rewritten"
        case .wouldRewrite: "would go to the rewrite agent"
        case .skipped: "skipped (limit)"
        case .failed: "rewrite failed"
        }
    }
}

public struct WhatIfItem: Codable, Sendable, Hashable, Identifiable {
    public var toolUseId: String
    public var toolName: String
    public var toolInput: String?
    public var originalText: String
    public var before: DecisionOutcome
    public var beforeReason: String
    public var beforeText: String?
    public var matchedRules: [String]
    public var afterText: String?
    public var afterExplanation: String?
    public var afterError: String?
    public var change: WhatIfChange
    public var costUSD: Double?
    public var id: String { toolUseId }

    public init(
        toolUseId: String, toolName: String, toolInput: String?, originalText: String, before: DecisionOutcome, beforeReason: String, beforeText: String?,
        matchedRules: [String], afterText: String? = nil, afterExplanation: String? = nil, afterError: String? = nil, change: WhatIfChange, costUSD: Double? = nil
    ) {
        self.toolUseId = toolUseId
        self.toolName = toolName
        self.toolInput = toolInput
        self.originalText = originalText
        self.before = before
        self.beforeReason = beforeReason
        self.beforeText = beforeText
        self.matchedRules = matchedRules
        self.afterText = afterText
        self.afterExplanation = afterExplanation
        self.afterError = afterError
        self.change = change
        self.costUSD = costUSD
    }
}

public struct WhatIfResult: Codable, Sendable, Hashable {
    public var sessionId: String
    public var sessionName: String
    /// What was compared, e.g. "Docs steer v3".
    public var rulesLabel: String
    public var rewrite: Bool
    public var items: [WhatIfItem]
    /// Rewrite-agent calls a full run would make (matched items, up to the limit), and their estimated cost.
    public var calls: Int
    public var estimateLowUSD: Double
    public var estimateHighUSD: Double
    public var costUSD: Double

    public init(sessionId: String, sessionName: String, rulesLabel: String, rewrite: Bool, items: [WhatIfItem], calls: Int, estimateLowUSD: Double, estimateHighUSD: Double, costUSD: Double) {
        self.sessionId = sessionId
        self.sessionName = sessionName
        self.rulesLabel = rulesLabel
        self.rewrite = rewrite
        self.items = items
        self.calls = calls
        self.estimateLowUSD = estimateLowUSD
        self.estimateHighUSD = estimateHighUSD
        self.costUSD = costUSD
    }

    public func count(_ c: WhatIfChange) -> Int { items.filter { $0.change == c }.count }
}

/// A recent decision with its session's name (the playground's "past tool result" picker).
public struct RecentToolResult: Codable, Sendable, Hashable, Identifiable {
    public var decision: DecisionSummary
    public var sessionName: String
    public var id: String { decision.toolUseId }

    public init(decision: DecisionSummary, sessionName: String) {
        self.decision = decision
        self.sessionName = sessionName
    }
}

/// Returned once when a session is created; the token is a credential for the gateway.
public struct SessionLaunch: Codable, Sendable {
    public var session: SessionInfo
    public var token: String
    public var baseURL: String
    /// Environment variables to set for Claude Code.
    public var environment: [String: String]
    /// Extra Claude Code CLI arguments (settings override, lockdown).
    public var claudeArguments: [String]

    public init(session: SessionInfo, token: String, baseURL: String, environment: [String: String], claudeArguments: [String]) {
        self.session = session
        self.token = token
        self.baseURL = baseURL
        self.environment = environment
        self.claudeArguments = claudeArguments
    }
}

// MARK: - Exchanges, decisions, rewrites

public struct TokenUsage: Codable, Sendable, Hashable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }

    public static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: a.inputTokens + b.inputTokens, outputTokens: a.outputTokens + b.outputTokens,
            cacheReadTokens: a.cacheReadTokens + b.cacheReadTokens, cacheWriteTokens: a.cacheWriteTokens + b.cacheWriteTokens)
    }
}

public struct ToolUseSummary: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    /// Compact JSON of the tool input (truncated for display).
    public var input: String

    public init(id: String, name: String, input: String) {
        self.id = id
        self.name = name
        self.input = input
    }
}

public struct AssistantSummary: Codable, Sendable, Hashable {
    public var text: String
    public var toolUses: [ToolUseSummary]
    public var stopReason: String?

    public init(text: String = "", toolUses: [ToolUseSummary] = [], stopReason: String? = nil) {
        self.text = text
        self.toolUses = toolUses
        self.stopReason = stopReason
    }
}

public enum DecisionOutcome: String, Codable, Sendable { case unchanged, rewritten, failed }

/// How a tool result was handled within one exchange.
public enum ToolResultHandling: String, Codable, Sendable {
    case decidedUnchanged, decidedRewritten, decidedFailed
    case replayedUnchanged, replayedRewritten, replayedFailed
    /// Claude Code sent different content for an already-decided tool_use_id.
    case clientModified
    /// Not eligible (no content, unparsable).
    case skipped
}

public struct ToolResultEntry: Codable, Sendable, Hashable {
    public var toolUseId: String
    public var toolName: String?
    public var handling: ToolResultHandling

    public init(toolUseId: String, toolName: String?, handling: ToolResultHandling) {
        self.toolUseId = toolUseId
        self.toolName = toolName
        self.handling = handling
    }
}

public struct ExchangeSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: Int64
    public var sessionId: String
    public var startedAt: Date
    public var method: String
    public var path: String
    public var requestClass: String?
    public var agentId: String?
    public var claudeSessionId: String?
    public var model: String?
    public var status: Int?
    public var timeToFirstByteMs: Double?
    public var addedLatencyMs: Double?
    public var durationMs: Double?
    public var usage: TokenUsage?
    public var toolResults: [ToolResultEntry]
    public var assistant: AssistantSummary?
    public var error: String?

    public init(
        id: Int64, sessionId: String, startedAt: Date, method: String, path: String, requestClass: String?, agentId: String?,
        claudeSessionId: String?, model: String?, status: Int?, timeToFirstByteMs: Double?, addedLatencyMs: Double?,
        durationMs: Double?, usage: TokenUsage?, toolResults: [ToolResultEntry], assistant: AssistantSummary?, error: String?
    ) {
        self.id = id
        self.sessionId = sessionId
        self.startedAt = startedAt
        self.method = method
        self.path = path
        self.requestClass = requestClass
        self.agentId = agentId
        self.claudeSessionId = claudeSessionId
        self.model = model
        self.status = status
        self.timeToFirstByteMs = timeToFirstByteMs
        self.addedLatencyMs = addedLatencyMs
        self.durationMs = durationMs
        self.usage = usage
        self.toolResults = toolResults
        self.assistant = assistant
        self.error = error
    }
}

public struct ContentEdit: Codable, Sendable, Hashable {
    public var find: String
    public var replace: String
    public var rationale: String

    public init(find: String, replace: String, rationale: String) {
        self.find = find
        self.replace = replace
        self.rationale = rationale
    }
}

public enum RewriteAttemptStatus: String, Codable, Sendable {
    case succeeded, unchanged, failed, refused, invalid, timedOut, skipped
}

public struct RewriteAttemptInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var provider: String
    public var modelRequested: String
    public var modelServed: String?
    public var promptVersion: String
    public var status: RewriteAttemptStatus
    public var error: String?
    public var usage: TokenUsage?
    public var costUSD: Double?
    public var latencyMs: Double
    public var explanation: String?
    public var mode: String?
    public var edits: [ContentEdit]
    public var createdAt: Date

    public init(
        id: String, provider: String, modelRequested: String, modelServed: String?, promptVersion: String,
        status: RewriteAttemptStatus, error: String?, usage: TokenUsage?, costUSD: Double?, latencyMs: Double,
        explanation: String?, mode: String?, edits: [ContentEdit], createdAt: Date
    ) {
        self.id = id
        self.provider = provider
        self.modelRequested = modelRequested
        self.modelServed = modelServed
        self.promptVersion = promptVersion
        self.status = status
        self.error = error
        self.usage = usage
        self.costUSD = costUSD
        self.latencyMs = latencyMs
        self.explanation = explanation
        self.mode = mode
        self.edits = edits
        self.createdAt = createdAt
    }
}

public struct RuleRef: Codable, Sendable, Hashable {
    public var ruleId: String
    public var name: String
    /// Hash of the rule's canonical JSON at the time it applied.
    public var ruleHash: String
    public var profileVersionId: String?

    public init(ruleId: String, name: String, ruleHash: String, profileVersionId: String?) {
        self.ruleId = ruleId
        self.name = name
        self.ruleHash = ruleHash
        self.profileVersionId = profileVersionId
    }
}

public struct DecisionSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: String { toolUseId }
    public var toolUseId: String
    public var sessionId: String
    public var exchangeId: Int64
    public var toolName: String?
    public var outcome: DecisionOutcome
    public var reason: String
    public var createdAt: Date
    public var rules: [RuleRef]
    public var replayCount: Int
    /// Raw JSON of the tool call's input (for showing what the call was about).
    public var toolInput: String?

    public init(
        toolUseId: String, sessionId: String, exchangeId: Int64, toolName: String?, outcome: DecisionOutcome, reason: String,
        createdAt: Date, rules: [RuleRef], replayCount: Int, toolInput: String? = nil
    ) {
        self.toolInput = toolInput
        self.toolUseId = toolUseId
        self.sessionId = sessionId
        self.exchangeId = exchangeId
        self.toolName = toolName
        self.outcome = outcome
        self.reason = reason
        self.createdAt = createdAt
        self.rules = rules
        self.replayCount = replayCount
    }
}

public struct DecisionDetail: Codable, Sendable, Hashable {
    public var summary: DecisionSummary
    public var toolInput: String?
    public var isError: Bool
    public var originalText: String
    public var replacementText: String?
    public var instructions: [String]
    public var attempts: [RewriteAttemptInfo]
    /// What Claude did in the first response after receiving this tool result.
    public var followUp: AssistantSummary?
    public var followUpExchangeId: Int64?
    /// Shadow mode: what the rewrite would have sent (Claude got the original).
    public var shadowText: String?

    public init(
        summary: DecisionSummary, toolInput: String?, isError: Bool, originalText: String, replacementText: String?,
        instructions: [String], attempts: [RewriteAttemptInfo], followUp: AssistantSummary?, followUpExchangeId: Int64?, shadowText: String? = nil
    ) {
        self.shadowText = shadowText
        self.summary = summary
        self.toolInput = toolInput
        self.isError = isError
        self.originalText = originalText
        self.replacementText = replacementText
        self.instructions = instructions
        self.attempts = attempts
        self.followUp = followUp
        self.followUpExchangeId = followUpExchangeId
    }
}

public struct SessionEvent: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case sessionCreated, sessionEnded, exchangeStarted, exchangeFinished, decisionMade, rewriteFailed, anomaly
        case trialStarted, trialFinished, runStarted, runFinished, profileUpdated, warning
        case reviewRequested, reviewResolved
    }

    public var id: Int64
    public var sessionId: String?
    public var kind: Kind
    public var message: String
    public var refId: String?
    public var createdAt: Date

    public init(id: Int64, sessionId: String?, kind: Kind, message: String, refId: String?, createdAt: Date) {
        self.id = id
        self.sessionId = sessionId
        self.kind = kind
        self.message = message
        self.refId = refId
        self.createdAt = createdAt
    }
}

public struct Timeline: Codable, Sendable {
    public var session: SessionInfo
    public var exchanges: [ExchangeSummary]
    public var decisions: [DecisionSummary]
    public var events: [SessionEvent]

    public init(session: SessionInfo, exchanges: [ExchangeSummary], decisions: [DecisionSummary], events: [SessionEvent]) {
        self.session = session
        self.exchanges = exchanges
        self.decisions = decisions
        self.events = events
    }
}

// MARK: - Settings and status

public struct DioramaSettings: Codable, Sendable, Hashable {
    public var defaultModel: String
    public var retentionDays: Int
    public var captureRawBodies: Bool
    public var claudePath: String?
    /// Ollama server for `ollama:` models.
    public var ollamaURL: String
    /// Cap on rewrite-agent spending per local calendar day (interactive sessions, playground,
    /// what-if; experiments are covered by their own approved estimate). Nil = no cap.
    public var dailyBudgetUSD: Double?
    /// Pauses steering everywhere: AI rewrites and input rules stop in every session; redaction keeps working.
    public var steeringPaused: Bool
    /// Default profile (name or id) per project folder: sessions started in the folder or below use it.
    public var folderProfiles: [String: String] = [:]
    /// Folders whose profile JSON files are kept in sync as profiles (one way: file → Diorama).
    public var profileFolders: [String] = []
    /// Saved session setups, started from the menu bar or `diorama launch`.
    public var launchers: [Launcher] = []

    public static let defaultOllamaURL = "http://127.0.0.1:11434"

    public init(defaultModel: String = ProfileDefaults.defaultModel, retentionDays: Int = 14, captureRawBodies: Bool = true, claudePath: String? = nil, ollamaURL: String = DioramaSettings.defaultOllamaURL) {
        self.steeringPaused = false
        self.ollamaURL = ollamaURL
        self.defaultModel = defaultModel
        self.retentionDays = retentionDays
        self.captureRawBodies = captureRawBodies
        self.claudePath = claudePath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DioramaSettings()
        defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel) ?? d.defaultModel
        retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? d.retentionDays
        captureRawBodies = try c.decodeIfPresent(Bool.self, forKey: .captureRawBodies) ?? d.captureRawBodies
        claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath)
        ollamaURL = try c.decodeIfPresent(String.self, forKey: .ollamaURL) ?? DioramaSettings.defaultOllamaURL
        dailyBudgetUSD = try c.decodeIfPresent(Double.self, forKey: .dailyBudgetUSD)
        steeringPaused = try c.decodeIfPresent(Bool.self, forKey: .steeringPaused) ?? false
        folderProfiles = try c.decodeIfPresent([String: String].self, forKey: .folderProfiles) ?? [:]
        profileFolders = try c.decodeIfPresent([String].self, forKey: .profileFolders) ?? []
        launchers = try c.decodeIfPresent([Launcher].self, forKey: .launchers) ?? []
    }

    /// The default for `path`: its own entry or the nearest parent folder's.
    public func folderDefault(for path: String) -> FolderDefault? {
        var p = FolderDefault.normalize(path)
        while true {
            if let profile = folderProfiles[p] { return FolderDefault(path: p, profile: profile) }
            guard p != "/" else { return nil }
            p = (p as NSString).deletingLastPathComponent
            if p.isEmpty { return nil }
        }
    }
}

/// A project folder's default profile (`profile` nil removes it).
public struct FolderDefault: Codable, Sendable, Hashable, Identifiable {
    public var path: String
    public var profile: String?
    public var id: String { path }

    public init(path: String, profile: String?) {
        self.path = path
        self.profile = profile
    }

    /// Absolute, tilde-expanded, without a trailing slash or `..` parts, and with symlinks resolved
    /// when the folder exists (so `/var/…` and `/private/var/…`, or a symlinked checkout, are one folder).
    public static func normalize(_ path: String) -> String {
        var p = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
        if let real = realpath(p, nil) {
            p = String(cString: real)
            free(real)
        }
        return p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p
    }
}

// MARK: - Search

public struct SearchHit: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// A tool result (or WebFetch page, or tool input) and what Diorama did with it.
        case decision
        /// Claude's reply in one request (gateway sessions).
        case reply
    }

    public var kind: Kind
    /// The decision's tool_use_id, or the exchange id of a reply.
    public var ref: String
    public var sessionId: String
    public var sessionName: String
    public var createdAt: Date
    public var toolName: String?
    public var outcome: DecisionOutcome?
    /// Matching text with the matched terms between ⟦ and ⟧.
    public var snippet: String
    public var id: String { kind.rawValue + ":" + ref }

    public init(kind: Kind, ref: String, sessionId: String, sessionName: String, createdAt: Date, toolName: String?, outcome: DecisionOutcome?, snippet: String) {
        self.kind = kind
        self.ref = ref
        self.sessionId = sessionId
        self.sessionName = sessionName
        self.createdAt = createdAt
        self.toolName = toolName
        self.outcome = outcome
        self.snippet = snippet
    }
}

/// Rewrite-agent spending today (local calendar day) against the caps.
public struct SpendSummary: Codable, Sendable, Hashable {
    public struct ProfileSpend: Codable, Sendable, Hashable, Identifiable {
        public var profileId: String
        public var name: String
        public var todayUSD: Double
        public var dailyBudgetUSD: Double?
        public var id: String { profileId }

        public init(profileId: String, name: String, todayUSD: Double, dailyBudgetUSD: Double?) {
            self.profileId = profileId
            self.name = name
            self.todayUSD = todayUSD
            self.dailyBudgetUSD = dailyBudgetUSD
        }
    }

    public var since: Date
    public var todayUSD: Double
    public var dailyBudgetUSD: Double?
    public var profiles: [ProfileSpend]

    public var isOverBudget: Bool { dailyBudgetUSD.map { todayUSD >= $0 } ?? false }

    public init(since: Date, todayUSD: Double, dailyBudgetUSD: Double?, profiles: [ProfileSpend]) {
        self.since = since
        self.todayUSD = todayUSD
        self.dailyBudgetUSD = dailyBudgetUSD
        self.profiles = profiles
    }
}

public struct HealthInfo: Codable, Sendable {
    public var version: String
    public var pid: Int32
    public var port: Int
    public var startedAt: Date
    public var upstream: String
    public var dataDirectory: String
    public var activeSessions: Int
    /// Experiment runs in progress (nil from daemons before 1.7.1).
    public var activeRuns: Int?

    public init(version: String, pid: Int32, port: Int, startedAt: Date, upstream: String, dataDirectory: String, activeSessions: Int, activeRuns: Int? = nil) {
        self.activeRuns = activeRuns
        self.version = version
        self.pid = pid
        self.port = port
        self.startedAt = startedAt
        self.upstream = upstream
        self.dataDirectory = dataDirectory
        self.activeSessions = activeSessions
    }
}

public struct KeyStatus: Codable, Sendable {
    public var configured: Bool
    public var source: String?
    public var hint: String?

    public init(configured: Bool, source: String?, hint: String?) {
        self.configured = configured
        self.source = source
        self.hint = hint
    }
}

public struct APIErrorBody: Codable, Sendable, Error {
    public var error: String
    public init(error: String) { self.error = error }
}

// MARK: - Control API payloads

public struct ProfileDetail: Codable, Sendable {
    public var summary: ProfileSummary
    public var current: ProfileVersionInfo
    public var versions: [ProfileVersionInfo]
    /// The watched-folder file this profile is synced from, if any.
    public var syncedFile: String?

    public init(summary: ProfileSummary, current: ProfileVersionInfo, versions: [ProfileVersionInfo]) {
        self.summary = summary
        self.current = current
        self.versions = versions
    }
}

public struct DoctorCheck: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable { case ok, warning, failure }
    public var name: String
    public var status: Status
    public var detail: String

    public init(name: String, status: Status, detail: String) {
        self.name = name
        self.status = status
        self.detail = detail
    }
}

public struct DoctorReport: Codable, Sendable {
    public var checks: [DoctorCheck]
    public init(checks: [DoctorCheck]) { self.checks = checks }
}

public struct SetKeyRequest: Codable, Sendable {
    public var key: String
    public init(key: String) { self.key = key }
}

public struct ExchangeRawPayload: Codable, Sendable {
    public var request: String?
    public var forwarded: String?
    public var response: String?
    public var requestHeaders: String?
    public var responseHeaders: String?

    public init(request: String?, forwarded: String?, response: String?, requestHeaders: String?, responseHeaders: String?) {
        self.request = request
        self.forwarded = forwarded
        self.response = response
        self.requestHeaders = requestHeaders
        self.responseHeaders = responseHeaders
    }
}

public struct MaintenanceResult: Codable, Sendable {
    public var exchangesCleared: Int
    public var blobsRemoved: Int
    public var blobBytes: Int64
    public init(exchangesCleared: Int, blobsRemoved: Int, blobBytes: Int64) {
        self.exchangesCleared = exchangesCleared
        self.blobsRemoved = blobsRemoved
        self.blobBytes = blobBytes
    }
}

/// How a profile's rules have been used: per rule, how often it matched, what came of it and what it
/// cost. A tool result that several rules matched counts for each of them (`shared`), and so does
/// its cost. Experiment trials are left out unless asked for.
public struct ProfileRuleStats: Codable, Sendable, Hashable {
    public struct RuleUse: Codable, Sendable, Hashable, Identifiable {
        public var ruleId: String
        public var name: String
        /// False for rules that only exist in older versions of the profile.
        public var inCurrentVersion: Bool
        public var matched: Int = 0
        public var rewritten: Int = 0
        public var unchanged: Int = 0
        public var failed: Int = 0
        /// Matches where other rules matched the same tool result too.
        public var shared: Int = 0
        public var classifierYes: Int = 0
        public var classifierNo: Int = 0
        public var sessions: Int = 0
        public var costUSD: Double = 0
        public var lastMatchedAt: Date?
        public var id: String { ruleId }

        public init(ruleId: String, name: String, inCurrentVersion: Bool) {
            self.ruleId = ruleId
            self.name = name
            self.inCurrentVersion = inCurrentVersion
        }
    }

    public var profileId: String
    public var profileName: String
    /// Start of the window; nil for all time.
    public var since: Date?
    public var includesTrials: Bool
    /// Distinct tool results any rule of this profile matched, and their total cost.
    public var toolResults: Int
    public var costUSD: Double
    /// Current-version rules first (in profile order), then rules from older versions.
    public var rules: [RuleUse]

    public init(profileId: String, profileName: String, since: Date?, includesTrials: Bool, toolResults: Int, costUSD: Double, rules: [RuleUse]) {
        self.profileId = profileId
        self.profileName = profileName
        self.since = since
        self.includesTrials = includesTrials
        self.toolResults = toolResults
        self.costUSD = costUSD
        self.rules = rules
    }
}

/// An AI rewrite waiting for the user's approval before Claude sees it (review mode).
public struct PendingReview: Codable, Sendable, Hashable, Identifiable {
    /// The decision id (`tool_use_id`, or `page:<id>` for a raw page).
    public var id: String
    public var sessionId: String
    public var sessionName: String
    public var toolName: String
    public var toolInput: String?
    public var stage: RuleStage
    /// What Claude sees if the rewrite is rejected (after any redaction).
    public var originalText: String
    public var proposedText: String
    public var explanation: String
    public var rules: [String]
    public var createdAt: Date
    public var expiresAt: Date

    public init(id: String, sessionId: String, sessionName: String, toolName: String, toolInput: String?, stage: RuleStage,
                originalText: String, proposedText: String, explanation: String, rules: [String], createdAt: Date, expiresAt: Date) {
        self.id = id
        self.sessionId = sessionId
        self.sessionName = sessionName
        self.toolName = toolName
        self.toolInput = toolInput
        self.stage = stage
        self.originalText = originalText
        self.proposedText = proposedText
        self.explanation = explanation
        self.rules = rules
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

public enum ReviewVerdict: String, Codable, Sendable { case approved, rejected, timedOut }

/// The user's edits to a session's name, notes and tags. Nil fields are left as they are.
public struct SessionAnnotations: Codable, Sendable, Hashable {
    public var name: String?
    public var notes: String?
    public var tags: [String]?

    public static let maxTags = 20, maxTagLength = 40, maxNotesLength = 20_000

    public init(name: String? = nil, notes: String? = nil, tags: [String]? = nil) {
        self.name = name
        self.notes = notes
        self.tags = tags
    }

    /// Trimmed, without empty or duplicate tags (case-insensitive), in the order given.
    public static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxTagLength)) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .prefix(maxTags).map { $0 }
    }
}

/// Rewrite-agent spending per local calendar day, by where it went. Unlike the budget, this
/// includes experiment trials (as their own source), since they cost money too.
public struct SpendHistory: Codable, Sendable, Hashable {
    public struct Day: Codable, Sendable, Hashable, Identifiable {
        /// Start of the local day.
        public var day: Date
        public var sessionsUSD: Double = 0
        public var trialsUSD: Double = 0
        /// Playground and what-if runs.
        public var previewsUSD: Double = 0
        /// Rewrite-agent calls (including classifier calls) in sessions and trials.
        public var calls: Int = 0
        /// Per profile name (sessions, trials and previews).
        public var byProfile: [String: Double] = [:]
        public var totalUSD: Double { sessionsUSD + trialsUSD + previewsUSD }
        public var id: Date { day }

        public init(day: Date) { self.day = day }
    }

    /// Oldest first, one entry per day in the window (zero days included).
    public var days: [Day]
    public var totalUSD: Double { days.reduce(0) { $0 + $1.totalUSD } }

    public init(days: [Day]) { self.days = days }
}

/// Run a profile's rule tests: a saved profile by name or id, or an unsaved one.
public struct ProfileTestRequest: Codable, Sendable {
    public var profileRef: String?
    public var profile: Profile?

    public init(profileRef: String? = nil, profile: Profile? = nil) {
        self.profileRef = profileRef
        self.profile = profile
    }
}

/// Adds a recorded tool result to a profile's rule tests (saving a new version).
public struct AddRuleTestRequest: Codable, Sendable {
    public var decisionId: String
    public var name: String?

    public init(decisionId: String, name: String? = nil) {
        self.decisionId = decisionId
        self.name = name
    }
}

/// Archive or unarchive sessions: by id, or every ended session older than `olderThanDays`.
public struct ArchiveRequest: Codable, Sendable {
    public var sessionIds: [String]
    public var olderThanDays: Int?
    public var kind: SessionKind?
    public var archived: Bool

    public init(sessionIds: [String] = [], olderThanDays: Int? = nil, kind: SessionKind? = nil, archived: Bool = true) {
        self.sessionIds = sessionIds
        self.olderThanDays = olderThanDays
        self.kind = kind
        self.archived = archived
    }
}

/// One profile file in a watched folder and what syncing it did.
public struct ProfileSyncFile: Codable, Sendable, Hashable, Identifiable {
    public var path: String
    public var profileId: String?
    public var profileName: String?
    /// Why the file isn't (or is no longer) in sync, e.g. invalid JSON or a name clash.
    public var error: String?
    public var syncedAt: Date
    /// The file was synced before but is gone now (its profile is kept).
    public var missing: Bool
    public var id: String { path }

    public init(path: String, profileId: String?, profileName: String?, error: String?, syncedAt: Date, missing: Bool = false) {
        self.path = path
        self.profileId = profileId
        self.profileName = profileName
        self.error = error
        self.syncedAt = syncedAt
        self.missing = missing
    }
}

public struct ProfileFolderStatus: Codable, Sendable, Hashable, Identifiable {
    public var path: String
    public var exists: Bool
    public var files: [ProfileSyncFile]
    public var id: String { path }

    public init(path: String, exists: Bool, files: [ProfileSyncFile]) {
        self.path = path
        self.exists = exists
        self.files = files
    }
}

/// A saved session setup: where to start Claude Code and with which steering.
public struct Launcher: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// Shown in the menu; also the session's name.
    public var name: String
    public var folder: String
    public var profile: String?
    public var prompt: String?
    public var promptTools: [String]
    public var taskContext: Bool
    public var pageStage: Bool
    public var lockdown: LockdownPreset
    /// Extra arguments for Claude Code (split on spaces).
    public var claudeArgs: String

    public init(id: String = "launch-" + UUID().uuidString.prefix(8).lowercased(), name: String, folder: String, profile: String? = nil, prompt: String? = nil,
                promptTools: [String] = SessionPrompt.defaultTools, taskContext: Bool = false, pageStage: Bool = false, lockdown: LockdownPreset = .none,
                claudeArgs: String = "") {
        self.id = id
        self.name = name
        self.folder = folder
        self.profile = profile
        self.prompt = prompt
        self.promptTools = promptTools
        self.taskContext = taskContext
        self.pageStage = pageStage
        self.lockdown = lockdown
        self.claudeArgs = claudeArgs
    }

    /// Arguments for `diorama run` (run from `folder`).
    public var runArguments: [String] {
        var a = ["run", "--name", name]
        if let p = profile, !p.isEmpty { a += ["--profile", p] }
        if let p = prompt, !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            a += ["--prompt", p]
            a += pageStage ? ["--prompt-stage", "page"] : ["--prompt-tools", promptTools.joined(separator: ",")]
            if taskContext { a += ["--prompt-context", "task"] }
        }
        if lockdown != .none { a += ["--lockdown", lockdown.rawValue] }
        let extra = claudeArgs.split(whereSeparator: \.isWhitespace).map(String.init)
        if !extra.isEmpty { a += ["--"] + extra }
        return a
    }
}
