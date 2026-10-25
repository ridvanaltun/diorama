import DioramaCore
import Darwin
import Foundation

/// Finds the `claude` executable without depending on the caller's shell.
public enum ClaudeLocator {
    public static func find(configured: String?, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let fm = FileManager.default
        if let configured, !configured.isEmpty {
            let p = (configured as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: p) ? p : nil
        }
        let home = environment["HOME"] ?? NSHomeDirectory()
        var dirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin"]
        for d in dirs {
            let p = (d as NSString).appendingPathComponent("claude")
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    public static func version(at path: String) -> String? {
        let r = try? ProcessRunner.run(path, ["--version"], timeout: 20)
        guard let r, r.exitCode == 0 else { return nil }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Spawns processes with explicit environment, working directory and timeout.
public enum ProcessRunner {
    public struct Result: Sendable {
        public var exitCode: Int32
        public var stdout: String
        public var stderr: String
        public var timedOut: Bool
    }

    /// Synchronous helper for short commands.
    public static func run(_ path: String, _ args: [String], cwd: String? = nil, environment: [String: String]? = nil, timeout: TimeInterval) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if let environment { p.environment = environment }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        var stdoutData = Data(), stderrData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            stdoutData = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            stderrData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        while p.isRunning {
            if Date() > deadline {
                timedOut = true
                p.terminate()
                break
            }
            usleep(20_000)
        }
        p.waitUntilExit()
        _ = group.wait(timeout: .now() + 5)
        return Result(exitCode: p.terminationStatus, stdout: String(decoding: stdoutData, as: UTF8.self), stderr: String(decoding: stderrData, as: UTF8.self), timedOut: timedOut)
    }
}

/// A process whose stdout is streamed to a file, cancellable from another task.
final class TrialProcess: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var terminatedByUs = false

    init(path: String, args: [String], cwd: String, environment: [String: String], stdout: URL, stderr: URL) throws {
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = environment
        FileManager.default.createFile(atPath: stdout.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: stderr.path, contents: nil, attributes: [.posixPermissions: 0o600])
        process.standardOutput = try FileHandle(forWritingTo: stdout)
        process.standardError = try FileHandle(forWritingTo: stderr)
        process.standardInput = FileHandle.nullDevice
    }

    func start() throws { try process.run() }

    func terminate() {
        lock.withLock { terminatedByUs = true }
        if process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [process] in
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    var wasTerminated: Bool { lock.withLock { terminatedByUs } }

    /// Waits for exit or `timeout`; returns (exit code, timed out).
    func wait(timeout: TimeInterval) async -> (Int32, Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Task.isCancelled {
                terminate()
                break
            }
            if Date() > deadline {
                terminate()
                while process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
                return (process.terminationStatus, true)
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        while process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        return (process.terminationStatus, false)
    }
}

/// Copies a project folder for an isolated trial (APFS clone when possible).
public enum ProjectCloner {
    public static func clone(_ source: URL, to dest: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        // clonefile(2) clones a whole directory tree copy-on-write on APFS.
        if clonefile(source.path, dest.path, 0) == 0 { return }
        try fm.copyItem(at: source, to: dest)
    }

    /// Stable identity of a project's contents: git HEAD + dirty-state hash, or a tree hash.
    public static func snapshotIdentity(_ dir: URL) -> String {
        if let git = gitIdentity(dir) { return git }
        return "tree:" + treeHash(dir)
    }

    static func gitIdentity(_ dir: URL) -> String? {
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) else { return nil }
        guard let head = try? ProcessRunner.run("/usr/bin/git", ["-C", dir.path, "rev-parse", "HEAD"], timeout: 10), head.exitCode == 0 else { return nil }
        let status = (try? ProcessRunner.run("/usr/bin/git", ["-C", dir.path, "status", "--porcelain"], timeout: 10))?.stdout ?? ""
        let sha = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return status.isEmpty ? "git:\(sha)" : "git:\(sha)+dirty:\(Hashing.sha256Hex(status).prefix(12))"
    }

    /// Hash of every regular file's path and content (bounded).
    public static func treeHash(_ dir: URL, limit: Int = 5000) -> String {
        fileHashes(dir, limit: limit).sorted { $0.key < $1.key }.map { "\($0.key)\t\($0.value)" }.joined(separator: "\n").sha256Short
    }

    public static func fileHashes(_ dir: URL, limit: Int = 5000) -> [String: String] {
        var out: [String: String] = [:]
        let fm = FileManager.default
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: []) else { return out }
        let base = dir.standardizedFileURL.path
        for case let url as URL in e {
            if url.lastPathComponent == ".git" { e.skipDescendants(); continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let rel = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            if size > 20_000_000 {
                out[rel] = "size:\(size)"
            } else if let d = try? Data(contentsOf: url) {
                out[rel] = Hashing.sha256Hex(Array(d)).prefix(16).description
            }
            if out.count >= limit { break }
        }
        return out
    }
}

extension String {
    var sha256Short: String { String(Hashing.sha256Hex(self).prefix(24)) }
}

/// SplitMix64 — tiny, seedable, reproducible.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
