import Foundation
import XCTest
@testable import AdmiralCore

/// A station's name lives in two places — Admiral's tab and claude's own registry entry —
/// and they must not drift. These cover the split that keeps them together: `rename` is the
/// intent path (and pushes), `adoptName` is the observation path (and must not).
@MainActor
final class RenameSyncTests: XCTestCase {
    private var home: URL!

    override func setUp() {
        super.setUp()
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("admiral-rename-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }

    private func makeManager() -> SessionManager {
        SessionManager(
            host: FakeTerminalHost(), claudeHome: home, executablePath: "/usr/bin/claude",
            appearanceStore: SessionAppearanceStore(
                defaults: UserDefaults(suiteName: "admiral-test-\(UUID().uuidString)")!
            )
        )
    }

    /// Stand in for what claude publishes about itself. No socket path: these tests are
    /// about the name reconciling, not about reaching a live session.
    private func writeSessionFile(pid: Int, sessionID: String, name: String, status: String = "idle") {
        let json: [String: Any] = [
            "pid": pid, "sessionId": sessionID, "cwd": "/tmp",
            "status": status, "name": name, "updatedAt": Date().timeIntervalSince1970,
        ]
        try? JSONSerialization.data(withJSONObject: json).write(
            to: home.appendingPathComponent("sessions/\(pid).json")
        )
    }

    private func claudeType() -> AgentType {
        AgentType(
            id: "claude_code", displayName: "Claude", executableName: "claude",
            defaultArgs: ["--session-id \(SessionManager.sessionIDPlaceholder)"],
            symbolName: "sparkles"
        )
    }

    // MARK: - Claude renamed itself → the tab follows

    func testARenameInClaudeIsCapturedOnTheNextRefresh() {
        let manager = makeManager()
        let session = manager.commission(
            callsign: "worker", cwd: "/tmp", agentType: claudeType(), sessionID: "00000000-0000-4000-8000-000000000001"
        )
        writeSessionFile(pid: 4242, sessionID: "00000000-0000-4000-8000-000000000001", name: "RENAMED_IN_CLAUDE")

        manager.refreshStatuses()

        XCTAssertEqual(manager.sessions.first(where: { $0.id == session.id })?.displayTitle,
                       "RENAMED_IN_CLAUDE")
    }

    /// An externally-set name with a space is corrected, not adopted dirty — the invariant
    /// is that both sides hold the same string, and only one shape is valid.
    func testACapturedNameIsSanitized() {
        let manager = makeManager()
        let session = manager.commission(
            callsign: "worker", cwd: "/tmp", agentType: claudeType(), sessionID: "00000000-0000-4000-8000-000000000001"
        )
        writeSessionFile(pid: 4242, sessionID: "00000000-0000-4000-8000-000000000001", name: "typed in claude")

        manager.refreshStatuses()

        XCTAssertEqual(manager.sessions.first(where: { $0.id == session.id })?.displayTitle,
                       "typed-in-claude")
    }

    /// Repeated ticks must settle. If the capture kept firing, every refresh would push a
    /// rename back at claude forever.
    func testCaptureIsIdempotentAcrossTicks() {
        let manager = makeManager()
        let session = manager.commission(
            callsign: "worker", cwd: "/tmp", agentType: claudeType(), sessionID: "00000000-0000-4000-8000-000000000001"
        )
        writeSessionFile(pid: 4242, sessionID: "00000000-0000-4000-8000-000000000001", name: "STABLE")
        manager.refreshStatuses()
        manager.refreshStatuses()
        manager.refreshStatuses()

        XCTAssertEqual(manager.sessions.first(where: { $0.id == session.id })?.displayTitle, "STABLE")
    }

    /// A session file with no name must not blank a tab that has one.
    func testAnEmptyNameInTheRegistryIsIgnored() {
        let manager = makeManager()
        let session = manager.commission(
            callsign: "worker", cwd: "/tmp", agentType: claudeType(), sessionID: "00000000-0000-4000-8000-000000000001"
        )
        manager.rename(session.id, to: "KEPT")
        writeSessionFile(pid: 4242, sessionID: "00000000-0000-4000-8000-000000000001", name: "")

        manager.refreshStatuses()

        XCTAssertEqual(manager.sessions.first(where: { $0.id == session.id })?.displayTitle, "KEPT")
    }

    // MARK: - The sanitizer applies to the intent path too

    func testRenameSanitizes() {
        let manager = makeManager()
        let session = manager.commission(callsign: "worker", cwd: "/tmp")
        manager.rename(session.id, to: "night shift")
        XCTAssertEqual(manager.sessions.first(where: { $0.id == session.id })?.displayTitle,
                       "night-shift")
    }

    /// Clearing still works: an empty rename drops the override back to the callsign.
    func testEmptyRenameClearsTheOverride() {
        let manager = makeManager()
        let session = manager.commission(callsign: "worker", cwd: "/tmp")
        manager.rename(session.id, to: "temporary")
        manager.rename(session.id, to: "  ")
        XCTAssertEqual(manager.sessions.first(where: { $0.id == session.id })?.displayTitle, "worker")
    }

    /// `adoptName` is the observation path; a name that sanitizes to nothing tells us
    /// nothing, so it must leave the tab alone rather than blank it.
    func testAdoptNameIgnoresAnUnusableName() {
        let manager = makeManager()
        let session = manager.commission(callsign: "worker", cwd: "/tmp")
        manager.rename(session.id, to: "KEPT")
        manager.adoptName(session.id, "  <>  ")
        XCTAssertEqual(manager.sessions.first(where: { $0.id == session.id })?.displayTitle, "KEPT")
    }

    // MARK: - Admiral renamed the tab → claude is told

    /// The whole chain over a REAL socket: rename → pushName → ClaudeMessagingSocket.
    /// The unit tests either side of this one would both still pass if the push were
    /// never wired up, which is exactly the failure worth catching.
    func testRenamingTheTabSendsAControlFrameToClaude() throws {
        let listener = try UDSListener()
        defer { listener.stop() }
        writeSessionFile(pid: 4242, sessionID: "00000000-0000-4000-8000-000000000001", name: "worker", socket: listener.path)

        let manager = makeManager()
        let session = manager.commission(
            callsign: "worker", cwd: "/tmp", agentType: claudeType(), sessionID: "00000000-0000-4000-8000-000000000001"
        )
        manager.rename(session.id, to: "from the tab")

        let frames = try listener.awaitFrames(timeout: 2)
        let control = try XCTUnwrap(frames.last)
        XCTAssertEqual(control["type"] as? String, "control")
        XCTAssertEqual(control["action"] as? String, "rename")
        XCTAssertEqual(control["session_id"] as? String, "00000000-0000-4000-8000-000000000001")
        // Claude is told the sanitized name, not what was typed — otherwise the tab and
        // claude hold different strings and every later comparison sees a spurious diff.
        XCTAssertEqual(control["name"] as? String, "from-the-tab")
    }

    /// A rename that lands before claude publishes a socket (spawn, fork) must be a silent
    /// no-op, not a crash or an error — the next refresh reconciles it.
    func testRenamingWithNoSocketIsSilent() {
        let manager = makeManager()
        let session = manager.commission(
            callsign: "worker", cwd: "/tmp", agentType: claudeType(), sessionID: "00000000-0000-4000-8000-0000000000ff"
        )
        manager.rename(session.id, to: "early")
        XCTAssertEqual(manager.sessions.first(where: { $0.id == session.id })?.displayTitle, "early")
    }

    private func writeSessionFile(pid: Int, sessionID: String, name: String, socket: String) {
        let json: [String: Any] = [
            "pid": pid, "sessionId": sessionID, "cwd": "/tmp", "status": "idle",
            "name": name, "updatedAt": Date().timeIntervalSince1970,
            "messagingSocketPath": socket,
        ]
        try? JSONSerialization.data(withJSONObject: json).write(
            to: home.appendingPathComponent("sessions/\(pid).json")
        )
    }
}

/// A one-connection stand-in for a claude session's inbox. Its directory is short on
/// purpose: an AF_UNIX path is capped near 104 bytes.
final class UDSListener {
    let path: String
    private let fd: Int32
    private let queue = DispatchQueue(label: "uds-listener")
    private var received = Data()
    private let done = DispatchSemaphore(value: 0)

    init() throws {
        let dir = "/tmp/adm-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        path = "\(dir)/s.sock"

        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: capacity) { strncpy($0, path, capacity - 1) }
        }
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            throw NSError(domain: "UDSListener", code: Int(errno))
        }
        queue.async { [self] in
            let conn = accept(fd, nil, nil)
            guard conn >= 0 else { done.signal(); return }
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(conn, &buffer, buffer.count)
                guard n > 0 else { break }
                received.append(contentsOf: buffer[0..<n])
            }
            close(conn)
            done.signal()
        }
    }

    func awaitFrames(timeout: TimeInterval) throws -> [[String: Any]] {
        guard done.wait(timeout: .now() + timeout) == .success else {
            throw NSError(domain: "UDSListener", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "nothing arrived within \(timeout)s"])
        }
        return String(decoding: received, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    func stop() {
        close(fd)
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }
}
