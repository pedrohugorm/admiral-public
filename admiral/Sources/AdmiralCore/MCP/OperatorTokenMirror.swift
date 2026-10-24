import Foundation
import Security

/// The Keychain home of the operator MCP token (the only place it lives). Implementations may
/// block (a Keychain prompt) — wrap them in `GuardedOperatorTokenMirror` so callers get a bounded
/// wait. Never log the values.
public protocol OperatorTokenMirror: AnyObject {
    /// The stored value, or `nil` when no item exists. Throws when the store is unavailable.
    func read() throws -> String?
    /// Create or update the stored value in place (never delete-then-add).
    func write(_ value: String) throws
    /// Make the stored value exactly `value`, even if the existing item cannot be updated by this
    /// build (an ACL the current build is not on): update in place first, then delete + add so the
    /// new item is owned by the current build. Used where the caller's value must win.
    func replace(_ value: String) throws
    /// One-time move of the token out of the login keychain into this build's access group
    /// (`Keychain.moveFromLoginKeychain`), run before the first read. True when it moved the item;
    /// false when there was nothing to move or the build has no access group. May prompt once.
    @discardableResult func moveFromLoginKeychain() throws -> Bool
}

extension OperatorTokenMirror {
    public func replace(_ value: String) throws { try write(value) }
    @discardableResult public func moveFromLoginKeychain() throws -> Bool { false }
}

public struct OperatorTokenMirrorError: Error, Equatable, Sendable {
    public let status: Int32
    public init(status: Int32) { self.status = status }
    /// Raised by `GuardedOperatorTokenMirror` when the underlying call did not return in time.
    public static let timeout = OperatorTokenMirrorError(status: -60_001)
    public var isTimeout: Bool { status == Self.timeout.status }
}

public enum OperatorTokenMirrorStatus: Equatable, Sendable {
    /// Not yet (re)checked — shown while the off-main-thread check runs.
    case checking
    case inSync
    /// The Keychain read-back did not equal the value just written (the legacy file, if any, is kept
    /// and its value is served). Informational; Recheck retries.
    case outOfSync
    /// A token was issued before (the marker file says so) but the Keychain has none now. Nothing
    /// was minted, so no client's copy was invalidated; Rotate issues a new one on purpose.
    case tokenLost
    /// Keychain call failed.
    case unavailable
    /// Keychain call did not return in time (usually an unanswered access prompt).
    case timedOut

    public var label: String {
        switch self {
        case .checking: "checking…"
        case .inSync: "in sync"
        case .outOfSync: "out of sync (file value in use)"
        case .tokenLost: "token missing from the Keychain — press Rotate to issue a new one (update clients)"
        case .unavailable: "unavailable (error)"
        case .timedOut: "unavailable (timeout)"
        }
    }

    /// A pending access prompt (the only status worth retrying on its own once the user answers).
    public var isRetryable: Bool { self == .timedOut }
}

/// When the app re-runs a timed-out resolution by itself (the user clicked Allow on the Keychain
/// prompt after the patient wait expired): every `interval` seconds, at most `maxAttempts` times.
public struct OperatorTokenRetryPolicy: Equatable, Sendable {
    public var interval: TimeInterval
    public var maxAttempts: Int
    public init(interval: TimeInterval = 15, maxAttempts: Int = 20) {
        self.interval = interval
        self.maxAttempts = maxAttempts
    }
    /// `attempt` = automatic retries already made.
    public func shouldRetry(status: OperatorTokenMirrorStatus, attempt: Int) -> Bool {
        status.isRetryable && attempt < maxAttempts
    }
}

/// Bounds every call to a possibly-blocking mirror. The call runs on a background queue and the
/// caller waits at most `timeout`; on expiry it gets `OperatorTokenMirrorError.timeout` and the
/// stuck call is abandoned (its late result is discarded — it can never be applied afterwards).
/// While an abandoned call is still stuck, further calls fail fast instead of piling up threads.
public final class GuardedOperatorTokenMirror: OperatorTokenMirror, @unchecked Sendable {
    private let inner: OperatorTokenMirror
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var inFlight = false

    public init(wrapping inner: OperatorTokenMirror, timeout: TimeInterval = 2) {
        self.inner = inner
        self.timeout = timeout
    }

    public func read() throws -> String? { try run(timeout) { try self.inner.read() } }
    public func write(_ value: String) throws { try run(timeout) { try self.inner.write(value) } }
    public func replace(_ value: String) throws { try run(timeout) { try self.inner.replace(value) } }
    @discardableResult
    public func moveFromLoginKeychain() throws -> Bool { try run(timeout) { try self.inner.moveFromLoginKeychain() } }

    /// The same guarded mirror (shared in-flight state: still at most one stuck call, never two
    /// concurrent Keychain prompts) with a different wait. Used for first-run / migration calls,
    /// where a human may have to answer a Keychain access prompt (`OperatorTokenStore.patientTimeout`),
    /// while steady-state reads keep the short default.
    public func waiting(upTo seconds: TimeInterval) -> OperatorTokenMirror {
        PatientView(guarded: self, timeout: seconds)
    }

    private final class PatientView: OperatorTokenMirror, @unchecked Sendable {
        let guarded: GuardedOperatorTokenMirror
        let timeout: TimeInterval
        init(guarded: GuardedOperatorTokenMirror, timeout: TimeInterval) {
            self.guarded = guarded
            self.timeout = timeout
        }
        func read() throws -> String? { try guarded.run(timeout) { try self.guarded.inner.read() } }
        func write(_ value: String) throws { try guarded.run(timeout) { try self.guarded.inner.write(value) } }
        func replace(_ value: String) throws { try guarded.run(timeout) { try self.guarded.inner.replace(value) } }
        @discardableResult
        func moveFromLoginKeychain() throws -> Bool { try guarded.run(timeout) { try self.guarded.inner.moveFromLoginKeychain() } }
    }

    private final class Box<T>: @unchecked Sendable {
        var result: Result<T, Error>?
    }

    private func run<T>(_ timeout: TimeInterval, _ op: @escaping @Sendable () throws -> T) throws -> T {
        lock.lock()
        if inFlight { lock.unlock(); throw OperatorTokenMirrorError.timeout }
        inFlight = true
        lock.unlock()
        let box = Box<T>()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let r = Result { try op() }
            self.lock.lock()
            box.result = r
            self.inFlight = false
            self.lock.unlock()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut { throw OperatorTokenMirrorError.timeout }
        lock.lock(); defer { lock.unlock() }
        return try box.result!.get()
    }
}

/// macOS Keychain mirror. Service `com.pedro.admiral.operator-mcp`, account `token`,
/// AfterFirstUnlockThisDeviceOnly (same accessibility as `TicketsAuthStore`), in whichever
/// keychain this build uses (`Keychain`).
public final class KeychainOperatorTokenMirror: OperatorTokenMirror {
    public static let service = "com.pedro.admiral.operator-mcp"
    public static let account = "token"

    /// `token` for the default profile, `token.<profile>` for any other, so a test or second
    /// profile can never mint, rotate or delete the main instance's token.
    public static func account(profile: String?) -> String {
        guard let profile, !profile.isEmpty else { return account }
        return account + "." + profile
    }

    private let itemAccount: String

    public init(profile: String? = nil) { itemAccount = Self.account(profile: profile) }

    private var base: [String: Any] { Keychain.query(service: Self.service, account: itemAccount) }

    public func read() throws -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw OperatorTokenMirrorError(status: status == errSecSuccess ? -1 : status)
        }
        // Undecodable data is an error, never "not set" — "not set" lets callers write over it.
        guard let value = String(data: data, encoding: .utf8) else { throw OperatorTokenMirrorError(status: -1) }
        return value
    }

    public func write(_ value: String) throws { try store(value, deleteAndAddOnFailure: false) }

    /// Update in place; if the item can't be updated (ACL owned by another build: auth failure /
    /// user denied), delete it and add a fresh one owned by this build.
    public func replace(_ value: String) throws { try store(value, deleteAndAddOnFailure: true) }

    private func store(_ value: String, deleteAndAddOnFailure: Bool) throws {
        guard let data = value.data(using: .utf8) else { throw OperatorTokenMirrorError(status: -1) }
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        if update != errSecItemNotFound {
            guard deleteAndAddOnFailure else { throw OperatorTokenMirrorError(status: update) }
            let del = SecItemDelete(base as CFDictionary)
            guard del == errSecSuccess || del == errSecItemNotFound else {
                throw OperatorTokenMirrorError(status: del)
            }
        }
        let status = Keychain.add(base, data: data)
        guard status == errSecSuccess else { throw OperatorTokenMirrorError(status: status) }
    }

    public func moveFromLoginKeychain() throws -> Bool {
        do { return try Keychain.moveFromLoginKeychain(service: Self.service, account: itemAccount) }
        catch let e as KeychainError { throw OperatorTokenMirrorError(status: e.status) }
    }
}
