import DioramaCore
import Foundation

/// Content-addressed, LZFSE-compressed blob storage. Identical content is stored once.
public final class BlobStore: @unchecked Sendable {
    public let root: URL
    private let fm = FileManager.default

    public init(root: URL) throws {
        self.root = root
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    func url(for hash: String) -> URL {
        let a = hash.prefix(2), b = hash.dropFirst(2).prefix(2)
        return root.appendingPathComponent(String(a), isDirectory: true)
            .appendingPathComponent(String(b), isDirectory: true)
            .appendingPathComponent(hash + ".lzfse")
    }

    /// Stores bytes and returns their sha256 key.
    @discardableResult
    public func put(_ bytes: [UInt8]) throws -> String {
        let hash = Hashing.sha256Hex(bytes)
        let dest = url(for: hash)
        if fm.fileExists(atPath: dest.path) { return hash }
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let raw = Data(bytes)
        let stored: Data
        if raw.isEmpty {
            stored = Data()
        } else {
            stored = try (raw as NSData).compressed(using: .lzfse) as Data
        }
        let tmp = dest.appendingPathExtension("tmp-\(UUID().uuidString)")
        guard fm.createFile(atPath: tmp.path, contents: stored, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tmp.path])
        }
        if fm.fileExists(atPath: dest.path) {
            try? fm.removeItem(at: tmp)
        } else {
            do {
                try fm.moveItem(at: tmp, to: dest)
            } catch {
                try? fm.removeItem(at: tmp)
                if !fm.fileExists(atPath: dest.path) { throw error }
            }
        }
        return hash
    }

    public func put(_ string: String) throws -> String { try put(Array(string.utf8)) }

    public func get(_ hash: String) throws -> [UInt8] {
        let data = try Data(contentsOf: url(for: hash))
        if data.isEmpty { return [] }
        let raw = try (data as NSData).decompressed(using: .lzfse) as Data
        return Array(raw)
    }

    public func getString(_ hash: String) throws -> String { String(decoding: try get(hash), as: UTF8.self) }

    public func exists(_ hash: String) -> Bool { fm.fileExists(atPath: url(for: hash).path) }

    /// Deletes every blob whose hash is not in `keep` and that is older than `minAge`
    /// (young blobs may belong to a row that is about to be inserted). Returns files removed.
    @discardableResult
    public func collectGarbage(keep: Set<String>, minAge: TimeInterval = 3600) -> Int {
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return 0 }
        var removed = 0
        let cutoff = Date().addingTimeInterval(-minAge)
        for case let file as URL in e where file.pathExtension == "lzfse" {
            let hash = file.deletingPathExtension().lastPathComponent
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if !keep.contains(hash), modified < cutoff {
                try? fm.removeItem(at: file)
                removed += 1
            }
        }
        return removed
    }

    public func totalBytes() -> Int64 {
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in e {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
