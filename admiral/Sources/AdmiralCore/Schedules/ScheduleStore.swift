import Foundation

/// Schedules on disk: `<base>/schedules/<id>.json`, and each one's run index at
/// `<base>/schedules/<id>/runs.jsonl`. Keyed by id, so a rename keeps the history.
public struct ScheduleStore: Sendable {
    let dir: URL

    public init(base: URL) {
        dir = base.appendingPathComponent("schedules", isDirectory: true)
    }

    public func all() -> [Schedule] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decoder.decode(Schedule.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func save(_ schedule: Schedule) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? Self.encoder(pretty: true).encode(schedule) else { return }
        try? data.write(to: file(schedule.id), options: .atomic)
    }

    /// The schedule and its history.
    public func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: file(id))
        try? FileManager.default.removeItem(at: runsDir(id))
    }

    /// Append the run's current state; the latest line for a run id is the one that counts.
    public func record(_ run: ScheduleRun, for id: UUID) {
        try? FileManager.default.createDirectory(at: runsDir(id), withIntermediateDirectories: true)
        guard let data = try? Self.encoder(pretty: false).encode(run) else { return }
        AtomicAppend.line(data, to: runsDir(id).appendingPathComponent("runs.jsonl"))
    }

    /// Each run as its latest line, newest first.
    public func runs(for id: UUID) -> [ScheduleRun] {
        guard let raw = try? String(contentsOf: runsDir(id).appendingPathComponent("runs.jsonl"), encoding: .utf8)
        else { return [] }
        var latest: [String: ScheduleRun] = [:]
        var order: [String: Int] = [:]
        for line in raw.split(separator: "\n") {
            guard let run = try? Self.decoder.decode(ScheduleRun.self, from: Data(line.utf8)) else { continue }
            if order[run.id] == nil { order[run.id] = order.count }
            latest[run.id] = run
        }
        return latest.values.sorted {
            $0.startedAt != $1.startedAt ? $0.startedAt > $1.startedAt : order[$0.id, default: 0] > order[$1.id, default: 0]
        }
    }

    private func file(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).json") }
    private func runsDir(_ id: UUID) -> URL { dir.appendingPathComponent(id.uuidString, isDirectory: true) }

    private static func encoder(pretty: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return encoder
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
