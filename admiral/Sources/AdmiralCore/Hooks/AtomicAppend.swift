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

        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }

        line.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let n = write(descriptor, base + written, buffer.count - written)
                guard n > 0 else { return }  // error or EOF; drop the remainder rather than spin
                written += n
            }
        }
    }
}
