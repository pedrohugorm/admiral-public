import XCTest
@testable import AdmiralCore

/// A token that was issued once is never silently replaced: a missing Keychain item after that
/// is `.tokenLost`, and only Rotate (or a first run) mints.
final class OperatorTokenIssuedTests: XCTestCase {
    private var base: URL!
    override func setUp() {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("op-token-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    func testFirstRunMintsAndLeavesAMarker() {
        let mirror = FakeMirror()
        let r = OperatorTokenStore.resolve(base: base, mirror: mirror)
        XCTAssertEqual(r.mirror, .inSync)
        XCTAssertTrue(OperatorTokenStore.isWellFormed(r.token))
        XCTAssertTrue(OperatorTokenStore.wasIssued(base: base))
        XCTAssertEqual(OperatorTokenStore.issuedHash(base: base), OperatorTokenStore.hashPrefix(r.token))
        let marker = (try? String(contentsOf: OperatorTokenStore.issuedMarker(base: base))) ?? ""
        XCTAssertFalse(marker.contains(r.token), "the marker is a hash prefix, never the token")
    }

    func testMissingItemAfterAnIssueIsNotMinted() {
        let mirror = FakeMirror()
        let first = OperatorTokenStore.resolve(base: base, mirror: mirror)
        mirror.value = nil  // the keychain lost it (another build's store, a deleted item)
        let writesBefore = mirror.writes

        let again = OperatorTokenStore.resolve(base: base, mirror: mirror)
        XCTAssertEqual(again, .init(token: "", mirror: .tokenLost))
        XCTAssertEqual(mirror.writes, writesBefore, "nothing written over the lost token")
        XCTAssertNil(mirror.value)
        XCTAssertNotEqual(again.token, first.token)
    }

    func testMalformedItemAfterAnIssueIsNotMintedOverEither() {
        let mirror = FakeMirror()
        _ = OperatorTokenStore.resolve(base: base, mirror: mirror)
        mirror.value = "garbage"
        let r = OperatorTokenStore.resolve(base: base, mirror: mirror)
        XCTAssertEqual(r.mirror, .tokenLost)
        XCTAssertEqual(mirror.value, "garbage")
    }

    func testRotateIssuesANewTokenFromTheLostState() {
        let mirror = FakeMirror()
        let first = OperatorTokenStore.resolve(base: base, mirror: mirror)
        mirror.value = nil
        XCTAssertEqual(OperatorTokenStore.resolve(base: base, mirror: mirror).mirror, .tokenLost)

        let rotated = OperatorTokenStore.rotateToken(base: base, mirror: mirror)
        XCTAssertEqual(rotated.mirror, .inSync)
        XCTAssertNotEqual(rotated.token, first.token)
        XCTAssertEqual(OperatorTokenStore.issuedHash(base: base), OperatorTokenStore.hashPrefix(rotated.token))
        XCTAssertEqual(OperatorTokenStore.resolve(base: base, mirror: mirror).token, rotated.token)
    }

    func testAnExistingTokenWithNoMarkerIsKeptAndBackfilled() {
        let mirror = FakeMirror()
        let existing = OperatorTokenStore.mint()
        mirror.value = existing  // an install that predates the marker
        let r = OperatorTokenStore.resolve(base: base, mirror: mirror)
        XCTAssertEqual(r, .init(token: existing, mirror: .inSync))
        XCTAssertEqual(OperatorTokenStore.issuedHash(base: base), OperatorTokenStore.hashPrefix(existing))
    }

    func testRelaunchesKeepTheSameToken() {
        let mirror = FakeMirror()
        let first = OperatorTokenStore.resolve(base: base, mirror: mirror).token
        for _ in 0..<3 { XCTAssertEqual(OperatorTokenStore.resolve(base: base, mirror: mirror).token, first) }
    }

    func testProfileScopesTheKeychainAccount() {
        XCTAssertEqual(KeychainOperatorTokenMirror.account(profile: nil), "token")
        XCTAssertEqual(KeychainOperatorTokenMirror.account(profile: ""), "token")
        XCTAssertEqual(KeychainOperatorTokenMirror.account(profile: "uitest-ab12"), "token.uitest-ab12")
    }
}
