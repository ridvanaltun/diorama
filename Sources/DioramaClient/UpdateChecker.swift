import DioramaCore
import Foundation

public struct UpdateInfo: Sendable, Codable {
    public var current: String
    public var latest: String
    public var isNewer: Bool
    public var pageURL: String
    public var publishedAt: String?
    public var notes: String
    public var zipAssetName: String?
    public var zipDownloadURL: String?
}

/// Checks GitHub Releases for a newer Diorama. Uses the public API first; for a private
/// repository (404) it falls back to the `gh` CLI when available and signed in.
public enum UpdateChecker {
    public static var repository: String {
        ProcessInfo.processInfo.environment["DIORAMA_UPDATE_REPO"] ?? DioramaVersion.repository
    }

    public static func check(current: String = DioramaVersion.current) async throws -> UpdateInfo {
        let json = try await latestReleaseJSON()
        guard let obj = try JSONSerialization.jsonObject(with: json) as? [String: Any], let tag = obj["tag_name"] as? String else {
            throw ClientError("unexpected response from GitHub")
        }
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = obj["assets"] as? [[String: Any]] ?? []
        let zip = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
        return UpdateInfo(
            current: current, latest: latest, isNewer: compare(latest, current) > 0, pageURL: obj["html_url"] as? String ?? "",
            publishedAt: obj["published_at"] as? String, notes: obj["body"] as? String ?? "", zipAssetName: zip?["name"] as? String,
            zipDownloadURL: zip?["browser_download_url"] as? String)
    }

    static func latestReleaseJSON() async throws -> Data {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "accept")
        req.setValue("diorama/\(DioramaVersion.current)", forHTTPHeaderField: "user-agent")
        req.timeoutInterval = 10
        if let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 {
            return data
        }
        // Private repository (or rate limited): try the signed-in GitHub CLI.
        guard let gh = findGH() else {
            throw ClientError("could not read releases of \(repository) (private repository? install and sign in to the GitHub CLI `gh`)")
        }
        let repo = repository
        let out = try await offloadBlocking { try runGH(gh, ["api", "repos/\(repo)/releases/latest"]) }
        return Data(out.utf8)
    }

    /// Downloads the release zip into `directory` and verifies it against the release's
    /// `.sha256` asset. Returns the zip's path.
    public static func download(_ info: UpdateInfo, to directory: URL) async throws -> URL {
        guard let name = info.zipAssetName else { throw ClientError("the latest release has no zip asset") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = directory.appendingPathComponent(name)
        let shaName = name + ".sha256"
        if let gh = findGH() {
            let args = ["release", "download", "v\(info.latest)", "--repo", repository, "--pattern", name, "--pattern", shaName, "--dir", directory.path, "--clobber"]
            _ = try await offloadBlocking { try runGH(gh, args) }
        } else if let urlString = info.zipDownloadURL, let url = URL(string: urlString) {
            let (tmp, _) = try await URLSession.shared.download(from: url)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            if let shaURL = URL(string: urlString + ".sha256"), let (shaData, _) = try? await URLSession.shared.data(from: shaURL) {
                try shaData.write(to: directory.appendingPathComponent(shaName))
            }
        } else {
            throw ClientError("no download URL")
        }
        let shaFile = directory.appendingPathComponent(shaName)
        guard let expected = (try? String(contentsOf: shaFile, encoding: .utf8))?.split(separator: " ").first.map(String.init) else {
            throw ClientError("downloaded \(name) but its checksum file is missing; not trusting it")
        }
        let actual = Hashing.sha256Hex(Array(try Data(contentsOf: dest)))
        guard actual == expected else {
            try? FileManager.default.removeItem(at: dest)
            throw ClientError("checksum mismatch for \(name); the download was deleted")
        }
        return dest
    }

    /// Semantic-version comparison (prerelease suffixes sort before the release).
    public static func compare(_ a: String, _ b: String) -> Int {
        func parts(_ v: String) -> ([Int], String?) {
            let split = v.split(separator: "-", maxSplits: 1).map(String.init)
            return (split[0].split(separator: ".").map { Int($0) ?? 0 }, split.count > 1 ? split[1] : nil)
        }
        let (na, pa) = parts(a), (nb, pb) = parts(b)
        for i in 0..<max(na.count, nb.count) {
            let x = i < na.count ? na[i] : 0, y = i < nb.count ? nb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        switch (pa, pb) {
        case (nil, nil): return 0
        case (nil, _): return 1
        case (_, nil): return -1
        case (let x?, let y?): return x == y ? 0 : (x < y ? -1 : 1)
        }
    }

    static func findGH() -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func runGH(_ gh: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gh)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw ClientError("gh \(args.prefix(2).joined(separator: " ")) failed: \(String(decoding: errData, as: UTF8.self).prefix(200))")
        }
        return String(decoding: data, as: UTF8.self)
    }
}
