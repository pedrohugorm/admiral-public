import XCTest
import Security
@testable import AdmiralCore

/// `Keychain`: which keychain a build's items go to, and the one-time move into the access group.
/// Nothing here touches a real keychain — queries are inspected, and the move runs on fakes.
final class KeychainTests: XCTestCase {
    func testWithoutAnAccessGroupItemsGoToTheLoginKeychain() {
        let q = Keychain.query(service: "svc", account: "acct", accessGroup: nil)
        XCTAssertEqual(q[kSecAttrService as String] as? String, "svc")
        XCTAssertEqual(q[kSecAttrAccount as String] as? String, "acct")
        XCTAssertNil(q[kSecUseDataProtectionKeychain as String])
        XCTAssertNil(q[kSecAttrAccessGroup as String])
    }

    func testWithAnAccessGroupItemsGoToTheDataProtectionKeychain() {
        let q = Keychain.query(service: "svc", account: "acct", accessGroup: "ABCDE12345.com.example.app")
        XCTAssertEqual(q[kSecUseDataProtectionKeychain as String] as? Bool, true)
        XCTAssertEqual(q[kSecAttrAccessGroup as String] as? String, "ABCDE12345.com.example.app")
    }

    func testServiceWideQueryNamesNoAccount() {
        XCTAssertNil(Keychain.query(service: "svc", accessGroup: nil)[kSecAttrAccount as String])
    }

    /// `swift test` binaries carry no provisioning profile: the login keychain is the default and
    /// the move is a no-op, so a test can never move a real item.
    func testUnprofiledTestRunnerHasNoAccessGroupAndNeverMoves() throws {
        XCTAssertNil(Keychain.accessGroup)
        XCTAssertFalse(try Keychain.moveFromLoginKeychain(service: "com.pedro.admiral.never-used", account: "x"))
    }

    // MARK: - The move

    private final class FakeItem: KeychainItemStore {
        var data: Data?
        var failRead = false
        var failAdd = false
        /// Accepts the add, then reads back something else.
        var readBackOverride: Data?
        private var added = false

        init(_ value: String? = nil) { data = value.map { Data($0.utf8) } }

        func read() throws -> Data? {
            if failRead { throw KeychainError(status: errSecInteractionNotAllowed) }
            if added, let readBackOverride { return readBackOverride }
            return data
        }
        func add(_ value: Data) throws {
            if failAdd { throw KeychainError(status: errSecDuplicateItem) }
            data = value
            added = true
        }
        func delete() throws { data = nil }
    }

    func testMoveCopiesReadsBackThenDeletesTheOldItem() throws {
        let old = FakeItem("adm_x"), new = FakeItem()
        XCTAssertTrue(try KeychainMove.move(from: old, to: new))
        XCTAssertEqual(new.data, Data("adm_x".utf8))
        XCTAssertNil(old.data)
    }

    func testAGroupItemWithTheSameValueOnlyRetiresTheOldOne() throws {
        let old = FakeItem("v"), new = FakeItem("v")
        XCTAssertFalse(try KeychainMove.move(from: old, to: new))
        XCTAssertNil(old.data)
        XCTAssertEqual(new.data, Data("v".utf8))
    }

    /// Two different values: the group's wins and the old one is kept — it may be the only copy
    /// of a value something still uses.
    func testAGroupItemWithADifferentValueWinsAndTheOldOneIsKept() throws {
        let old = FakeItem("old"), new = FakeItem("new")
        XCTAssertFalse(try KeychainMove.move(from: old, to: new))
        XCTAssertEqual(old.data, Data("old".utf8))
        XCTAssertEqual(new.data, Data("new".utf8))
    }

    func testNothingInTheLoginKeychainIsANoOp() throws {
        let old = FakeItem(), new = FakeItem()
        XCTAssertFalse(try KeychainMove.move(from: old, to: new))
        XCTAssertNil(new.data)
    }

    func testAFailedAddKeepsTheOldItem() {
        let old = FakeItem("v"), new = FakeItem()
        new.failAdd = true
        XCTAssertThrowsError(try KeychainMove.move(from: old, to: new))
        XCTAssertEqual(old.data, Data("v".utf8))
    }

    func testAReadBackMismatchKeepsTheOldItem() {
        let old = FakeItem("v"), new = FakeItem()
        new.readBackOverride = Data("other".utf8)
        XCTAssertThrowsError(try KeychainMove.move(from: old, to: new)) {
            XCTAssertEqual($0 as? KeychainError, .readBackMismatch)
        }
        XCTAssertEqual(old.data, Data("v".utf8))
    }

    /// An unanswered or denied prompt on the old item: nothing is copied, nothing deleted.
    func testAnUnreadableOldItemChangesNothing() {
        let old = FakeItem("v"), new = FakeItem()
        old.failRead = true
        XCTAssertThrowsError(try KeychainMove.move(from: old, to: new))
        XCTAssertEqual(old.data, Data("v".utf8))
        XCTAssertNil(new.data)
    }
}
