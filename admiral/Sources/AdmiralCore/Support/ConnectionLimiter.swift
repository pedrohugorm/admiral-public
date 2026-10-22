import Foundation

/// A thread-safe cap on connections in flight: `acquire` takes a slot (false when all are
/// taken, so the caller closes the connection unanswered), `release` gives it back.
public final class ConnectionLimiter: @unchecked Sendable {
    public let limit: Int
    private let lock = NSLock()
    private var active = 0

    public init(limit: Int) { self.limit = limit }

    public var inFlight: Int { lock.lock(); defer { lock.unlock() }; return active }

    public func acquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active < limit else { return false }
        active += 1
        return true
    }

    public func release() {
        lock.lock(); defer { lock.unlock() }
        active = max(active - 1, 0)
    }
}
