import Foundation

/// Appends one line to a file so that concurrent *processes* cannot lose or interleave it.
///
/// Claude Code runs hooks for parallel tool calls concurrently, so several short-lived
/// `admiral-hook` processes append to the same log at once. The obvious implementation —
/// open, `seekToEnd`, write — is **not** safe: each descriptor has its own file offset, so
/// two writers can both seek to the same end and one overwrites the other. Measured on this
/// codebase: 100 concurrent writers left 4 lines, only 1 of them well-formed.
///
/// `O_APPEND` moves the seek into the same atomic operation as the write, for a regular
/// file. Keep records small so a single `write(2)` carries the whole line.
enum AtomicAppend {
    /// Appends `data` followed by a newline. Silently does nothing on failure: a log write
    /// must never wedge the agent.
    static func line(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        var line = data
        line.append(0x0A)

        // These logs carry prompts and replies: created 0600, and an older 0644 file is
        // tightened on its next append.
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, PrivateFile.fileMode)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        _ = fchmod(descriptor, PrivateFile.fileMode)

        // On an error or EOF the remainder is dropped rather than spun on.
        _ = PrivateFile.writeAll(descriptor, line)
    }
}
