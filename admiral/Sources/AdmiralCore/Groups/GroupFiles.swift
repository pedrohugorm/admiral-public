import Foundation

/// The plain files under `<base>/groups/`, read and written without an actor, so the
/// `admiral-hook` helper (a separate process with no running `GroupStore`) and the app agree on
/// one format. `GroupStore` goes through these too.
public enum GroupFiles {
    // MARK: - Groups and logs

    public static func readGroups(base: URL) -> [ChatGroup] {
        guard let data = try? Data(contentsOf: AdmiralPaths.groupsFile(base: base)) else { return [] }
        return (try? JSONDecoder().decode([ChatGroup].self, from: data)) ?? []
    }

    public static func readLog(base: URL, group: UUID) -> [GroupMessage] {
        guard let data = try? Data(contentsOf: AdmiralPaths.groupLogFile(base: base, group: group)) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(GroupMessage.self, from: Data($0)) }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Cursors

    /// `[member UUID string: last seq given]` for one group.
    public static func readCursors(base: URL, group: UUID) -> [String: Int] {
        guard let data = try? Data(contentsOf: AdmiralPaths.groupCursorsFile(base: base, group: group)) else { return [:] }
        return (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
    }

    @discardableResult
    public static func writeCursors(_ all: [String: Int], base: URL, group: UUID) -> Bool {
        guard let data = try? JSONEncoder().encode(all) else { return false }
        return (try? PrivateFile.write(data, to: AdmiralPaths.groupCursorsFile(base: base, group: group))) != nil
    }

    @discardableResult
    public static func setCursor(_ member: UUID, base: URL, group: UUID, to seq: Int) -> Bool {
        var all = readCursors(base: base, group: group)
        all[member.uuidString] = seq
        return writeCursors(all, base: base, group: group)
    }

    // MARK: - Names

    /// `{memberKey: callsign}` — names for the hook's membership line and prompt header.
    public static func readCallsigns(base: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: AdmiralPaths.groupCallsignsFile(base: base)) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    /// Sorted keys, so an unchanged fleet writes identical bytes.
    public static func writeCallsigns(peers: [GroupPeer], base: URL) {
        let callsigns = Dictionary(peers.map { ($0.id.uuidString, $0.callsign) }, uniquingKeysWith: { a, _ in a })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let url = AdmiralPaths.groupCallsignsFile(base: base)
        // Called on the status tick: an unchanged fleet touches no file.
        if let data = try? encoder.encode(callsigns), (try? Data(contentsOf: url)) != data {
            try? PrivateFile.write(data, to: url)
        }
    }
}
