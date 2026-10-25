import Foundation

/// One decided tool result, flattened for analysis (CSV or JSON Lines).
public struct DecisionExportRow: Codable, Sendable, Hashable {
    public var decisionId: String
    public var createdAt: Date
    public var sessionId: String
    public var sessionName: String
    public var sessionKind: String
    public var via: String
    public var trialId: String?
    public var profile: String?
    public var profileVersion: Int?
    public var tool: String?
    public var stage: String
    public var toolInput: String?
    public var isError: Bool
    public var outcome: String
    public var reason: String
    public var rules: [String]
    public var attempts: Int
    public var costUSD: Double
    public var originalChars: Int
    public var replacementChars: Int?
    /// Only with texts included.
    public var originalText: String?
    public var replacementText: String?

    public init(decisionId: String, createdAt: Date, sessionId: String, sessionName: String, sessionKind: String, via: String, trialId: String?,
                profile: String?, profileVersion: Int?, tool: String?, stage: String, toolInput: String?, isError: Bool, outcome: String, reason: String,
                rules: [String], attempts: Int, costUSD: Double, originalChars: Int, replacementChars: Int?, originalText: String? = nil, replacementText: String? = nil) {
        self.decisionId = decisionId
        self.createdAt = createdAt
        self.sessionId = sessionId
        self.sessionName = sessionName
        self.sessionKind = sessionKind
        self.via = via
        self.trialId = trialId
        self.profile = profile
        self.profileVersion = profileVersion
        self.tool = tool
        self.stage = stage
        self.toolInput = toolInput
        self.isError = isError
        self.outcome = outcome
        self.reason = reason
        self.rules = rules
        self.attempts = attempts
        self.costUSD = costUSD
        self.originalChars = originalChars
        self.replacementChars = replacementChars
        self.originalText = originalText
        self.replacementText = replacementText
    }
}

/// Which decisions to export.
public struct DecisionExportFilter: Codable, Sendable, Hashable {
    public var since: Date?
    public var until: Date?
    public var sessionId: String?
    /// Profile id: decisions from sessions that used any version of it.
    public var profileId: String?
    public var includeTrials: Bool
    public var rewrittenOnly: Bool
    public var includeTexts: Bool

    public init(since: Date? = nil, until: Date? = nil, sessionId: String? = nil, profileId: String? = nil, includeTrials: Bool = true,
                rewrittenOnly: Bool = false, includeTexts: Bool = false) {
        self.since = since
        self.until = until
        self.sessionId = sessionId
        self.profileId = profileId
        self.includeTrials = includeTrials
        self.rewrittenOnly = rewrittenOnly
        self.includeTexts = includeTexts
    }
}

/// An export as returned by the control API.
public struct DecisionExport: Codable, Sendable {
    public var format: DataExport.Format
    public var rows: Int
    public var content: String

    public init(format: DataExport.Format, rows: Int, content: String) {
        self.format = format
        self.rows = rows
        self.content = content
    }
}

public enum DataExport {
    public enum Format: String, Codable, Sendable, CaseIterable { case csv, jsonl }

    static let columns = ["decision_id", "created_at", "session_id", "session_name", "session_kind", "via", "trial_id", "profile", "profile_version",
                          "tool", "stage", "tool_input", "is_error", "outcome", "reason", "rules", "attempts", "cost_usd", "original_chars",
                          "replacement_chars"]

    static let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    public static func render(_ rows: [DecisionExportRow], format: Format, includeTexts: Bool) -> String {
        switch format {
        case .jsonl:
            let e = DioramaCoding.encoder
            return rows.map { String(decoding: (try? e.encode($0)) ?? Data(), as: UTF8.self) }.joined(separator: "\n") + (rows.isEmpty ? "" : "\n")
        case .csv:
            let header = columns + (includeTexts ? ["original_text", "replacement_text"] : [])
            var out = [header.joined(separator: ",")]
            for r in rows {
                var cells: [String?] = [r.decisionId, iso.format(r.createdAt), r.sessionId, r.sessionName, r.sessionKind, r.via, r.trialId, r.profile,
                                        r.profileVersion.map(String.init), r.tool, r.stage, r.toolInput, r.isError ? "true" : "false", r.outcome, r.reason,
                                        r.rules.joined(separator: "; "), String(r.attempts), String(format: "%.6f", r.costUSD), String(r.originalChars),
                                        r.replacementChars.map(String.init)]
                if includeTexts { cells += [r.originalText, r.replacementText] }
                out.append(cells.map { csvCell($0 ?? "") }.joined(separator: ","))
            }
            return out.joined(separator: "\r\n") + "\r\n"
        }
    }

    /// RFC 4180 quoting, plus a leading quote mark for cells a spreadsheet would run as a formula.
    static func csvCell(_ s: String) -> String {
        var v = s
        if let first = v.first, "=+-@\t\r".contains(first), Double(v) == nil { v = "'" + v }
        guard v.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return v }
        return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
