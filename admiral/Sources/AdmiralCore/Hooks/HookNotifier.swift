import Foundation
import Darwin

/// Hands a hook's notification to the running app. The hook helper is a separate process, so
/// it speaks to the app over the bridge socket (`ADMIRAL_SOCKET`): a `tools/call` of the
/// bridge `notify` tool with an internal `kind`, which the app turns into
/// `NotificationService.post`. Best effort and bounded — a missing app or a stuck socket
/// costs at most `timeout` seconds and never changes what claude does.
public enum HookNotifier {
    public static let timeout: TimeInterval = 1.5

    public static func socketPath(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let path = env["ADMIRAL_SOCKET"], !path.isEmpty { return path }
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Admiral/bridge.sock").path
    }

    /// The socket envelope for one notification.
    public static func envelope(_ note: HookNotification, token: String) -> Data {
        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "notify", "arguments": [
                "kind": note.kind.rawValue, "title_suffix": note.titleSuffix, "body": note.body,
            ]],
        ]
        return (try? JSONSerialization.data(withJSONObject: ["token": token, "request": request])) ?? Data()
    }

    public static func send(_ note: HookNotification, token: String) {
        send(envelope(note, token: token), to: socketPath())
    }

    static func send(_ envelope: Data, to path: String) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            pathBytes.withUnsafeBytes { src in
                dst.copyMemory(from: UnsafeRawBufferPointer(start: src.baseAddress, count: src.count))
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) == 0 }
        }
        guard connected else { return }

        var out = envelope
        out.append(0x0A)
        let wrote = out.withUnsafeBytes { write(fd, $0.baseAddress, out.count) }
        guard wrote == out.count else { return }
        // Wait for the app's reply line (bounded by SO_RCVTIMEO) so it has run before we exit.
        var byte: UInt8 = 0
        while read(fd, &byte, 1) > 0, byte != 0x0A {}
    }
}
