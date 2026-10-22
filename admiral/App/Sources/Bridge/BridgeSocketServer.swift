import Foundation
import Darwin
import AdmiralCore

/// Serves Admiral's `MCPServer` over a loopback Unix-domain socket so the external
/// `bridge_mcp` (running inside an Admiral-hosted claude) can drive Admiral's sessions —
/// roster / hail / broadcast / commission / set_goal — over the app's live registry.
///
/// Protocol: one newline-terminated JSON line per connection,
/// `{"token": "<ADMIRAL_SESSION>", "request": <jsonrpc>}` → JSON response line.
@MainActor
final class BridgeSocketServer {
    private let mcp: MCPServer
    let path: String
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "admiral.bridge.socket", qos: .utility)

    init(mcp: MCPServer, path: String = BridgeSocketServer.defaultPath) {
        self.mcp = mcp
        self.path = path
    }

    /// Fixed, well-known path the Python bridge derives the same way
    /// (`~/Library/Application Support/Admiral/bridge.sock`).
    nonisolated static var defaultPath: String {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Admiral", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("bridge.sock").path
    }

    func start() {
        unlink(path)  // a stale socket file would make bind() fail
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        // Close-on-exec: the always-on bridge listener must not leak into every spawned session.
        SocketFD.setCloseOnExec(fd)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)  // NUL-terminated
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= capacity else { close(fd); return }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            pathBytes.withUnsafeBytes { src in
                dst.copyMemory(from: UnsafeRawBufferPointer(start: src.baseAddress, count: src.count))
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); return }
        listenFD = fd
        queue.async { [weak self] in self?.acceptLoop(fd) }
    }

    func stop() {
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(path)
    }

    private nonisolated func acceptLoop(_ fd: Int32) {
        while true {
            let conn = accept(fd, nil, nil)
            if conn < 0 { break }  // listener closed
            SocketFD.setCloseOnExec(conn)
            handleConnection(conn)
        }
    }

    /// Read one line, run it on the main actor (BridgeCore touches SessionManager), reply.
    private nonisolated func handleConnection(_ conn: Int32) {
        defer { close(conn) }
        var request = Data()
        var byte: UInt8 = 0
        while request.count < 1 << 20 {  // 1 MB safety cap
            let n = read(conn, &byte, 1)
            if n <= 0 { return }
            if byte == 0x0A { break }     // newline = end of request
            request.append(byte)
        }
        guard !request.isEmpty else { return }
        let response = DispatchQueue.main.sync { MainActor.assumeIsolated { self.mcp.handle(envelope: request) } }
        var out = response
        out.append(0x0A)
        out.withUnsafeBytes { _ = write(conn, $0.baseAddress, out.count) }
    }
}
