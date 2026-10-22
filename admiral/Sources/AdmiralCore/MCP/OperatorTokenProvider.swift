import Foundation

/// The operator token as the HTTP endpoints see it: a thread-safe, swappable value that starts
/// EMPTY ("unavailable") and is filled once the Keychain resolution finishes. The API server
/// binds its port immediately and never waits for the Keychain; until this holds a token the
/// guarded routes answer `503 token unavailable` (never 401, never a hang). Swapping the value
/// needs no server restart.
public final class OperatorTokenProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var current: String

    public init(_ initial: String = "") { current = initial }

    /// The token to check against, `""` while unavailable.
    public var token: String {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }

    public var isAvailable: Bool { !token.isEmpty }
}

/// Outcome of checking a request against the operator token.
public enum OperatorAuthResult: Equatable, Sendable {
    case ok
    case unauthorized
    /// No token is known yet (Keychain still resolving / unavailable).
    case unavailable

    @MainActor public static func check(_ request: HTTPRequest, expected: String) -> OperatorAuthResult {
        guard !expected.isEmpty else { return .unavailable }
        return OperatorMCPEndpoint.isAuthorized(request, token: expected) ? .ok : .unauthorized
    }
}
