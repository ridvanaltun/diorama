import Foundation
import SQLite3

public enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob([UInt8])
}

public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

public struct Row: Sendable {
    let columns: [String: Int]
    let values: [SQLValue]

    public subscript(_ name: String) -> SQLValue {
        guard let i = columns[name] else { return .null }
        return values[i]
    }

    public func string(_ name: String) -> String? {
        switch self[name] {
        case .text(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        default: return nil
        }
    }

    public func int(_ name: String) -> Int64? {
        switch self[name] {
        case .int(let i): return i
        case .double(let d): return Int64(d)
        case .text(let s): return Int64(s)
        default: return nil
        }
    }

    public func double(_ name: String) -> Double? {
        switch self[name] {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }

    public func bool(_ name: String) -> Bool { (int(name) ?? 0) != 0 }

    public func date(_ name: String) -> Date? { double(name).map { Date(timeIntervalSince1970: $0) } }
}

/// Minimal thread-safe SQLite wrapper (serialized access through a lock).
public final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    public let path: String

    public init(path: String) throws {
        self.path = path
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw SQLiteError(code: rc, message: msg)
        }
        handle = db
        sqlite3_busy_timeout(db, 5000)
        try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }

    deinit { sqlite3_close_v2(handle) }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        sqlite3_close_v2(handle)
        handle = nil
    }

    private func error(_ rc: Int32) -> SQLiteError {
        SQLiteError(code: rc, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed")
    }

    public func execute(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteError(code: rc, message: msg)
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepare(_ sql: String, _ params: [SQLValue]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw error(rc) }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            let brc: Int32
            switch p {
            case .null: brc = sqlite3_bind_null(stmt, idx)
            case .int(let v): brc = sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): brc = sqlite3_bind_double(stmt, idx, v)
            case .text(let v): brc = sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            case .blob(let v):
                brc = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32($0.count), Self.transient) }
            }
            if brc != SQLITE_OK {
                sqlite3_finalize(stmt)
                throw error(brc)
            }
        }
        return stmt
    }

    /// Runs a statement; returns the last insert rowid.
    @discardableResult
    public func run(_ sql: String, _ params: [SQLValue] = []) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw error(rc) }
        return sqlite3_last_insert_rowid(handle)
    }

    public var changes: Int {
        lock.lock()
        defer { lock.unlock() }
        return Int(sqlite3_changes(handle))
    }

    public func query(_ sql: String, _ params: [SQLValue] = []) throws -> [Row] {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var columns: [String: Int] = [:]
        let count = sqlite3_column_count(stmt)
        for i in 0..<count { columns[String(cString: sqlite3_column_name(stmt, i))] = Int(i) }
        var rows: [Row] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error(rc) }
            var values: [SQLValue] = []
            values.reserveCapacity(Int(count))
            for i in 0..<count {
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: values.append(.int(sqlite3_column_int64(stmt, i)))
                case SQLITE_FLOAT: values.append(.double(sqlite3_column_double(stmt, i)))
                case SQLITE_TEXT: values.append(.text(String(cString: sqlite3_column_text(stmt, i))))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, i))
                    if let p = sqlite3_column_blob(stmt, i) {
                        values.append(.blob(Array(UnsafeRawBufferPointer(start: p, count: n))))
                    } else {
                        values.append(.blob([]))
                    }
                default: values.append(.null)
                }
            }
            rows.append(Row(columns: columns, values: values))
        }
        return rows
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public var userVersion: Int {
        (try? query("PRAGMA user_version").first?.int("user_version")).flatMap { $0 }.map(Int.init) ?? 0
    }

    public func quickCheck() -> Bool {
        (try? query("PRAGMA quick_check").first?.string("quick_check")) == "ok"
    }
}

extension SQLValue {
    public static func optional(_ s: String?) -> SQLValue { s.map { .text($0) } ?? .null }
    public static func optional(_ d: Double?) -> SQLValue { d.map { .double($0) } ?? .null }
    public static func optional(_ i: Int?) -> SQLValue { i.map { .int(Int64($0)) } ?? .null }
    public static func date(_ d: Date?) -> SQLValue { d.map { .double($0.timeIntervalSince1970) } ?? .null }
}
