import CryptoKit
import Foundation
import XCTest
@testable import AdmiralCore

/// The wire the receiving claude actually parses. These frames are matched byte-for-byte
/// against the Python client's (`tests/test_uds.py`) — one protocol, two senders.
final class ClaudeMessagingSocketTests: XCTestCase {
    private func decode(_ data: Data) -> [[String: Any]] {
        String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    func testMessageFramesAuthenticateThenSend() {
        let frames = ClaudeMessagingSocket.messageFrames(
            token: "s3cret", from: "ALICE", body: "hello", sessionID: "sid-1", msgID: "m-1"
        )
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0]["type"] as? String, "auth")
        XCTAssertEqual(frames[0]["token"] as? String, "s3cret")
        XCTAssertEqual(frames[1]["type"] as? String, "user")
        XCTAssertEqual(frames[1]["from"] as? String, "ALICE")
        XCTAssertEqual(frames[1]["session_id"] as? String, "sid-1")
        XCTAssertEqual(frames[1]["message"] as? [String: String], ["role": "user", "content": "hello"])
    }

    /// Auth is optional on this platform, so a session with no readable key still gets
    /// the message rather than nothing at all.
    func testMissingTokenOmitsTheAuthLine() {
        let frames = ClaudeMessagingSocket.messageFrames(
            token: nil, from: "ALICE", body: "hi", sessionID: "sid-1", msgID: "m-1"
        )
        XCTAssertEqual(frames.map { $0["type"] as? String }, ["user"])
    }

    /// The receiver drops a control frame whose session_id is not its own, which is what
    /// stops a recycled pid from landing a rename on the wrong session.
    func testRenameFrameCarriesTheSessionID() {
        let frames = ClaudeMessagingSocket.renameFrames(token: nil, name: "NEW", sessionID: "sid-9")
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0]["type"] as? String, "control")
        XCTAssertEqual(frames[0]["action"] as? String, "rename")
        XCTAssertEqual(frames[0]["name"] as? String, "NEW")
        XCTAssertEqual(frames[0]["session_id"] as? String, "sid-9")
    }

    func testEncodeIsNewlineDelimited() {
        let data = ClaudeMessagingSocket.encode(
            ClaudeMessagingSocket.renameFrames(token: "t", name: "N", sessionID: "s")
        )
        XCTAssertEqual(data.last, 0x0A)
        XCTAssertEqual(decode(data).count, 2)
    }

    /// The key is named after the sha256 of the socket's REAL path. Hash the unresolved
    /// path instead and the token is silently not found, so every send goes unauthenticated.
    func testKeyPathHashesTheResolvedSocketPath() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("real.sock")
        FileManager.default.createFile(atPath: target.path, contents: Data())
        let link = dir.appendingPathComponent("link.sock")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertEqual(
            ClaudeMessagingSocket.keyPath(pid: 1, socketPath: link.path, claudeHome: dir),
            ClaudeMessagingSocket.keyPath(pid: 1, socketPath: target.path, claudeHome: dir)
        )
    }

    func testKeyPathMatchesTheDigestClaudeCodeWrites() {
        let home = URL(fileURLWithPath: "/tmp/home")
        let digest = SHA256.hash(data: Data("/tmp/peer.sock".utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(
            ClaudeMessagingSocket.keyPath(pid: 42, socketPath: "/tmp/peer.sock", claudeHome: home).path,
            "/tmp/home/sessions/42.\(digest).key"
        )
    }

    func testUnreachableSocketThrows() {
        let file = ClaudeSessionFile(
            pid: 1, sessionId: "s", cwd: "/tmp", status: "idle", updatedAt: nil,
            name: "X", messagingSocketPath: "/tmp/definitely-not-listening.sock"
        )
        XCTAssertThrowsError(
            try ClaudeMessagingSocket.send("hi", to: file, from: "A",
                                           claudeHome: URL(fileURLWithPath: "/tmp"))
        )
    }

    func testEmptyBodyIsRefused() {
        let file = ClaudeSessionFile(
            pid: 1, sessionId: "s", cwd: "/tmp", status: "idle", updatedAt: nil,
            name: "X", messagingSocketPath: "/tmp/whatever.sock"
        )
        XCTAssertThrowsError(
            try ClaudeMessagingSocket.send("   ", to: file, from: "A",
                                           claudeHome: URL(fileURLWithPath: "/tmp"))
        ) { error in
            guard case ClaudeMessagingSocket.DeliveryError.emptyBody = error else {
                return XCTFail("expected emptyBody, got \(error)")
            }
        }
    }

    /// A registry entry outlives its process, so the socket's existence — not the file's —
    /// is what makes a session addressable.
    func testEntryWithNoSocketOnDiskIsNotAddressable() {
        let file = ClaudeSessionFile(
            pid: 1, sessionId: "s", cwd: "/tmp", status: "idle", updatedAt: nil,
            name: "X", messagingSocketPath: "/tmp/gone-\(UUID().uuidString).sock"
        )
        XCTAssertFalse(file.isAddressable)
    }
}
