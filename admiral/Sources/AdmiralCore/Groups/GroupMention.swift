import Foundation

/// `@name` and `@all` tokens in a group message.
///
/// Only an exact member handle (a callsign, any case) or `all` counts; any other `@word` stays
/// literal text, so an email address, `@types/node` or a decorator in an agent's reply never
/// wakes anyone.
public enum GroupMention {
    public struct Handle: Equatable, Sendable {
        public let id: UUID
        public let name: String
        public init(id: UUID, name: String) { self.id = id; self.name = name }
    }

    public struct Parsed: Equatable, Sendable {
        public var ids: [UUID] = []
        public var all = false
        public var isEmpty: Bool { ids.isEmpty && !all }
    }

    public static func parse(_ text: String, handles: [Handle]) -> Parsed {
        var parsed = Parsed()
        for token in tokens(text) {
            let name = token.name.lowercased()
            if name == "all" {
                parsed.all = true
            } else if let handle = handles.first(where: { $0.name.lowercased() == name }),
                      !parsed.ids.contains(handle.id) {
                parsed.ids.append(handle.id)
            }
        }
        return parsed
    }

    /// One `@word` in a text: where it sits (in Characters, `@` included) and the word.
    public struct Token: Equatable, Sendable {
        public let offset: Int
        public let length: Int
        public let name: String
    }

    /// Every `@word` candidate, by the same rule `parse` applies. The window colors the ones
    /// that name a member (`mentions`), so what is colored is exactly what wakes someone.
    public static func tokens(_ text: String) -> [Token] {
        var found: [Token] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            guard chars[i] == "@", i == 0 || !isWordish(chars[i - 1]) else { i += 1; continue }
            var j = i + 1
            while j < chars.count, isWordish(chars[j]) { j += 1 }
            // Trailing dots and dashes are sentence punctuation, not part of a callsign.
            var end = j
            while end > i + 1, chars[end - 1] == "." || chars[end - 1] == "-" { end -= 1 }
            if end > i + 1 {
                found.append(Token(offset: i, length: end - i, name: String(chars[(i + 1)..<end])))
            }
            i = max(j, i + 1)
        }
        return found
    }

    /// The tokens that name a member (any case) or `all` — the ones the window colors.
    public static func mentions(_ text: String, names: [String]) -> [Token] {
        let known = Set(names.map { $0.lowercased() } + ["all"])
        return tokens(text).filter { known.contains($0.name.lowercased()) }
    }

    private static func isWordish(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "." || c == "-" || c == "@" || c == "/"
    }
}
