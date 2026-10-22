import XCTest
import Foundation
@testable import AdmiralCore

final class SocketFDTests: XCTestCase {
    func testSetsCloseOnExecOnARealSocket() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }

        // A fresh socket does NOT have close-on-exec — otherwise the fix would be a no-op and
        // the leak would persist silently.
        XCTAssertEqual(fcntl(fd, F_GETFD) & FD_CLOEXEC, 0)

        XCTAssertTrue(SocketFD.setCloseOnExec(fd))
        XCTAssertNotEqual(fcntl(fd, F_GETFD) & FD_CLOEXEC, 0)
    }

    func testInvalidFdReturnsFalse() {
        XCTAssertFalse(SocketFD.setCloseOnExec(-1))
    }
}
