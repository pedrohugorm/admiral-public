import Foundation

/// Decides which Admiral runs a support folder's schedules. Two instances sharing the folder (a
/// dev build beside the installed app) would otherwise open every run twice, and the second to
/// start would end the first's in-flight runs as interrupted. An exclusive `flock` on
/// `schedules/.lock`, held for the holder's life; the kernel drops it if the process dies.
public final class SchedulerLock {
    private let fd: Int32

    /// Nil when another process holds the lock (or the file can't be opened).
    public init?(base: URL) {
        let dir = base.appendingPathComponent("schedules", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        self.fd = fd
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
