import XCTest
import Darwin
@testable import AdmiralCore

/// The bridge socket's transport. Every test runs its own server on a fresh socket path with
/// an echo handler, so nothing here reaches the app or a real session.
final class LineSocketServerTests: XCTestCase {
    private var servers: [LineSocketServer] = []

    override func tearDown() {
        servers.forEach { $0.stop() }
        servers = []
        super.tearDown()
    }

    /// A short path: `sockaddr_un` caps it near 104 bytes.
    private func socketPath() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lss-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("s.sock").path
    }

    private func makeServer(ioTimeout: TimeInterval = 5, maxConnections: Int = 32,
                            maxLineBytes: Int = 1 << 20, allowedUID: uid_t = getuid()) throws -> LineSocketServer {
        let server = LineSocketServer(path: try socketPath(), maxLineBytes: maxLineBytes, ioTimeout: ioTimeout,
                                      maxConnections: maxConnections, allowedUID: allowedUID) { line in
            Data("echo:".utf8) + line
        }
        XCTAssertTrue(server.start())
        servers.append(server)
        return server
    }

    /// A connected client fd with its own receive timeout, so a test can never hang.
    private func connectClient(_ path: String, timeout: Int = 3) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            bytes.withUnsafeBytes { dst.copyMemory(from: UnsafeRawBufferPointer(start: $0.baseAddress, count: $0.count)) }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard ok else { close(fd); throw XCTSkip("connect failed: \(errno)") }
        return fd
    }

    private func send(_ fd: Int32, _ text: String) {
        let data = Array(text.utf8)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
    }

    /// Everything until EOF, the client timeout (`timedOut`), or a newline.
    private func reply(_ fd: Int32) -> (text: String, timedOut: Bool) {
        var out = [UInt8]()
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n < 0 { return (String(decoding: out, as: UTF8.self), true) }
            if n == 0 || byte == 0x0A { break }
            out.append(byte)
        }
        return (String(decoding: out, as: UTF8.self), false)
    }

    private func roundTrip(_ path: String, _ line: String) throws -> String {
        let fd = try connectClient(path)
        defer { close(fd) }
        send(fd, line + "\n")
        return reply(fd).text
    }

    private func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            usleep(10_000)
        }
        return condition()
    }

    func testAnswersOneLine() throws {
        let server = try makeServer()
        XCTAssertEqual(try roundTrip(server.path, "hello"), "echo:hello")
    }

    /// Only this user may reach the socket file at all.
    func testSocketFileIsOwnerOnly() throws {
        let server = try makeServer()
        var info = stat()
        XCTAssertEqual(stat(server.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600, String(info.st_mode & 0o777, radix: 8))
    }

    /// A peer of any other uid is closed without an answer. (The test cannot connect as
    /// another user, so the server is told to expect a uid that is not ours.)
    func testPeerOfAnotherUIDIsClosedUnanswered() throws {
        let server = try makeServer(allowedUID: getuid() &+ 1)
        let fd = try connectClient(server.path)
        defer { close(fd) }
        send(fd, "hello\n")
        let answer = reply(fd)
        XCTAssertFalse(answer.timedOut, "closed at once, not left hanging")
        XCTAssertEqual(answer.text, "")
    }

    /// A client that connects and sends nothing is dropped after the I/O timeout.
    func testSilentClientIsDroppedAfterTheTimeout() throws {
        let server = try makeServer(ioTimeout: 0.3)
        let fd = try connectClient(server.path, timeout: 3)
        defer { close(fd) }
        let started = Date()
        let answer = reply(fd)
        XCTAssertFalse(answer.timedOut, "the server closed it before the client gave up")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertTrue(waitUntil(1) { server.activeConnections == 0 })
    }

    /// One stalled client holds only its own slot: another is answered meanwhile.
    func testStalledClientDoesNotBlockOthers() throws {
        let server = try makeServer(ioTimeout: 5)
        let stalled = try connectClient(server.path)
        defer { close(stalled) }
        XCTAssertTrue(waitUntil(2) { server.activeConnections == 1 })
        let started = Date()
        XCTAssertEqual(try roundTrip(server.path, "second"), "echo:second")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    /// Past the connection cap a new client is closed unanswered; a freed slot serves again.
    func testConnectionsPastTheCapAreClosedUnanswered() throws {
        let server = try makeServer(ioTimeout: 5, maxConnections: 2)
        let held = try [connectClient(server.path), connectClient(server.path)]
        XCTAssertTrue(waitUntil(2) { server.activeConnections == 2 })
        let extra = try connectClient(server.path)
        send(extra, "third\n")
        let answer = reply(extra)
        close(extra)
        XCTAssertFalse(answer.timedOut)
        XCTAssertEqual(answer.text, "", "no answer past the cap")
        held.forEach { close($0) }
        XCTAssertTrue(waitUntil(2) { server.activeConnections == 0 })
        XCTAssertEqual(try roundTrip(server.path, "again"), "echo:again")
    }

    /// A line over the cap is never handed to the handler.
    func testOverlongLineIsClosedUnanswered() throws {
        let server = try makeServer(maxLineBytes: 16)
        XCTAssertEqual(try roundTrip(server.path, String(repeating: "x", count: 64)), "")
        XCTAssertEqual(try roundTrip(server.path, "short"), "echo:short")
    }
}
