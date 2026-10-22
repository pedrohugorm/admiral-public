import Foundation

/// How a clicked terminal link should be opened. SwiftTerm's default handler does
/// `URL(string: link)` then `NSWorkspace.shared.open` — which fails with OSStatus -50
/// (`paramErr`) for the bare, workspace-relative file paths claude emits as OSC 8 hyperlinks
/// (e.g. `.output/specs/2026-…-design.md`): those parse to a schemeless, un-openable URL.
///
/// This resolves the link into an openable form so the app never hands Launch Services a bad
/// URL: web/other-scheme URLs pass through; anything file-ish is turned into a real file URL,
/// resolving a relative path against the session's working directory. Pure + injectable so it's
/// covered by fast `swift test`; the app performs the actual `NSWorkspace` open.
public enum TerminalLink: Equatable, Sendable {
    /// An http/https/mailto/… URL — open as-is.
    case web(URL)
    /// A resolved, existing file — open (reveals in / launches the default app).
    case file(URL)
    /// Nothing openable (empty, or a path that doesn't exist) — the app can beep.
    case none

    public static func resolve(
        _ raw: String,
        cwd: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> TerminalLink {
        let link = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return .none }

        // A real URL with a non-file scheme (http, https, mailto, …) opens as-is. A `file`
        // scheme falls through to filesystem handling so relative/percent-encoded forms resolve.
        if let url = URL(string: link), let scheme = url.scheme, !scheme.isEmpty,
           scheme.lowercased() != "file" {
            return .web(url)
        }

        // Filesystem path: strip a `file://` prefix (decoding percent-escapes via URL.path),
        // expand a leading `~`, and resolve a relative path against the session cwd.
        var path: String
        if link.lowercased().hasPrefix("file://"), let url = URL(string: link) {
            path = url.path
        } else {
            path = link
        }
        path = (path as NSString).expandingTildeInPath
        if !path.hasPrefix("/") {
            path = (cwd as NSString).appendingPathComponent(path)
        }
        let resolved = URL(fileURLWithPath: path).standardizedFileURL
        return fileExists(resolved.path) ? .file(resolved) : .none
    }

    /// Punctuation prose puts straight after a path: the sentence's full stop, a closing
    /// backtick/quote/bracket, a list comma. A terminal link picked out of claude's rendered
    /// text carries it (`…/review.md.`), and so does a chat token (`` `review.md`. ``).
    static let trailingPunctuation = CharacterSet(charactersIn: ".,;:!?`'\"“”‘’)]}>*_")

    /// `raw`, then `raw` with trailing punctuation dropped one character at a time — longest
    /// first, so a file whose name really ends in one of these still wins over a shorter one.
    public static func proseCandidates(_ raw: String) -> [String] {
        var out = [raw]
        var scalars = raw.unicodeScalars[...]
        while let last = scalars.last, trailingPunctuation.contains(last) {
            scalars = scalars.dropLast()
            if !scalars.isEmpty { out.append(String(scalars)) }
        }
        return out
    }

    /// `resolve`, forgiving the punctuation prose leaves on a path (`proseCandidates`).
    public static func resolveInProse(
        _ raw: String,
        cwd: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> TerminalLink {
        for candidate in proseCandidates(raw) {
            let link = resolve(candidate, cwd: cwd, fileExists: fileExists)
            if link != .none { return link }
        }
        return .none
    }
}
