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

    func testOldCommaSeparatedStringMigratesToAnOrderedArray() {
        XCTAssertEqual(TrustedHosts.migrate(stored: "host.docker.internal, B.test:80\nb.test"),
                       ["host.docker.internal", "b.test"])
        XCTAssertEqual(TrustedHosts.migrate(stored: ["a.test", "A.test", "bad host", "http://x"]), ["a.test"])
        XCTAssertEqual(TrustedHosts.migrate(stored: nil), [])
    }

    func testValidateAcceptsBareHostsAndRejectsTheRestWithAReason() throws {
        XCTAssertEqual(try TrustedHosts.validate(" Host.Docker.Internal ", existing: []).get(), "host.docker.internal")
        XCTAssertEqual(try TrustedHosts.validate("10.0.0.5", existing: []).get(), "10.0.0.5")
        XCTAssertEqual(try TrustedHosts.validate("[fe80::1]", existing: []).get(), "[fe80::1]")
        func failure(_ s: String, existing: [String] = []) -> TrustedHosts.Invalid? {
            if case .failure(let e) = TrustedHosts.validate(s, existing: existing) { return e }
            return nil
        }
        XCTAssertEqual(failure(""), .empty)
        XCTAssertEqual(failure("http://x.test"), .notABareHost)
        XCTAssertEqual(failure("x.test/path"), .notABareHost)
        XCTAssertEqual(failure("x.test:4141"), .notABareHost)
        XCTAssertEqual(failure("a b"), .notABareHost)
        XCTAssertEqual(failure("localhost"), .builtIn)
        XCTAssertEqual(failure("A.test", existing: ["a.test"]), .duplicate)
    }

    func testArraySetterAppliesImmediately() {
        TrustedHosts.set(["host.docker.internal"])
        XCTAssertFalse(request(host: "host.docker.internal:4141").looksBrowserOriginated)
        TrustedHosts.set([String]())
        XCTAssertTrue(request(host: "host.docker.internal:4141").looksBrowserOriginated)
    }
}
