import DioramaCore
import DioramaJSON
import DioramaStore
import Foundation

extension DecisionEngine {
    struct InputShapeError: Error, CustomStringConvertible {
        let description: String
    }

    /// Decides a tool call's input before the tool runs (input-stage rules). The agent edits the
    /// input as pretty-printed JSON; the result must stay a JSON object with the same keys, so it
    /// can change values but not add or drop parameters. Keyed by `input:<tool_use_id>`.
    /// Returns the decision and, when rewritten, the new input JSON.
    public func decideInput(
        session: SessionRecord, toolUseId: String, toolName: String, toolInputJSON: String, taskText: String?
    ) async -> (DecisionRecord?, [UInt8]?) {
        let id = "input:" + toolUseId
        if let existing = try? store.decision(toolUseId: id) { return (existing, replacement(existing)) }
        guard let input = try? JSONValue.parse(toolInputJSON), case .object(let fields) = input else { return (nil, nil) }
        let original = input.canonicalBytes
        let pretty = Self.prettyJSON(original) ?? String(decoding: original, as: UTF8.self)
        // Most calls match no input rule: record nothing for them (no decision, no timeline row).
        let ctx = MatchContext(toolName: toolName, toolInput: input, text: pretty, requestClass: "main", isError: false, stage: .input)
        guard !applicableRules(session: session, ctx: ctx).rules.isEmpty else { return (nil, nil) }
        let keys = Set(fields.keys)
        let target = DecisionTarget(
            decisionId: id, toolName: toolName, toolInputJSON: toolInputJSON, matchInput: input, treatmentInput: input, isError: false, stage: .input,
            original: original, hash: Hashing.sha256Hex(original), segments: [pretty], taskText: taskText, missingReason: nil,
            buildReplacement: { texts in
                guard let text = texts.first, let value = try? JSONValue.parse(text), case .object(let new) = value else {
                    throw InputShapeError(description: "the edited input is not a JSON object")
                }
                guard Set(new.keys) == keys else { throw InputShapeError(description: "the edited input must keep the same keys") }
                return value.canonicalBytes
            })
        let d = await inflight.decision(for: id) {
            await self.decide(target, session: session, exchangeId: 0, requestClass: "main")
        }
        return (d, replacement(d))
    }

    public static func prettyJSON(_ bytes: [UInt8]) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(bytes)),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
