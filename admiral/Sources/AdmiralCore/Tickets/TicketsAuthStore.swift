import Foundation
import Security

/// Jira OAuth tokens in the macOS Keychain only — never config.json / UserDefaults / disk.
///
/// Service: `com.pedro.admiral.tickets.jira`
/// Accessibility: AfterFirstUnlockThisDeviceOnly (refresh after sleep; no iCloud sync).
public enum TicketsAuthStore {
    public static let service = "com.pedro.admiral.tickets.jira"

    public struct Tokens: Equatable, Sendable {
        public var accessToken: String
        public var refreshToken: String
        public var expiresAt: Date
        public var cloudId: String

        public init(accessToken: String, refreshToken: String, expiresAt: Date, cloudId: String) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresAt = expiresAt
            self.cloudId = cloudId
        }

        public var isExpired: Bool {
            // Refresh a minute early so a fetch never races the expiry edge.
            expiresAt.timeIntervalSinceNow < 60
        }
    }

    private enum Account: String, CaseIterable {
        case accessToken, refreshToken, expiresAt, cloudId, clientSecret
    }

    /// The Atlassian app's client secret (required by the token endpoint even with PKCE).
    /// Keychain-only, same service as the tokens.
    public static var clientSecret: String? {
        read(.clientSecret).flatMap { $0.isEmpty ? nil : $0 }
    }

    public static func setClientSecret(_ secret: String) {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { delete(.clientSecret) } else { write(.clientSecret, trimmed) }
    }

    public static func load() -> Tokens? {
        guard let access = read(.accessToken), !access.isEmpty,
              let refresh = read(.refreshToken), !refresh.isEmpty,
              let expiryRaw = read(.expiresAt),
              let expiry = ISO8601DateFormatter().date(from: expiryRaw) ?? Double(expiryRaw).map(Date.init(timeIntervalSince1970:)),
              let cloudId = read(.cloudId), !cloudId.isEmpty
        else { return nil }
        return Tokens(accessToken: access, refreshToken: refresh, expiresAt: expiry, cloudId: cloudId)
    }

    public static var isConnected: Bool { load() != nil }

    public static func save(_ tokens: Tokens) {
        write(.accessToken, tokens.accessToken)
        write(.refreshToken, tokens.refreshToken)
        write(.expiresAt, ISO8601DateFormatter().string(from: tokens.expiresAt))
        write(.cloudId, tokens.cloudId)
    }

    /// Disconnect: delete every item for this service (tokens and client secret) — from the login
    /// keychain too, so a leftover a failed move kept there can't reconnect Jira next launch.
    public static func clear() {
        SecItemDelete(Keychain.query(service: service) as CFDictionary)
        SecItemDelete(Keychain.query(service: service, accessGroup: nil) as CFDictionary)
    }

    private static func delete(_ account: Account) {
        SecItemDelete(query(account) as CFDictionary)
    }

    // MARK: - SecItem

    /// Runs `moveFromLoginKeychain` once per process, before the first read touches the items.
    private static let movedOnce: Int = moveFromLoginKeychain()

    private static func query(_ account: Account) -> [String: Any] {
        Keychain.query(service: service, account: account.rawValue)
    }

    private static func read(_ account: Account) -> String? {
        _ = movedOnce
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ account: Account, _ value: String) {
        guard let data = value.data(using: .utf8) else { return }
        SecItemDelete(query(account) as CFDictionary)
        Keychain.add(query(account), data: data)
    }

    /// One-time, blocking (run off-main; may show a single Keychain prompt): a build with a
    /// keychain access group moves the items out of the login keychain into it. No-op without
    /// one. Returns how many items moved.
    @discardableResult
    public static func moveFromLoginKeychain() -> Int {
        Account.allCases.filter {
            (try? Keychain.moveFromLoginKeychain(service: service, account: $0.rawValue)) == true
        }.count
    }
}
