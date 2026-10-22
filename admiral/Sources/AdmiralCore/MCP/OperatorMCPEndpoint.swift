import Foundation

/// HTTP front door for operator MCP: `POST /mcp` with `Authorization: Bearer <token>`.
/// Same `MCPServer` the Unix-socket BridgeMCP uses — full tool list (no Claude hide filter).
@MainActor
public struct OperatorMCPEndpoint {
    private let mcp: MCPServer
    private let tokenProvider: OperatorTokenProvider

    /// `tokenProvider` is read per request, so the token can arrive after the server is up
    /// (until then guarded routes answer 503 "token unavailable").
    public init(mcp: MCPServer, tokenProvider: OperatorTokenProvider) {
        self.mcp = mcp
        self.tokenProvider = tokenProvider
    }

    public init(mcp: MCPServer, expectedToken: String) {
        self.init(mcp: mcp, tokenProvider: OperatorTokenProvider(expectedToken))
    }

    /// True when the request path is the operator MCP endpoint.
    public static func isMCPPath(_ path: String) -> Bool {
        let p = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        return p == "/mcp" || p == "/mcp/"
    }

    public func handle(_ request: HTTPRequest) -> Data {
        guard Self.isMCPPath(request.path) else {
            return Self.jsonError(status: 404, code: -32000, message: "not found: \(request.path)")
        }
        guard request.method == "POST" else {
            return Self.jsonError(status: 405, code: -32600,
                                  message: "use POST /mcp with a JSON-RPC body")
        }
        switch OperatorAuthResult.check(request, expected: tokenProvider.token) {
        case .ok: break
        case .unavailable:
            return Self.jsonError(status: 503, code: -32002,
                                  message: "token unavailable — the operator token is still being resolved from the Keychain; retry shortly")
        case .unauthorized:
            return Self.jsonError(status: 401, code: -32001,
                                  message: "unauthorized — Authorization: Bearer <operator-token>")
        }
        // Notifications (no id) return empty body with 202 in some transports; we still
        // run handle which returns empty Data for notifications.
        let response = mcp.handle(
            requestData: request.body,
            sessionToken: OperatorTokenStore.mcpSessionToken
        )
        if response.isEmpty {
            return HTTPWire.response(status: 202, body: Data())
        }
        return HTTPWire.response(status: 200, body: response)
    }

    /// The operator token check, shared by every route it guards (`/mcp`, the session
    /// event stream): `Authorization: Bearer <token>` or `X-Admiral-Operator-Token`.
    static func isAuthorized(_ request: HTTPRequest, token expectedToken: String) -> Bool {
        if let auth = request.headers["authorization"],
           auth.lowercased().hasPrefix("bearer ") {
            let token = String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            return timingSafeEqual(token, expectedToken)
        }
        if let header = request.headers["x-admiral-operator-token"] {
            return timingSafeEqual(header.trimmingCharacters(in: .whitespaces), expectedToken)
        }
        return false
    }

    private static func timingSafeEqual(_ a: String, _ b: String) -> Bool {
        let aa = Array(a.utf8), bb = Array(b.utf8)
        guard aa.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in aa.indices { diff |= aa[i] ^ bb[i] }
        return diff == 0
    }

    private static func jsonError(status: Int, code: Int, message: String) -> Data {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": NSNull(),
            "error": ["code": code, "message": message],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        return HTTPWire.response(status: status, body: data)
    }
}
