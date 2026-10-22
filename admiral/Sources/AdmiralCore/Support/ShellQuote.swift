import Foundation

/// Quoting for values spliced into a command line a POSIX shell (zsh, sh) will parse — the
/// `zsh -ilc "command claude …"` launch line and the hook commands claude runs.
public enum ShellQuote {
    /// `value` as ONE shell word: wrapped in single quotes, with each embedded `'` written as
    /// `'\''` (close the quote, an escaped quote, reopen). Inside single quotes the shell
    /// expands nothing — no `$`, backtick, `\`, glob or `;` — so the word reaches the program
    /// exactly as given, whatever it holds.
    public static func single(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
