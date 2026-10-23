import XCTest
@testable import AdmiralCore

final class TrustedHostsTests: XCTestCase {
    override func tearDown() { TrustedHosts.set("") }

    private func request(host: String, origin: String? = nil) -> HTTPRequest {
        var headers = ["host": host]
        if let origin { headers["origin"] = origin }
        return HTTPRequest(method: "POST", path: "/mcp", headers: headers, body: Data())
    }

    func testDockerHostRefusedByDefault() {
        XCTAssertTrue(request(host: "host.docker.internal:4141").looksBrowserOriginated)
    }

    func testDockerHostAcceptedOnceTrusted() {
        TrustedHosts.set("Host.Docker.Internal")
        XCTAssertFalse(request(host: "host.docker.internal:4141").looksBrowserOriginated)
    }

    func testOtherHostsStillRefusedAndOriginAlwaysRefused() {
        TrustedHosts.set("host.docker.internal")
        XCTAssertTrue(request(host: "evil.example:4141").looksBrowserOriginated)
        XCTAssertTrue(request(host: "host.docker.internal", origin: "http://x").looksBrowserOriginated)
    }

    func testParseSplitsAndStripsPorts() {
        XCTAssertEqual(TrustedHosts.parse("a.test:80, B.test\nc.test"), ["a.test", "b.test", "c.test"])
    }
}
