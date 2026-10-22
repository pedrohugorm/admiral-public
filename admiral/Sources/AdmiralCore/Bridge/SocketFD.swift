import Foundation

/// Marks a file descriptor close-on-exec so a `posix_spawn`/`exec`'d child does NOT inherit it.
///
/// Every `claude` session Admiral launches is an `exec` child of the app, and it inherits every
/// open fd that lacks this flag. For a **listening** socket that's a real leak: the port stays
/// bound long after the server's own copy is closed (only the last holder frees it), so a
/// toggled-off server can't reclaim its port and a client half-connects to a socket nobody
/// `accept()`s. A leaked listener is also one a child could `accept()` on and intercept.
public enum SocketFD {
    /// Set `FD_CLOEXEC` on `fd`. Idempotent; no-op (false) on an invalid fd or an fcntl error.
    /// Returns true iff the flag is set afterward. Only affects `exec()`; the owner keeps using
    /// the fd normally.
    @discardableResult
    public static func setCloseOnExec(_ fd: Int32) -> Bool {
        guard fd >= 0 else { return false }
        let flags = fcntl(fd, F_GETFD)
        guard flags >= 0, fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0 else { return false }
        return (fcntl(fd, F_GETFD) & FD_CLOEXEC) != 0
    }
}
