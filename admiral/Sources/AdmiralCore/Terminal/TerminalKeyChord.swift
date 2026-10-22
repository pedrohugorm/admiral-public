import Foundation

/// Encodes operator key input for `send_keys`. Named chords are conveniences; anything
/// else can be pushed as `raw:…` / `hex:…` or as literal characters — there is no
/// allowlist that rejects unknown keys.
public enum TerminalKeyChord {
    /// xterm modifier parameter: 1 + shift + 2*alt + 4*ctrl (CSI `1;<mod><letter>`).
    public struct Mods: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let shift = Mods(rawValue: 1)
        public static let alt = Mods(rawValue: 2)
        public static let ctrl = Mods(rawValue: 4)
        public var csiParam: Int { 1 + rawValue }
        public var isEmpty: Bool { rawValue == 0 }
    }

    public enum EncodeError: Error, Equatable, CustomStringConvertible {
        case empty
        case badHex(String)
        public var description: String {
            switch self {
            case .empty: return "empty key chord"
            case let .badHex(s): return "bad hex: \(s)"
            }
        }
    }

    /// Encode one chord or a comma-separated sequence. (Comma only — not `;`, so CSI
    /// `raw:\e[1;5A` stays intact.)
    public static func encode(_ spec: String) throws -> String {
        let parts = splitSpec(spec)
        guard !parts.isEmpty else { throw EncodeError.empty }
        return try parts.map { try encodeOne($0) }.joined()
    }

    public static func encodeOne(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EncodeError.empty }

        let lower = trimmed.lowercased()
        if lower.hasPrefix("raw:") {
            return unescape(String(trimmed.dropFirst(4)))
        }
        if lower.hasPrefix("hex:") {
            return try decodeHex(String(trimmed.dropFirst(4)))
        }

        var mods = Mods()
        var key = lower
        while true {
            if key.hasPrefix("shift+") { mods.insert(.shift); key = String(key.dropFirst(6)); continue }
            if key.hasPrefix("ctrl+") { mods.insert(.ctrl); key = String(key.dropFirst(5)); continue }
            if key.hasPrefix("control+") { mods.insert(.ctrl); key = String(key.dropFirst(8)); continue }
            if key.hasPrefix("option+") { mods.insert(.alt); key = String(key.dropFirst(7)); continue }
            if key.hasPrefix("alt+") { mods.insert(.alt); key = String(key.dropFirst(4)); continue }
            if key.hasPrefix("meta+") { mods.insert(.alt); key = String(key.dropFirst(5)); continue }
            if key.hasPrefix("cmd+") { mods.insert(.alt); key = String(key.dropFirst(4)); continue }
            break
        }
        guard !key.isEmpty else { throw EncodeError.empty }

        if let named = namedKey(key, mods: mods) { return named }

        if key.hasPrefix("f"), let n = Int(key.dropFirst()), n >= 1 {
            return functionKey(n, mods: mods)
        }

        let literal = stripModPrefixesPreservingCase(trimmed)
        return try literalChars(literal, mods: mods)
    }

    private static func namedKey(_ key: String, mods: Mods) -> String? {
        switch key {
        case "left", "leftarrow", "arrowleft": return csiArrow("D", mods)
        case "right", "rightarrow", "arrowright": return csiArrow("C", mods)
        case "up", "uparrow", "arrowup": return csiArrow("A", mods)
        case "down", "downarrow", "arrowdown": return csiArrow("B", mods)
        case "enter", "return", "cr": return "\r"
        case "esc", "escape": return "\u{1b}"
        case "tab":
            if mods.contains(.shift) { return "\u{1b}[Z" }
            return "\t"
        case "backspace", "bs": return "\u{7f}"
        case "delete", "del": return csiTilde(3, mods)
        case "insert", "ins": return csiTilde(2, mods)
        case "home": return mods.isEmpty ? "\u{1b}[H" : "\u{1b}[1;\(mods.csiParam)H"
        case "end": return mods.isEmpty ? "\u{1b}[F" : "\u{1b}[1;\(mods.csiParam)F"
        case "pageup", "pgup": return csiTilde(5, mods)
        case "pagedown", "pgdn", "pgdown": return csiTilde(6, mods)
        case "space": return " "
        default: return nil
        }
    }

    private static func functionKey(_ n: Int, mods: Mods) -> String {
        let code: Int
        switch n {
        case 1: code = 11
        case 2: code = 12
        case 3: code = 13
        case 4: code = 14
        case 5: code = 15
        case 6: code = 17
        case 7: code = 18
        case 8: code = 19
        case 9: code = 20
        case 10: code = 21
        case 11: code = 23
        case 12: code = 24
        default: code = 24 + (n - 12)
        }
        return csiTilde(code, mods)
    }

    private static func literalChars(_ text: String, mods: Mods) throws -> String {
        guard !text.isEmpty else { throw EncodeError.empty }
        var out = ""
        for ch in text { out += oneChar(ch, mods: mods) }
        return out
    }

    private static func oneChar(_ ch: Character, mods: Mods) -> String {
        let lower = Character(ch.lowercased())
        if mods.contains(.ctrl) {
            if lower >= "a" && lower <= "z" {
                let v = lower.unicodeScalars.first!.value - 96
                return String(UnicodeScalar(v)!)
            }
            switch lower {
            case "@": return "\u{00}"
            case "[": return "\u{1b}"
            case "\\": return "\u{1c}"
            case "]": return "\u{1d}"
            case "^": return "\u{1e}"
            case "_": return "\u{1f}"
            case "?": return "\u{7f}"
            default: return csiU(ch, mods: mods)
            }
        }
        if mods.contains(.alt) {
            let body = mods.contains(.shift) ? String(ch).uppercased() : String(ch)
            return "\u{1b}" + body
        }
        if mods.contains(.shift) {
            if lower >= "a" && lower <= "z" { return String(ch).uppercased() }
            return csiU(ch, mods: mods)
        }
        return String(ch)
    }

    private static func csiU(_ ch: Character, mods: Mods) -> String {
        let cp = ch.unicodeScalars.first!.value
        if mods.isEmpty { return "\u{1b}[\(cp)u" }
        return "\u{1b}[\(cp);\(mods.csiParam)u"
    }

    private static func csiArrow(_ letter: String, _ mods: Mods) -> String {
        if mods.isEmpty { return "\u{1b}[\(letter)" }
        return "\u{1b}[1;\(mods.csiParam)\(letter)"
    }

    private static func csiTilde(_ n: Int, _ mods: Mods) -> String {
        if mods.isEmpty { return "\u{1b}[\(n)~" }
        return "\u{1b}[\(n);\(mods.csiParam)~"
    }

    static func splitSpec(_ spec: String) -> [String] {
        var parts: [String] = []
        var current = ""
        for c in spec {
            if c == "," {
                let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { parts.append(t) }
                current = ""
                continue
            }
            if c == " " || c == "\t" || c == "\n" {
                let soFar = current.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if soFar.hasPrefix("raw:") || soFar.hasPrefix("hex:") {
                    current.append(c)
                } else {
                    let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { parts.append(t) }
                    current = ""
                }
                continue
            }
            current.append(c)
        }
        let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { parts.append(t) }
        return parts
    }

    static func unescape(_ s: String) -> String {
        var out = ""
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\" && i + 1 < chars.count {
                switch chars[i + 1] {
                case "e", "E":
                    out.append("\u{1b}"); i += 2
                case "n":
                    out.append("\n"); i += 2
                case "r":
                    out.append("\r"); i += 2
                case "t":
                    out.append("\t"); i += 2
                case "\\":
                    out.append("\\"); i += 2
                case "x" where i + 3 < chars.count:
                    let hex = String(chars[(i + 2)...(i + 3)])
                    if let v = UInt8(hex, radix: 16) {
                        out.append(Character(UnicodeScalar(v)))
                        i += 4
                    } else {
                        out.append(chars[i]); i += 1
                    }
                default:
                    out.append(chars[i + 1]); i += 2
                }
            } else {
                out.append(chars[i]); i += 1
            }
        }
        return out
    }

    static func decodeHex(_ s: String) throws -> String {
        let hex = s.filter { !$0.isWhitespace }
        guard hex.count % 2 == 0, !hex.isEmpty else { throw EncodeError.badHex(s) }
        var data = Data()
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else { throw EncodeError.badHex(s) }
            data.append(b)
            idx = next
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func stripModPrefixesPreservingCase(_ s: String) -> String {
        var rest = s
        while true {
            let lower = rest.lowercased()
            if lower.hasPrefix("shift+") { rest = String(rest.dropFirst(6)); continue }
            if lower.hasPrefix("control+") { rest = String(rest.dropFirst(8)); continue }
            if lower.hasPrefix("ctrl+") { rest = String(rest.dropFirst(5)); continue }
            if lower.hasPrefix("option+") { rest = String(rest.dropFirst(7)); continue }
            if lower.hasPrefix("alt+") { rest = String(rest.dropFirst(4)); continue }
            if lower.hasPrefix("meta+") { rest = String(rest.dropFirst(5)); continue }
            if lower.hasPrefix("cmd+") { rest = String(rest.dropFirst(4)); continue }
            break
        }
        return rest
    }
}
