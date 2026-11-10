import ArgumentParser
import DioramaClient
import DioramaCore
import Foundation

struct Storage: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show how much space Diorama's data uses, and permanently delete old archived data.",
        subcommands: [Show.self, Purge.self], defaultSubcommand: Show.self)

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Sizes and counts of what the data folder holds.")
        @OptionGroup var global: GlobalOptions
        @Flag var json = false
        func run() async throws {
            let u = try await global.client().storageUsage()
            if json { return try printJSON(u) }
            print("Data folder: \(abbreviatingHome(global.paths.home.path))")
            print("  Database:  \(Storage.bytes(u.databaseBytes))")
            print("  Blobs:     \(Storage.bytes(u.blobBytes))  (captured bodies, tool results, rewrites, transcripts)")
            print("  Total:     \(Storage.bytes(u.totalBytes))")
            print("Sessions: \(u.sessions) (\(u.archivedSessions) archived) · Experiments: \(u.experiments) (\(u.archivedExperiments) archived)")
            print("Tool results decided: \(u.decisions) · Requests recorded: \(u.exchanges)")
            if u.archivedSessions + u.archivedExperiments > 0 {
                print("Free space with `diorama storage purge --older-than 30`.")
            }
        }
    }

    struct Purge: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Permanently delete archived sessions and experiments older than N days.",
            discussion: """
                Only archived items go: sessions with their requests, tool results, rewrites, events and
                search entries; experiments with their runs, trials and trial sessions. Running sessions and
                experiments with a run in progress are skipped. Rewrite costs stay in the spending history.
                This can't be undone. Shows what would go and asks first, unless --yes.
                """)
        @OptionGroup var global: GlobalOptions
        @Option(help: "Delete archived items created more than this many days ago (at least 1).") var olderThan: Int
        @Flag(help: "Show what would be deleted, and stop.") var dryRun = false
        @Flag(help: "Don't ask for confirmation.") var yes = false

        func validate() throws {
            guard olderThan >= 1 else { throw ValidationError("--older-than must be at least 1") }
        }

        func run() async throws {
            let client = try await global.client()
            let plan = try await client.purgeArchived(PurgeRequest(olderThanDays: olderThan, dryRun: true))
            if plan.isEmpty { return print("Nothing to delete: no archived sessions or experiments older than \(olderThan) days.") }
            print("Archived and older than \(olderThan) days:")
            print("  \(plan.sessions) session(s): \(plan.exchanges) request(s), \(plan.decisions) tool result(s) across them and the trials below")
            print("  \(plan.experiments) experiment(s): \(plan.runs) run(s), \(plan.trialSessions) trial session(s)")
            if dryRun { return }
            if !yes {
                print("\nDelete them permanently? This can't be undone. Type 'yes' to confirm: ", terminator: "")
                guard readLine()?.trimmingCharacters(in: .whitespaces).lowercased() == "yes" else { return print("Nothing deleted.") }
            }
            let r = try await client.purgeArchived(PurgeRequest(olderThanDays: olderThan))
            print("✓ Deleted \(r.sessions) session(s) and \(r.experiments) experiment(s); freed \(Storage.bytes(r.bytesFreed)).")
        }
    }
}
