import XCTest
@testable import AdmiralCore

final class WatchdogTemplateTests: XCTestCase {
    func testRendersAllVariables() {
        let out = WatchdogTemplate.render(
            "t={trigger} p={prompt} s={status} r={reason} m={idle_minutes}",
            trigger: "/drive-ticket to PROD", prompt: "go /drive-ticket to PROD",
            status: "blocked", reason: "CI down", idleMinutes: 7)
        XCTAssertEqual(out, "t=/drive-ticket to PROD p=go /drive-ticket to PROD s=blocked r=CI down m=7")
    }

    func testNilVariablesRenderEmpty() {
        XCTAssertEqual(
            WatchdogTemplate.render("[{status}][{reason}]",
                                    trigger: nil, prompt: nil, status: nil, reason: nil, idleMinutes: nil),
            "[][]")
    }

    func testUnknownPlaceholderLeftAsIs() {
        XCTAssertEqual(
            WatchdogTemplate.render("{nope} {trigger}", trigger: "X",
                                    prompt: nil, status: nil, reason: nil, idleMinutes: nil),
            "{nope} X")
    }
}
