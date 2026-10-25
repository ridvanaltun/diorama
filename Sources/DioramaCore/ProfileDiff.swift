import Foundation

/// What changed between two versions of a profile: its name, description and defaults, and rule by
/// rule (matched by rule id) which rules were added, removed, edited or moved.
public struct ProfileComparison: Codable, Sendable, Hashable {
    public struct FieldChange: Codable, Sendable, Hashable, Identifiable {
        /// Dotted path, e.g. `defaults.model` or `match.tools`.
        public var path: String
        public var old: String?
        public var new: String?
        public var id: String { path }
    }

    public struct RuleChange: Codable, Sendable, Hashable, Identifiable {
        public enum Kind: String, Codable, Sendable { case added, removed, changed, moved }
        public var ruleId: String
        public var name: String
        public var kind: Kind
        /// Also moved in the order (for `changed`).
        public var moved: Bool
        public var fields: [FieldChange]
        public var id: String { ruleId }
    }

    public var fields: [FieldChange]
    public var rules: [RuleChange]
    public var isEmpty: Bool { fields.isEmpty && rules.isEmpty }

    public static func compare(_ a: Profile, _ b: Profile) -> ProfileComparison {
        var fields = diff(flatten(["name": a.name, "description": a.description]), flatten(["name": b.name, "description": b.description]))
        fields += diff(flatten(encoded(a.defaults), prefix: "defaults"), flatten(encoded(b.defaults), prefix: "defaults"))

        let old = Dictionary(a.rules.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
        let new = Dictionary(b.rules.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
        // Order among the rules both versions have: a rule moved if its position there changed.
        let commonOld = a.rules.map(\.id).filter { new[$0] != nil }
        let commonNew = b.rules.map(\.id).filter { old[$0] != nil }
        var rules: [RuleChange] = []
        for r in b.rules {
            guard let before = old[r.id] else {
                rules.append(RuleChange(ruleId: r.id, name: r.name, kind: .added, moved: false, fields: []))
                continue
            }
            let moved = commonOld.firstIndex(of: r.id) != commonNew.firstIndex(of: r.id)
            let changes = diff(flatten(encoded(before)), flatten(encoded(r))).filter { $0.path != "id" }
            if !changes.isEmpty {
                rules.append(RuleChange(ruleId: r.id, name: r.name, kind: .changed, moved: moved, fields: changes))
            } else if moved {
                rules.append(RuleChange(ruleId: r.id, name: r.name, kind: .moved, moved: true, fields: []))
            }
        }
        for r in a.rules where new[r.id] == nil {
            rules.append(RuleChange(ruleId: r.id, name: r.name, kind: .removed, moved: false, fields: []))
        }
        return ProfileComparison(fields: fields, rules: rules)
    }

    static func encoded<T: Encodable>(_ v: T) -> Any {
        (try? DioramaCoding.encoder.encode(v)).flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) } ?? [:]
    }

    /// Leaf values by dotted path. Arrays of plain values become one comma-separated value.
    static func flatten(_ value: Any, prefix: String = "") -> [String: String] {
        func key(_ k: String) -> String { prefix.isEmpty ? k : "\(prefix).\(k)" }
        switch value {
        case let d as [String: Any]:
            return d.reduce(into: [:]) { out, kv in out.merge(flatten(kv.value, prefix: key(kv.key))) { x, _ in x } }
        case let arr as [Any]:
            if arr.allSatisfy({ !($0 is [String: Any]) && !($0 is [Any]) }) {
                return [prefix: arr.map(scalar).joined(separator: ", ")]
            }
            return arr.enumerated().reduce(into: [:]) { out, e in out.merge(flatten(e.element, prefix: key(String(e.offset)))) { x, _ in x } }
        default:
            return [prefix: scalar(value)]
        }
    }

    static func scalar(_ v: Any) -> String {
        switch v {
        case is NSNull: "none"
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): n.boolValue ? "true" : "false"
        default: "\(v)"
        }
    }

    static func diff(_ a: [String: String], _ b: [String: String]) -> [FieldChange] {
        Set(a.keys).union(b.keys).sorted().compactMap { k in
            let (x, y) = (a[k].flatMap { $0 == "none" || $0.isEmpty ? nil : $0 }, b[k].flatMap { $0 == "none" || $0.isEmpty ? nil : $0 })
            return x == y ? nil : FieldChange(path: k, old: x, new: y)
        }
    }

    /// Plain text for the CLI and the MCP server.
    public func text(from: String, to: String) -> String {
        guard !isEmpty else { return "No differences between \(from) and \(to)." }
        func line(_ f: FieldChange) -> String {
            let o = f.old.map { Self.short($0) } ?? "(none)", n = f.new.map { Self.short($0) } ?? "(none)"
            return "  \(f.path): \(o) → \(n)"
        }
        var out = ["Changes from \(from) to \(to):"]
        if !fields.isEmpty {
            out.append("")
            out.append("Profile")
            out += fields.map(line)
        }
        for r in rules {
            out.append("")
            switch r.kind {
            case .added: out.append("+ Added rule “\(r.name)”")
            case .removed: out.append("- Removed rule “\(r.name)”")
            case .moved: out.append("↕ Moved rule “\(r.name)”")
            case .changed: out.append("~ Changed rule “\(r.name)”" + (r.moved ? " (also moved)" : ""))
            }
            out += r.fields.map(line)
        }
        return out.joined(separator: "\n")
    }

    /// Compares two versions of a profile by number (defaults: the one before `to`, and the current one).
    public static func versions(_ detail: ProfileDetail, from: Int?, to: Int?) throws -> (ProfileVersionInfo, ProfileVersionInfo) {
        struct Missing: Error, CustomStringConvertible { let description: String }
        let byNumber = Dictionary(detail.versions.map { ($0.number, $0) }, uniquingKeysWith: { x, _ in x })
        let toNumber = to ?? detail.current.number
        guard let b = byNumber[toNumber] else { throw Missing(description: "no version \(toNumber) (the profile has v1–v\(detail.current.number))") }
        let fromNumber = from ?? (toNumber - 1)
        guard let a = byNumber[fromNumber] else {
            throw Missing(description: fromNumber < 1 ? "v\(toNumber) is the first version: nothing to compare it with" : "no version \(fromNumber)")
        }
        return (a, b)
    }

    static func short(_ s: String) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ⏎ ")
        return one.count > 160 ? String(one.prefix(157)) + "…" : one
    }
}
