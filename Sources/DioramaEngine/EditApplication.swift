import DioramaCore
import Foundation

public struct EditError: Error, Sendable, Equatable, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

/// Applies a rewrite agent's output to the original text segments, deterministically.
public enum EditApplication {
    /// Returns the new segments, or an error explaining why the output is unusable (that text
    /// is fed back to the agent on retry).
    public static func apply(_ output: RewriteOutput, to segments: [String]) -> Result<[String], EditError> {
        switch output.decision {
        case .unchanged:
            return .success(segments)
        case .replace:
            guard !output.content.isEmpty else { return .failure(EditError("decision was \"replace\" but `content` is empty")) }
            guard !segments.isEmpty else { return .failure(EditError("there is no text to replace")) }
            var out = segments.map { _ in "" }
            out[0] = output.content
            return .success(out)
        case .edit:
            guard !output.edits.isEmpty else { return .failure(EditError("decision was \"edit\" but `edits` is empty")) }
            // Locate every edit in the original text first, then apply from the end.
            var located: [(segment: Int, range: Range<String.Index>, replace: String)] = []
            for (i, edit) in output.edits.enumerated() {
                guard !edit.find.isEmpty else { return .failure(EditError("edit \(i + 1) has an empty `find`")) }
                var hits: [(Int, Range<String.Index>)] = []
                for (si, seg) in segments.enumerated() {
                    var searchStart = seg.startIndex
                    while searchStart < seg.endIndex, let r = seg.range(of: edit.find, range: searchStart..<seg.endIndex) {
                        hits.append((si, r))
                        if hits.count > 1 { break }
                        searchStart = seg.index(after: r.lowerBound)
                    }
                    if hits.count > 1 { break }
                }
                if hits.isEmpty {
                    return .failure(EditError("edit \(i + 1): `find` text was not found verbatim in the original output: \(preview(edit.find))"))
                }
                if hits.count > 1 {
                    // The output's full text says which occurrences were meant: if it equals the
                    // original with every occurrence replaced, that's verifiably what was asked.
                    if let all = everyOccurrence(output, segments) { return .success(all) }
                    return .failure(EditError("edit \(i + 1): `find` text occurs more than once; include more surrounding context: \(preview(edit.find))"))
                }
                located.append((hits[0].0, hits[0].1, edit.replace))
            }
            // Overlap check within each segment.
            for a in 0..<located.count {
                for b in (a + 1)..<located.count where located[a].segment == located[b].segment {
                    if located[a].range.overlaps(located[b].range) {
                        return .failure(EditError("edits \(a + 1) and \(b + 1) overlap"))
                    }
                }
            }
            var out = segments
            for seg in Set(located.map(\.segment)) {
                let edits = located.filter { $0.segment == seg }.sorted { $0.range.lowerBound > $1.range.lowerBound }
                var s = segments[seg]
                for e in edits { s.replaceSubrange(e.range, with: e.replace) }
                out[seg] = s
            }
            return .success(out)
        }
    }

    /// Every edit applied to every occurrence, if that's exactly the output's own `content`.
    static func everyOccurrence(_ output: RewriteOutput, _ segments: [String]) -> [String]? {
        let content = output.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }
        var out = segments
        for e in output.edits where !e.find.isEmpty {
            out = out.map { $0.replacingOccurrences(of: e.find, with: e.replace) }
        }
        guard out != segments, out.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines) == content else { return nil }
        return out
    }

    static func preview(_ s: String) -> String {
        let p = s.prefix(80)
        return "\"\(p)\(s.count > 80 ? "…" : "")\""
    }
}
