// admiral/Tests/AdmiralCoreTests/HTTPWireTests.swift
import XCTest
@testable import AdmiralCore

final class HTTPWireTests: XCTestCase {

    func testParsesCompletePost() throws {
        let raw = "POST /v1/messages HTTP/1.1\r\nHost: 127.0.0.1:4141\r\nContent-Type: application/json\r\nContent-Length: 7\r\n\r\n{\"a\":1}"
        let req = try XCTUnwrap(HTTPWire.parse(Data(raw.utf8)))
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/v1/messages")
        XCTAssertEqual(req.headers["content-type"], "application/json") // lowercased key
        XCTAssertEqual(String(data: req.body, encoding: .utf8), "{\"a\":1}")
    }

    func testIncompleteReturnsNil() {
        // no blank line yet
        XCTAssertNil(HTTPWire.parse(Data("POST / HTTP/1.1\r\nContent-Length: 5\r\n".utf8)))
        // head complete, body short
        XCTAssertNil(HTTPWire.parse(Data("POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\nab".utf8)))
    }

    func testNoContentLengthMeansEmptyBody() throws {
        let req = try XCTUnwrap(HTTPWire.parse(Data("GET /v1/models HTTP/1.1\r\nHost: x\r\n\r\n".utf8)))
        XCTAssertEqual(req.method, "GET")
        XCTAssertTrue(req.body.isEmpty)
    }

    func testNegativeContentLengthReturnsNil() {
        let raw = "POST /v1/messages HTTP/1.1\r\nContent-Length: -1\r\n\r\nxx"
        XCTAssertNil(HTTPWire.parse(Data(raw.utf8)))
    }

    func testResponseBytes() {
        let out = String(data: HTTPWire.response(status: 404, body: Data("{}".utf8)), encoding: .utf8)!
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
        XCTAssertTrue(out.contains("\r\nContent-Type: application/json\r\n"))
        XCTAssertTrue(out.contains("\r\nContent-Length: 2\r\n"))
        XCTAssertTrue(out.contains("\r\nConnection: close\r\n"))
        XCTAssertTrue(out.hasSuffix("\r\n\r\n{}"))
    }

    func testNonStandard529Reason() {
        let out = String(data: HTTPWire.response(status: 529, body: Data()), encoding: .utf8)!
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 529 Overloaded\r\n"))
    }

    func testSSEHeadAndFrame() {
        let head = String(data: HTTPWire.sseHead(), encoding: .utf8)!
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(head.contains("\r\nContent-Type: text/event-stream\r\n"))
        XCTAssertFalse(head.contains("Content-Length"))
        XCTAssertTrue(head.hasSuffix("\r\n\r\n"))

        let frame = String(data: HTTPWire.sseFrame(event: "ping", data: Data("{\"type\":\"ping\"}".utf8)), encoding: .utf8)!
        XCTAssertEqual(frame, "event: ping\ndata: {\"type\":\"ping\"}\n\n")
    }
}
