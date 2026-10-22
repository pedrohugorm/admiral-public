import Foundation
import Security

/// Where Admiral's secrets live: the operator MCP token and the Jira OAuth items.
///
/// - **Signed with a provisioning profile** (an App Store build, or a Developer ID build that
///   embeds one — `scripts/sign-app.sh`, docs/signing.md): the signature carries
///   `keychain-access-groups`, and every item goes to the data-protection keychain under that
///   group. No ACLs, no prompts after a rebuild, and the keychain a sandboxed build can rely on.
/// - **Anything else** (Developer ID without a profile, self-signed, ad-hoc, the test runner):
///   the login keychain with securityd's default ACL. A Team-ID build reads its items back
///   silently after a rebuild — the item's partition is `teamid:<TEAM>` and its ACL trusts the
///   app's designated requirement — while a build without a Team ID prompts once per rebuild.
///
/// Every item query is built by `query(service:account:)`, so a process never mixes the two.
public enum Keychain {
    /// The access group this build's signature grants; nil means the login keychain.
    public static let accessGroup: String? = entitledAccessGroup()

    /// One generic-password item — or, without `account`, every item of `service` — in this
    /// build's keychain. `accessGroup: nil` names the login keychain explicitly.
    public static func query(service: String, account: String? = nil,
                             accessGroup: String? = accessGroup) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service]
        if let account { query[kSecAttrAccount as String] = account }
        if let accessGroup {
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    /// Add `data` as a new item: this device only, readable after the first unlock.
    @discardableResult
    public static func add(_ query: [String: Any], data: Data) -> OSStatus {
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    /// One-time move of an item from the login keychain into the access group, run before the
    /// build first reads it — otherwise a profile-signed build finds nothing and the operator
    /// token is minted afresh. No-op without an access group. Blocking (the login-keychain read
    /// can sit behind one access prompt): run off-main. Returns true when it moved the item.
    @discardableResult
    public static func moveFromLoginKeychain(service: String, account: String) throws -> Bool {
        guard accessGroup != nil else { return false }
        return try KeychainMove.move(
            from: KeychainItem(query(service: service, account: account, accessGroup: nil)),
            to: KeychainItem(query(service: service, account: account)))
    }

    /// The first `keychain-access-groups` entry of this process's own signature. macOS refuses
    /// to run code that claims it without a provisioning profile, so its presence means a
    /// profile authorized it.
    static func entitledAccessGroup() -> String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) as? [String]
        else { return nil }
        return groups.first
    }
}

public struct KeychainError: Error, Equatable, Sendable {
    public let status: Int32
    public init(status: Int32) { self.status = status }
    /// The item read back with different bytes than were just written.
    public static let readBackMismatch = KeychainError(status: -1)
}

/// One end of a move — a single item in one keychain (fakes in tests).
protocol KeychainItemStore {
    /// The item's data; nil when there is no item. Throws when the keychain can't say.
    func read() throws -> Data?
    func add(_ data: Data) throws
    func delete() throws
}

/// A generic-password item as `Keychain.query` names it.
struct KeychainItem: KeychainItemStore {
    let query: [String: Any]
    init(_ query: [String: Any]) { self.query = query }

    func read() throws -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else {
            throw status == errSecSuccess ? KeychainError.readBackMismatch : KeychainError(status: status)
        }
        return data
    }

    func add(_ data: Data) throws {
        let status = Keychain.add(query, data: data)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

enum KeychainMove {
    /// Copy `old` into an empty `new`, read it back, and only then delete `old`. When `new`
    /// already holds a value, `new` wins and `old` is deleted only if it holds that same value —
    /// a secret that exists nowhere else is never thrown away. Returns true when it copied.
    static func move(from old: KeychainItemStore, to new: KeychainItemStore) throws -> Bool {
        guard let value = try old.read() else { return false }
        if let current = try new.read() {
            if current == value { try old.delete() }
            return false
        }
        try new.add(value)
        guard try new.read() == value else { throw KeychainError.readBackMismatch }
        try old.delete()
        return true
    }
}
