import Foundation
import Darwin

// admiral-bridge-mcp — the bridge MCP server, bundled inside Admiral and injected per
// session (via `--mcp-config`), so Admiral-hosted claudes reach THIS instance's bridge
// with no dependency on the external bridge package.
//
// It's a transparent MCP-over-stdio proxy to the app's own `MCPServer`, which is served on
// a loopback Unix socket by `BridgeSocketServer`. claude speaks newline-delimited JSON-RPC
// on stdin/stdout; for each message we wrap it in the socket envelope
// `{"token": <ADMIRAL_SESSION>, "request": <jsonrpc>}`, send it to the socket, and return
// the reply. Because tools/list, tools/call, and initialize are all answered by the one
// Swift `MCPServer`, the tool surface can never drift — this binary declares nothing, and
// filters nothing: the socket is always a session caller, so the app itself withholds the
// operator tools.
//
// The socket is chosen per instance via `ADMIRAL_SOCKET` (Admiral exports its own path,
// which is profile-aware), so a dev/test instance's sessions talk to that instance's bridge.

let token = ProcessInfo.processInfo.environment["ADMIRAL_SESSION"] ?? ""
let socketPath: String = ProcessInfo.processInfo.environment["ADMIRAL_SOCKET"] ?? {
    let base = (try? FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
    )) ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent("Admiral/bridge.sock").path
}()

/// One request/response round-trip over the Admiral bridge socket (one line each way).
func callSocket(_ envelope: Data) -> Data? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8CString)
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { dst in
        pathBytes.withUnsafeBytes { src in
            dst.copyMemory(from: UnsafeRawBufferPointer(start: src.baseAddress, count: src.count))
        }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) == 0 }
    }
    guard connected else { return nil }

    var out = envelope
    out.append(0x0A)
    out.withUnsafeBytes { _ = write(fd, $0.baseAddress, out.count) }

    var buf = Data()
    var byte: UInt8 = 0
    while buf.count < 16 << 20 {         // 16 MB safety cap
        let n = read(fd, &byte, 1)
        if n <= 0 { break }
        if byte == 0x0A { break }
        buf.append(byte)
    }
    return buf
}

func emit(_ data: Data) {
    var line = data
    line.append(0x0A)
    FileHandle.standardOutput.write(line)
}

// MCP stdio: one JSON-RPC message per line. Loop until claude closes stdin.
while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty,
          let msg = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    else { continue }

    let id = msg["id"]   // absent on notifications — those get no response
    let envelope = (try? JSONSerialization.data(withJSONObject: ["token": token, "request": msg])) ?? Data()
    let response = callSocket(envelope)

    guard let id else { continue }   // notification: forwarded, nothing to return

    guard let respData = response, !respData.isEmpty else {
        // Socket unreachable (Admiral not running / wrong instance): answer with a JSON-RPC
        // error so claude surfaces it instead of hanging on the request.
        let err: [String: Any] = [
            "jsonrpc": "2.0", "id": id,
            "error": ["code": -32000, "message": "Admiral bridge endpoint unavailable"],
        ]
        emit((try? JSONSerialization.data(withJSONObject: err)) ?? Data())
        continue
    }

    // The app already leaves the operator tools out of a session's tools/list (and refuses
    // them), so the reply is passed through untouched.
    emit(respData)
}
