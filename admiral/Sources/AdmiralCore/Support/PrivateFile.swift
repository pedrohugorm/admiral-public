import Foundation

/// Files that hold conversation text, prompts or a provider token: readable by the user who
/// runs Admiral and nobody else. Files are created `0600` from the first byte (never written
/// world-readable and tightened afterwards), and the directories made for them `0700`.
public enum PrivateFile {
    public static let fileMode: mode_t = 0o600
    public static let directoryMode: mode_t = 0o700

    /// Creates `dir` (and any missing parents) `0700`, and tightens it to `0700` if it already
    /// exists. Use only on directories Admiral owns outright. Returns false on failure.
    @discardableResult
    public static func directory(_ dir: URL) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: Int(directoryMode)])
            try fm.setAttributes([.posixPermissions: Int(directoryMode)], ofItemAtPath: dir.path)
            return true
        } catch {
            return false
        }
    }

    /// Replaces `url` with `data` atomically: a `0600` temp file in the same directory is
    /// written in full, then renamed over `url`. The parent must exist (it is created with
    /// default permissions if missing). The result is `0600` whatever `url` was before.
    public static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, fileMode)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var ok = fchmod(fd, fileMode) == 0   // the umask can only have narrowed it; be exact
        if ok { ok = writeAll(fd, data) }
        if close(fd) != 0 { ok = false }
        guard ok, rename(temp.path, url.path) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            unlink(temp.path)
            throw POSIXError(code)
        }
    }

    /// `write(_:to:)` for a UTF-8 string.
    public static func write(_ text: String, to url: URL) throws {
        try write(Data(text.utf8), to: url)
    }

    /// Writes every byte of `data` to `fd`. False on an error.
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return true }
            var written = 0
            while written < buffer.count {
                let n = Foundation.write(fd, base + written, buffer.count - written)
                guard n > 0 else { return false }
                written += n
            }
            return true
        }
    }
}
