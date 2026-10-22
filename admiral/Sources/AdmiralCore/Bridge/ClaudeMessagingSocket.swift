import CryptoKit
import Foundation

/// Delivers into a running Claude Code session over the session's own messaging socket.
///
/// Claude Code publishes, per session, `~/.claude/sessions/<pid>.json` naming a unix socket
/// plus an auth key beside it. Writing newline-delimited JSON to that socket is exactly how
/// its built-in `SendMessage` reaches a peer — so a hail sent this way arrives as a
/// first-class peer message, needs no framing of ours, and enqueues even while the receiving
/// session is mid-turn (which typing into the PTY does not).
public enum ClaudeMessagingSocket {
    public enum DeliveryError: Error, CustomStringConvertible {
        case noSocket
        case unreachable(String)
        case emptyBody

        public var description: String {
            switch self {
            case .noSocket: "that session publishes no messaging socket"
            case let .unreachable(reason): reason
            case .emptyBody: "refusing to send an empty message"
            }
        }
    }

    /// The socket refuses a line over 1 MiB, and a body that large is a mistake anyway.
    static let maxBodyBytes = 512 * 1024

    // MARK: - Addressing

    /// Where the peer token for this socket lives.
    ///
    /// Claude Code names the key after the sha256 of the socket's REAL path, so a symlinked
    /// or relative path has to be resolved the same way or the token is simply not found and
    /// every send silently goes out unauthenticated.
    static func keyPath(pid: Int, socketPath: String, claudeHome: URL) -> URL {
        let resolved = URL(fileURLWithPath: socketPath).resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(resolved.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return claudeHome.appendingPathComponent("sessions/\(pid).\(digest).key")
    }

    static func peerToken(pid: Int, socketPath: String, claudeHome: URL) -> String? {
        guard let data = try? Data(contentsOf: keyPath(pid: pid, socketPath: socketPath, claudeHome: claudeHome)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["peerToken"] as? String
    }

    // MARK: - Frames

    /// The lines for a peer message. `msgID` must be a UUID — the receiver ignores any other
    /// shape, taking the message but dropping the correlation, which is the worst of both.
    static func messageFrames(
        token: String?, from sender: String, body: String, sessionID: String, msgID: String
    ) -> [[String: Any]] {
        auth(token) + [[
            "type": "user",
            "from": sender,
            "msg_id": msgID,
            "priority": "next",
            "session_id": sessionID,
            "message": ["role": "user", "content": body],
        ]]
    }

    /// The lines for a rename. `session_id` is carried so a recycled pid cannot land this on
    /// a different session: the receiver drops a control frame whose session_id is not its own.
    static func renameFrames(token: String?, name: String, sessionID: String) -> [[String: Any]] {
        auth(token) + [[
            "type": "control",
            "action": "rename",
            "name": name,
            "session_id": sessionID,
        ]]
    }

    private static func auth(_ token: String?) -> [[String: Any]] {
        // Auth may be optional on this platform, so a missing key is not fatal — send
        // unauthenticated and let the receiver decide.
        token.map { [["type": "auth", "token": $0]] } ?? []
    }

    static func encode(_ frames: [[String: Any]]) -> Data {
        var out = Data()
        for frame in frames {
            guard let line = try? JSONSerialization.data(withJSONObject: frame) else { continue }
            out.append(line)
            out.append(0x0A)
        }
        return out
    }

    // MARK: - Delivery

    /// Queue `body` in `file`'s session and return the msg_id it went out under.
    @discardableResult
    public static func send(
        _ body: String, to file: ClaudeSessionFile, from sender: String, claudeHome: URL
    ) throws -> String {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeliveryError.emptyBody
        }
        guard body.utf8.count <= maxBodyBytes else {
            throw DeliveryError.unreachable("message is over \(maxBodyBytes) bytes")
        }
        guard let pid = file.pid, let path = file.messagingSocketPath, !path.isEmpty else {
            throw DeliveryError.noSocket
        }
        let msgID = UUID().uuidString.lowercased()
        try write(
            encode(messageFrames(
                token: peerToken(pid: pid, socketPath: path, claudeHome: claudeHome),
                from: sender, body: body, sessionID: file.sessionId ?? "", msgID: msgID
            )),
            to: path
        )
        return msgID
    }

    /// Rename the claude session itself, so its own name matches the tab's.
    public static func rename(_ name: String, on file: ClaudeSessionFile, claudeHome: URL) throws {
        guard let pid = file.pid, let path = file.messagingSocketPath, !path.isEmpty else {
            throw DeliveryError.noSocket
        }
        try write(
            encode(renameFrames(
                token: peerToken(pid: pid, socketPath: path, claudeHome: claudeHome),
                name: name, sessionID: file.sessionId ?? ""
            )),
            to: path
        )
    }

    /// One connection's worth of NDJSON. Blocking, but bounded: these are small writes to a
    /// local socket, and the caller (an MCP tool call) is already synchronous.
    static func write(_ payload: Data, to socketPath: String) throws {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.utf8.count < capacity else {
            throw DeliveryError.unreachable("socket path is too long: \(socketPath)")
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                strncpy(dst, socketPath, capacity - 1)
            }
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DeliveryError.unreachable("socket(): \(errnoText())") }
        SocketFD.setCloseOnExec(fd)
        defer { close(fd) }

        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(fd, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw DeliveryError.unreachable("connect(\(socketPath)): \(errnoText())")
        }

        try payload.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent)
                guard n > 0 else { throw DeliveryError.unreachable("write(): \(errnoText())") }
                sent += n
            }
        }
    }

    private static func errnoText() -> String { String(cString: strerror(errno)) }
}
