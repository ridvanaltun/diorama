import Foundation

// Shared domain and API types. Everything here is Codable so the daemon, CLI and app speak
// one vocabulary over the control API.

public enum DioramaVersion {
    public static let current = "1.0.0"
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

    public init(
        tools: [String], input: [String: String] = [:], content: String? = nil, minChars: Int? = nil,
        maxChars: Int? = nil, requestClasses: [String]? = nil, includeErrors: Bool = false, stage: RuleStage = .result
    ) {
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

    public init(
        id: String = UUID().uuidString.lowercased(), name: String, enabled: Bool = true, match: RuleMatch,
        instructions: String, model: String? = nil, effort: String? = nil, context: ContextMode = .none
    ) {
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
        instructions = try c.decode(String.self, forKey: .instructions)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        context = try c.decodeIfPresent(ContextMode.self, forKey: .context) ?? .none
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

    public static let defaultModel = "claude-haiku-5-5"

    public init(
        model: String = ProfileDefaults.defaultModel, effort: String? = nil, onFailure: FailurePolicy = .passOriginal,
        maxInputChars: Int = 200_000, timeoutSeconds: Double = 45, maxOutputTokens: Int = 16_000
    ) {
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
    }
}

/// A named, ordered set of rules. Stored as immutable, content-addressed versions.
public struct Profile: Codable, Sendable, Hashable {
    public var name: String
    public var description: String
    public var rules: [Rule]
    public var defaults: ProfileDefaults

    public init(name: String, description: String = "", rules: [Rule] = [], defaults: ProfileDefaults = .init()) {
        self.name = name
        self.description = description
        self.rules = rules
        self.defaults = defaults
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        rules = try c.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        defaults = try c.decodeIfPresent(ProfileDefaults.self, forKey: .defaults) ?? .init()
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
}

// MARK: - Sessions

public enum SessionKind: String, Codable, Sendable { case interactive, trial }
public enum SessionStatus: String, Codable, Sendable { case active, ended }

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

    public init(
        name: String, cwd: String, profile: String? = nil, prompt: SessionPrompt? = nil, lockdown: LockdownPreset = .none,
        kind: SessionKind = .interactive, trialId: String? = nil, onFailure: FailurePolicy? = nil, treatmentScope: String? = nil
    ) {
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

    public init(
        id: String, name: String, cwd: String, kind: SessionKind, status: SessionStatus, createdAt: Date, endedAt: Date?,
        profileId: String?, profileName: String?, profileVersionId: String?, profileVersionNumber: Int?,
        prompt: SessionPrompt?, lockdown: LockdownPreset, trialId: String?, claudeSessionIds: [String], flags: [String],
        stats: SessionStats
    ) {
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

    public init(
        toolUseId: String, sessionId: String, exchangeId: Int64, toolName: String?, outcome: DecisionOutcome, reason: String,
        createdAt: Date, rules: [RuleRef], replayCount: Int
    ) {
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

    public init(
        summary: DecisionSummary, toolInput: String?, isError: Bool, originalText: String, replacementText: String?,
        instructions: [String], attempts: [RewriteAttemptInfo], followUp: AssistantSummary?, followUpExchangeId: Int64?
    ) {
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

    public static let defaultOllamaURL = "http://127.0.0.1:11434"

    public init(defaultModel: String = ProfileDefaults.defaultModel, retentionDays: Int = 14, captureRawBodies: Bool = true, claudePath: String? = nil, ollamaURL: String = DioramaSettings.defaultOllamaURL) {
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

    public init(version: String, pid: Int32, port: Int, startedAt: Date, upstream: String, dataDirectory: String, activeSessions: Int) {
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
