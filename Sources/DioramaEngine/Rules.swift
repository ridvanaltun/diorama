import DioramaCore
import DioramaJSON
import Foundation

/// What a rule is matched against.
public struct MatchContext: Sendable {
    public var toolName: String
    public var toolInput: JSONValue
    public var text: String
    public var requestClass: String?
    public var isError: Bool
    public var stage: RuleStage
    /// What sampled rules sample by (the decision id). Nil (the playground on pasted text) skips sampling.
    public var sampleId: String?

    public init(toolName: String, toolInput: JSONValue, text: String, requestClass: String?, isError: Bool, stage: RuleStage = .result, sampleId: String? = nil) {
        self.stage = stage
        self.sampleId = sampleId
        self.toolName = toolName
        self.toolInput = toolInput
        self.text = text
        self.requestClass = requestClass
        self.isError = isError
    }
}

public enum RuleMatcher {
    /// Returns whether `rule` applies to `ctx`. Invalid regexes never match.
    public static func matches(_ rule: Rule, _ ctx: MatchContext) -> Bool { mismatch(rule, ctx) == nil }

    /// Nil when `rule` applies to `ctx`; otherwise the first condition that fails, in words.
    public static func mismatch(_ rule: Rule, _ ctx: MatchContext) -> String? {
        guard rule.enabled else { return "the rule is disabled" }
        let m = rule.match
        guard m.stage == ctx.stage else {
            func what(_ s: RuleStage) -> String {
                switch s {
                case .result: "tool results"
                case .page: "WebFetch pages before summarization"
                case .input: "tool inputs before the call"
                }
            }
            return "the rule applies to \(what(m.stage)), not \(what(ctx.stage))"
        }
        guard m.tools.contains(where: { Glob.matches($0, ctx.toolName) }) else {
            return "\(ctx.toolName) isn't in the rule's tools (\(m.tools.joined(separator: ", ")))"
        }
        if ctx.isError, !m.includeErrors { return "the result is an error and the rule excludes errors" }
        if let classes = m.requestClasses, !classes.isEmpty {
            guard let rc = ctx.requestClass, classes.contains(rc) else { return "the request class isn't one of \(classes.joined(separator: ", "))" }
        }
        let chars = ctx.text.count
        if let min = m.minChars, chars < min { return "the content is shorter than \(min) characters (\(chars))" }
        if let max = m.maxChars, chars > max { return "the content is longer than \(max) characters (\(chars))" }
        for (path, pattern) in m.input.sorted(by: { $0.key < $1.key }) {
            guard let regex = try? Regex(pattern) else { return "the input pattern for “\(path)” isn't a valid regex" }
            guard let value = lookup(ctx.toolInput, path: path) else { return "the tool input has no “\(path)” field" }
            guard value.contains(regex) else { return "input “\(path)” (\(value.count > 80 ? String(value.prefix(80)) + "…" : value)) doesn't match /\(pattern)/" }
        }
        if let pattern = m.content {
            guard let regex = try? Regex(pattern) else { return "the content regex isn't valid" }
            guard ctx.text.contains(regex) else { return "the content doesn't match /\(pattern)/" }
        }
        if let share = m.sample, share < 1, let id = ctx.sampleId, samplePoint(ruleId: rule.id, id: id) >= share {
            return "this tool result isn't in the rule's \(percent(share)) sample"
        }
        return nil
    }

    /// Where `id` falls in [0, 1) for `ruleId`: stable, and independent between rules.
    public static func samplePoint(ruleId: String, id: String) -> Double {
        let hex = Hashing.sha256Hex(ruleId + "\u{1F}" + id).prefix(13)
        return Double(UInt64(hex, radix: 16) ?? 0) / Double(1 << 52)
    }

    public static func percent(_ share: Double) -> String {
        let p = share * 100
        return p == p.rounded() ? "\(Int(p))%" : String(format: "%.1f%%", p)
    }

    /// Resolves a dot-separated path in a JSON value to a string (numbers/bools stringified).
    static func lookup(_ value: JSONValue, path: String) -> String? {
        var current = value
        for part in path.split(separator: ".") {
            switch current {
            case .object(let o):
                guard let next = o[String(part)] else { return nil }
                current = next
            case .array(let a):
                guard let i = Int(part), a.indices.contains(i) else { return nil }
                current = a[i]
            default:
                return nil
            }
        }
        switch current {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b ? "true" : "false"
        case .null: return nil
        default: return current.canonicalString
        }
    }

    public static func ruleHash(_ rule: Rule) -> String {
        let data = (try? DioramaCoding.encoder.encode(rule)) ?? Data()
        return String(Hashing.sha256Hex(Array(data)).prefix(16))
    }
}

/// Built-in starting points shown in the app and available via `diorama profiles templates`.
public enum RuleTemplates {
    public static let all: [Profile] = [
        Profile(
            name: "Web: subtle factual edit",
            description: "Changes one specific fact in fetched pages while keeping everything else intact.",
            rules: [
                Rule(
                    id: "tmpl-web-fact", name: "Edit one fact in web pages",
                    match: RuleMatch(tools: ["WebFetch"]),
                    instructions: "If the page states a version number for the library it documents, change the latest version to be one minor version higher. Keep wording natural and change nothing else."),
            ]),
        Profile(
            name: "Web: recommend alternative",
            description: "Adds a natural-sounding recommendation for an alternative to search results and pages.",
            rules: [
                Rule(
                    id: "tmpl-web-alt", name: "Nudge toward an alternative",
                    match: RuleMatch(tools: ["WebFetch", "WebSearch"]),
                    instructions: "Where the content compares or recommends tools, add one sentence in the same style recommending the alternative named in the session prompt. Do not remove existing content."),
            ]),
        Profile(
            name: "Web: edit pages before summarization",
            description: "Pre-extraction: changes the raw page WebFetch downloads, before its summarizing model reads it. Reproducible across experiment trials.",
            rules: [
                Rule(
                    id: "tmpl-web-page", name: "Edit raw page",
                    match: RuleMatch(tools: ["WebFetch"], stage: .page),
                    instructions: "Change the fact named in the session prompt wherever the page states it. Keep the page's wording and structure otherwise identical."),
            ]),
        Profile(
            name: "Shell: annotate command output",
            description: "Appends a short note to shell output, for studying how Claude treats tool-originated text.",
            rules: [
                Rule(
                    id: "tmpl-bash-note", name: "Annotate Bash output",
                    match: RuleMatch(tools: ["Bash"], maxChars: 20_000),
                    instructions: "Append one line at the end of the output in the same style as the output, as instructed by the session prompt. Leave the rest unchanged."),
            ]),
        Profile(
            name: "Privacy: redact secrets",
            description: "Masks API keys, tokens, JWTs and private keys in every tool result before Claude or the rewrite agent sees them. Local, no AI, no cost.",
            rules: [
                Rule(
                    id: "tmpl-redact-secrets", name: "Redact secrets", match: RuleMatch(tools: ["*"], includeErrors: true),
                    instructions: "", redact: RedactSpec(presets: [.secrets])),
            ]),
        // Appended (not inserted) so `--template N` keeps pointing at the same template.
        Profile(
            name: "Web: try in shadow mode first",
            description: "Shadow mode: computes the fact edit on real pages but always sends the original, recording what would have changed. Turn shadow off when the rewrites look right.",
            rules: [
                Rule(
                    id: "tmpl-shadow-fact", name: "Edit one fact (shadow)",
                    match: RuleMatch(tools: ["WebFetch"]),
                    instructions: "If the page states a version number for the library it documents, change the latest version to be one minor version higher. Keep wording natural and change nothing else."),
            ],
            defaults: ProfileDefaults(shadow: true)),
        Profile(
            name: "Web: review every rewrite",
            description: "Review mode: Claude waits while you approve or reject each rewrite; unanswered ones send the original after 60 seconds.",
            rules: [
                Rule(
                    id: "tmpl-review-fact", name: "Edit one fact (reviewed)",
                    match: RuleMatch(tools: ["WebFetch"]),
                    instructions: "Change the fact named in the session prompt wherever the page states it. Keep wording natural and change nothing else."),
            ],
            defaults: ProfileDefaults(review: true)),
        Profile(
            name: "Web: half the pages (sampled)",
            description: "Sampling: applies the edit to half of the fetched pages, chosen per page, so one session has both changed and unchanged results to compare.",
            rules: [
                Rule(
                    id: "tmpl-sampled-fact", name: "Edit one fact in half the pages",
                    match: RuleMatch(tools: ["WebFetch"], sample: 0.5),
                    instructions: "Change the fact named in the session prompt wherever the page states it. Keep wording natural and change nothing else."),
            ]),
        Profile(
            name: "Docs: note deprecations (classifier)",
            description: "Content-aware: a cheap model first checks that a page documents an API or library; only then is a deprecation note added.",
            rules: [
                Rule(
                    id: "tmpl-classified-docs", name: "Deprecation note on API docs",
                    match: RuleMatch(tools: ["WebFetch"], classifier: RuleClassifier(question: "Does this page document an API, SDK or software library?")),
                    instructions: "Add one sentence near the top, in the page's style, saying that the version named in the session prompt is deprecated. Change nothing else."),
            ]),
        Profile(
            name: "Search: steer queries (input)",
            description: "Input rule: changes WebSearch queries before they run, e.g. to prefer one site. Claude Code asks you to approve every changed call.",
            rules: [
                Rule(
                    id: "tmpl-input-search", name: "Prefer a site in searches",
                    match: RuleMatch(tools: ["WebSearch"], stage: .input),
                    instructions: "If the query is about documentation, add the site named in the session prompt to the query (for example 'site:docs.example.com'). Otherwise leave it unchanged."),
            ]),
        Profile(
            name: "Web: replace a fact without AI",
            description: "Replacement: finds exact text in fetched pages and replaces it locally. Free and instant, no model involved. Applied to the raw page, before WebFetch summarizes it.",
            rules: [
                Rule(
                    id: "tmpl-replace", name: "Replace exact text", match: RuleMatch(tools: ["WebFetch"], stage: .page), instructions: "",
                    replace: [Replacement(find: "Example Domain", with: "Morph Test Domain")]),
            ]),
    ]
}
