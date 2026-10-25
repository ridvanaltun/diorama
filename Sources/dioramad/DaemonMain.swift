import DioramaCore
import DioramaGateway
import Darwin
import Foundation

/// dioramad — Diorama's background service (gateway, control API, rewrite engine, runner).
///
/// Usage: dioramad [--port N] [--exact-port] [--home DIR] [--upstream URL]
///                 [--rewrite-base-url URL] [--provider anthropic|offline]
struct DaemonArguments {
    var port = 47821
    var exactPort = false
    var home: String?
    var upstream: String?
    var rewriteBase: String?
    var provider = DioramaDaemon.ProviderKind.anthropic

    init(_ args: [String]) throws {
        var it = args.makeIterator()
        while let a = it.next() {
            func value() throws -> String {
                guard let v = it.next() else { throw ArgumentError(message: "\(a) needs a value") }
                return v
            }
            switch a {
            case "--port": port = Int(try value()) ?? port
            case "--exact-port": exactPort = true
            case "--home": home = try value()
            case "--upstream": upstream = try value()
            case "--rewrite-base-url": rewriteBase = try value()
            case "--provider":
                let v = try value()
                guard let p = DioramaDaemon.ProviderKind(rawValue: v) else { throw ArgumentError(message: "unknown provider \(v)") }
                provider = p
            case "--version":
                print("dioramad \(DioramaVersion.current)")
                exit(0)
            case "--help", "-h":
                print("usage: dioramad [--port N] [--exact-port] [--home DIR] [--upstream URL] [--rewrite-base-url URL] [--provider anthropic|offline]")
                exit(0)
            default: throw ArgumentError(message: "unknown argument \(a)")
            }
        }
    }
}

struct ArgumentError: Error, CustomStringConvertible { let message: String; var description: String { message } }

func log(_ s: String) {
    FileHandle.standardError.write(Data("[\(DateFormatting.string(Date()))] dioramad: \(s)\n".utf8))
}

@main
struct Main {
    static func main() async {
        // Everything the daemon writes (database, WAL, blobs, logs) is private to the user.
        umask(0o077)
        signal(SIGHUP, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)
        let args: DaemonArguments
        do { args = try DaemonArguments(Array(CommandLine.arguments.dropFirst())) } catch {
            log("\(error)")
            exit(64)
        }
        var env = ProcessInfo.processInfo.environment
        if let h = args.home { env["DIORAMA_HOME"] = h }
        var options = DioramaDaemon.Options(paths: DioramaPaths.default(environment: env))
        options.port = args.port
        options.exactPort = args.exactPort
        options.provider = args.provider
        options.environment = env
        if let u = args.upstream, let url = URL(string: u) { options.upstream = url }
        if let r = args.rewriteBase, let url = URL(string: r) { options.rewriteBaseURL = url }
        let daemon: DioramaDaemon
        do {
            daemon = try DioramaDaemon(options: options)
            let port = try await daemon.start()
            log("listening on 127.0.0.1:\(port) (data: \(options.paths.home.path), upstream: \(options.upstream.absoluteString), provider: \(options.provider.rawValue))")
        } catch {
            log("failed to start: \(error)")
            exit(1)
        }
        let signals = [SIGTERM, SIGINT].map { sig -> DispatchSourceSignal in
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                log("received signal \(sig), shutting down")
                // Hard limit: never linger after a termination signal.
                DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                    log("shutdown took longer than 10s; exiting")
                    exit(0)
                }
                Task {
                    await daemon.stop()
                    log("stopped")
                    exit(0)
                }
            }
            src.resume()
            return src
        }
        do { try await daemon.run() } catch { log("server error: \(error)") }
        await daemon.stop()
        _ = signals
        log("stopped")
        exit(0)
    }
}
