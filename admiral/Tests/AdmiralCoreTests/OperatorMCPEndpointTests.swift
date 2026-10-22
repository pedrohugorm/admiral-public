import XCTest
@testable import AdmiralCore

@MainActor
final class OperatorMCPEndpointTests: XCTestCase {
    private let token = "adm_test_token_please"

    private func makeEndpoint() -> OperatorMCPEndpoint {
        let host = FakeTerminalHost()
        let manager = SessionManager(
            host: host,
            claudeHome: URL(fileURLWithPath: "/tmp/admiral-none"),
            executablePath: "/bin/echo"
        )
        manager.register(AgentSession(callsign: "alice", cwd: "/a", token: "A"),
                         handle: FakeTerminalHost.Handle(pid: 1))
        let bridge = BridgeCore(manager: manager, idGenerator: { "id123" })
        return OperatorMCPEndpoint(mcp: MCPServer(bridge: bridge), expectedToken: token)
    }

    private func request(method: String, path: String, headers: [String: String] = [:],
                         body: Data = Data()) -> HTTPRequest {
        HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    private func jsonRPCToolsList() -> Data {
        Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)
    }

    func testTokenUnavailableGives503ThenWorksOnceResolvedWithoutNewEndpoint() {
        let provider = OperatorTokenProvider()  // Keychain not resolved yet
        let host = FakeTerminalHost()
        let manager = SessionManager(host: host, claudeHome: URL(fileURLWithPath: "/tmp/admiral-none"),
                                     executablePath: "/bin/echo")
        let ep = OperatorMCPEndpoint(mcp: MCPServer(bridge: BridgeCore(manager: manager, idGenerator: { "id" })),
                                     tokenProvider: provider)
        let anon = request(method: "POST", path: "/mcp", body: jsonRPCToolsList())
        let authed = request(method: "POST", path: "/mcp", headers: ["authorization": "Bearer adm_x"],
                             body: jsonRPCToolsList())
        // No token yet: 503 for everyone (never a hang, never a misleading 401, never open).
        XCTAssertTrue((String(data: ep.handle(anon), encoding: .utf8) ?? "").hasPrefix("HTTP/1.1 503"))
        XCTAssertTrue((String(data: ep.handle(authed), encoding: .utf8) ?? "").hasPrefix("HTTP/1.1 503"))
        provider.token = "adm_x"  // resolved in the background — same endpoint instance
        XCTAssertTrue((String(data: ep.handle(anon), encoding: .utf8) ?? "").hasPrefix("HTTP/1.1 401"))
        XCTAssertTrue((String(data: ep.handle(authed), encoding: .utf8) ?? "").hasPrefix("HTTP/1.1 200"))
        provider.token = "adm_y"  // rotation applies immediately too
        XCTAssertTrue((String(data: ep.handle(authed), encoding: .utf8) ?? "").hasPrefix("HTTP/1.1 401"))
    }

    func testRejectsMissingAuth() {
        let ep = makeEndpoint()
        let raw = ep.handle(request(method: "POST", path: "/mcp", body: jsonRPCToolsList()))
        let text = String(data: raw, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("401"), text)
        XCTAssertTrue(text.contains("unauthorized"), text)
    }

    func testAcceptsBearerAndListsTools() {
        let ep = makeEndpoint()
        let raw = ep.handle(request(
            method: "POST", path: "/mcp",
            headers: ["authorization": "Bearer \(token)", "content-length": "0"],
            body: jsonRPCToolsList()
        ))
        let text = String(data: raw, encoding: .utf8) ?? ""
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200"), text)
        XCTAssertTrue(text.contains("list_sessions"), text)
        XCTAssertTrue(text.contains("inject"), text)
    }

    func testWrongPath404() {
        let ep = makeEndpoint()
        let raw = ep.handle(request(
            method: "POST", path: "/v1/messages",
            headers: ["authorization": "Bearer \(token)"],
            body: jsonRPCToolsList()
        ))
        let text = String(data: raw, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("404"), text)
    }

    func testTokenStoreMintsOnceIntoKeychainOnly() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("admiral-op-token-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = FakeMirror()
        let a = OperatorTokenStore.resolve(base: dir, mirror: m).token
        let b = OperatorTokenStore.resolve(base: dir, mirror: m).token
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.hasPrefix("adm_"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: OperatorTokenStore.legacyTokenFile(base: dir).path))
    }
}
