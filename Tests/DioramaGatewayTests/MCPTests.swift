import DioramaClient
import DioramaCore
import Foundation
import Testing
@testable import DioramaGateway

@Suite struct MCPServerTests {
    func call(_ server: MCPServer, _ id: Int, _ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        let msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: msg), as: UTF8.self)
        let reply = try #require(await server.handle(line))
        return try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
    }

    func tool(_ server: MCPServer, _ name: String, _ args: [String: Any] = [:]) async throws -> (text: String, isError: Bool) {
        let r = try await call(server, 9, "tools/call", ["name": name, "arguments": args])
        let result = try #require(r["result"] as? [String: Any], "\(r)")
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (text, result["isError"] as? Bool ?? false)
    }

    @Test func handshakeAndToolList() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        let server = MCPServer(cliPath: "/x/diorama", hookRegistry: HookRegistry(paths: DioramaPaths(home: env.home))) { env.client }
        let ini = try await call(server, 1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "t", "version": "1"]])
        let result = try #require(ini["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "diorama")
        #expect((result["instructions"] as? String)?.contains("estimate_experiment_run") == true)
        // Unknown versions get the server's preferred one.
        let other = try await call(server, 2, "initialize", ["protocolVersion": "1999-01-01"])
        #expect((other["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18")
        // Notifications get no reply; unknown methods and bad JSON get JSON-RPC errors.
        #expect(await server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(((try await call(server, 3, "resources/list"))["error"] as? [String: Any])?["code"] as? Int == -32601)
        #expect(await server.handle("{oops")?.contains("-32700") == true)

        let list = try #require((try await call(server, 4, "tools/list"))["result"] as? [String: Any])
        let tools = try #require(list["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        #expect(names.isSuperset(of: ["list_sessions", "get_decision", "create_profile", "install_hook", "estimate_experiment_run", "start_experiment_run"]))
        let start = try #require(tools.first { $0["name"] as? String == "start_experiment_run" })
        #expect((start["annotations"] as? [String: Any])?["openWorldHint"] as? Bool == true)
        #expect((start["description"] as? String)?.contains("SPENDS MONEY") == true)

        let ro = MCPServer(cliPath: "/x/diorama", hookRegistry: HookRegistry(paths: DioramaPaths(home: env.home)), readOnly: true) { env.client }
        let roList = try #require((try await call(ro, 5, "tools/list"))["result"] as? [String: Any])
        let roNames = Set((roList["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
        #expect(roNames.contains("get_session") && !roNames.contains("create_profile") && !roNames.contains("start_experiment_run"))
        let refused = try await call(ro, 6, "tools/call", ["name": "create_profile", "arguments": ["profile": ["name": "x"]]])
        #expect((refused["error"] as? [String: Any])?["code"] as? Int == -32602)
    }

    @Test func toolsReadAndChangeDiorama() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        let server = MCPServer(cliPath: "/Apps/Diorama.app/Contents/Helpers/diorama", hookRegistry: HookRegistry(paths: DioramaPaths(home: env.home))) { env.client }

        #expect(try await tool(server, "list_sessions").text == "No sessions yet.")
        let created = try await tool(server, "create_profile", ["profile": [
            "name": "Docs steer", "rules": [["name": "Rename", "match": ["tools": ["WebFetch"]], "instructions": "Rename the domain"]],
        ]])
        #expect(!created.isError, "\(created.text)")
        #expect(try await tool(server, "list_profiles").text.contains("“Docs steer” v1"))
        let profile = try await tool(server, "get_profile", ["profile": "Docs steer"])
        #expect(profile.text.contains("Rename the domain"))

        #expect(try await tool(server, "get_rule_stats", ["profile": "Docs steer", "days": 7]).text.contains("Rename\n  never matched"))
        let bad = try await tool(server, "create_profile", ["profile": "not an object"])
        #expect(bad.isError && bad.text.contains("must be a JSON object"))
        let missing = try await tool(server, "get_session", [:])
        #expect(missing.isError && missing.text.contains("session_id"))

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("diorama-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let unknown = try await tool(server, "install_hook", ["folder": folder.path, "profile": "nope"])
        #expect(unknown.isError && unknown.text.contains("unknown profile"))
        #expect(!(try await tool(server, "install_hook", ["folder": folder.path, "profile": "Docs steer"])).isError)
        let status = try await tool(server, "get_hook_status", ["folder": folder.path])
        #expect(status.text.contains("profile \"Docs steer\"") && status.text.contains("'/Apps/Diorama.app/Contents/Helpers/diorama' hook run --config hk_"))
        #expect(try !String(contentsOf: HookInstaller.projectSettings(folder.path), encoding: .utf8).contains("Docs steer"))
        #expect(try await tool(server, "uninstall_hook", ["folder": folder.path]).text.hasPrefix("Removed"))

        let launch = try await env.client.createSession(SessionSpec(name: "via mcp", cwd: "/tmp"))
        #expect(try await tool(server, "list_sessions").text.contains("“via mcp”"))
        #expect(try await tool(server, "get_session", ["session_id": launch.session.id]).text.contains("Tool results: 0"))
        #expect(try await tool(server, "set_steering_paused", ["paused": true, "session_id": launch.session.id]).text.hasPrefix("Steering paused for “via mcp”"))
        #expect(try await env.client.session(launch.session.id).isPaused)
        #expect(try await tool(server, "set_steering_paused", ["paused": true]).text == "Steering paused everywhere.")
        #expect(try await env.client.settings().steeringPaused)
        _ = try await tool(server, "set_steering_paused", ["paused": false])
        #expect(try await !env.client.settings().steeringPaused)
        #expect(try await tool(server, "end_session", ["session_id": launch.session.id]).text.contains("ended"))

        // Starting a run without a valid prepared run and token fails as a readable tool error.
        let start = try await tool(server, "start_experiment_run", ["run_id": "run_missing", "confirmation_token": "x"])
        #expect(start.isError)
    }

    @Test func desktopConfigKeepsOtherServers() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("diorama-mcp-\(UUID().uuidString)/claude_desktop_config.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"mcpServers":{"other":{"command":"x"}},"globalShortcut":"Cmd+Space"}"#.write(to: url, atomically: true, encoding: .utf8)
        try MCPInstaller.installDesktop(cli: "/x/diorama", readOnly: true, config: url)
        #expect(MCPInstaller.isInstalledInDesktop(config: url))
        var root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let servers = try #require(root["mcpServers"] as? [String: [String: Any]])
        #expect(servers["other"]?["command"] as? String == "x")
        #expect(servers["diorama"]?["args"] as? [String] == ["mcp", "serve", "--read-only"])
        #expect(root["globalShortcut"] as? String == "Cmd+Space")
        #expect(try MCPInstaller.uninstallDesktop(config: url))
        root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect((root["mcpServers"] as? [String: Any])?.keys.sorted() == ["other"])
        #expect(try !MCPInstaller.uninstallDesktop(config: url))
    }
}
