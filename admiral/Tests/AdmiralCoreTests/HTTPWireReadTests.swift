import XCTest
import Darwin
@testable import AdmiralCore

/// `HTTPWire.readRequest` over a socketpair: the server end is read the way the API server
/// reads a connection, the client end is driven by the test. Nothing leaves the process.
final class HTTPWireReadTests: XCTestCase {
    private func pair() -> (server: Int32, client: Int32) {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        return (fds[0], fds[1])
    }

    private func send(_ fd: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, bytes.count) }
    }

    /// Runs `readRequest` off the test thread and returns its result and how long it took, or
    /// nil when it had not returned within `wait` (the read is then still blocked; closing the
    /// client end afterwards releases it).
    private func read(_ fd: Int32, timeout: TimeInterval, wait: TimeInterval)
        -> (request: HTTPRequest?, seconds: TimeInterval)? {
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        let started = Date()
        DispatchQueue.global().async {
            box.request = HTTPWire.readRequest(from: fd, timeout: timeout)
            box.seconds = Date().timeIntervalSince(started)
            done.signal()
        }
        guard done.wait(timeout: .now() + wait) == .success else { return nil }
        return (box.request, box.seconds)
    }

    private final class Box: @unchecked Sendable {
        var request: HTTPRequest?
        var seconds: TimeInterval = 0
    }

    func testReadsARequestSplitAcrossWrites() throws {
        let (server, client) = pair()
        defer { close(server); close(client) }
        send(client, "POST /v1/messages HTTP/1.1\r\nContent-Length: 7\r\n\r\n")
        send(client, "{\"a\":1}")
        let result = try XCTUnwrap(read(server, timeout: 2, wait: 3))
        XCTAssertEqual(result.request?.path, "/v1/messages")
        XCTAssertEqual(result.request.map { String(decoding: $0.body, as: UTF8.self) }, "{\"a\":1}")
    }

    /// A client that sends half a request and goes quiet is dropped at the timeout.
    func testSilentClientTimesOut() throws {
        let (server, client) = pair()
        defer { close(server); close(client) }
        send(client, "POST /v1/messages HTTP/1.1\r\nContent-Length: 5\r\n")
        let result = read(server, timeout: 0.3, wait: 3)
        XCTAssertNotNil(result, "the read never returned")
        XCTAssertNil(result?.request ?? nil)
        XCTAssertLessThan(result?.seconds ?? 99, 1.5)
    }

    /// A client dribbling a byte at a time never resets the clock: the whole request has one
    /// budget.
    func testDribblingClientTimesOutOnTheWholeRequestBudget() throws {
        let (server, client) = pair()
        defer { close(server); close(client) }
        let stop = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { [self] in
            for _ in 0..<40 {
                if stop.wait(timeout: .now() + 0.1) == .success { return }
                send(client, "x")
            }
        }
        let result = read(server, timeout: 0.5, wait: 3)
        stop.signal()
        XCTAssertNotNil(result, "the read never returned")
        XCTAssertNil(result?.request ?? nil)
        XCTAssertLessThan(result?.seconds ?? 99, 1.5)
    }

    /// The timeout also bounds writes on the connection (the answer, an SSE frame).
    func testSetsTheSendTimeout() throws {
        let (server, client) = pair()
        defer { close(server); close(client) }
        send(client, "GET / HTTP/1.1\r\n\r\n")
        _ = try XCTUnwrap(read(server, timeout: 2, wait: 3))
        var tv = timeval()
        var len = socklen_t(MemoryLayout<timeval>.size)
        XCTAssertEqual(getsockopt(server, SOL_SOCKET, SO_SNDTIMEO, &tv, &len), 0)
        XCTAssertEqual(tv.tv_sec, 2)
    }

    func testConnectionLimiterCapsAndReleases() {
        let limiter = ConnectionLimiter(limit: 2)
        XCTAssertTrue(limiter.acquire())
        XCTAssertTrue(limiter.acquire())
        XCTAssertFalse(limiter.acquire(), "past the cap")
        limiter.release()
        XCTAssertTrue(limiter.acquire(), "a released slot is reusable")
        XCTAssertEqual(limiter.inFlight, 2)
    }
}
