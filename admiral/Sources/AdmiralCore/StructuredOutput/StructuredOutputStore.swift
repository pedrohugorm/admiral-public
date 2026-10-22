import Foundation

/// A parsed structured-output request: the schema the result must match and how the
/// response delivers it (`output_format` → JSON in a text block; a forced tool →
/// a `tool_use` block).
public struct StructuredOutputSpec: Equatable, Sendable {
    public let schema: JSONValue
    public let delivery: StructuredOutputState.Delivery
    public let toolName: String?
    /// Which slot this arm claims. Defaults to the endpoint's, since that is the only
    /// caller that builds a spec from a request rather than from a fixed feature.
    public let type: ArmType
    public init(schema: JSONValue, delivery: StructuredOutputState.Delivery,
                toolName: String? = nil, type: ArmType = .api) {
        self.schema = schema
        self.delivery = delivery
        self.toolName = toolName
        self.type = type
    }
}

/// The tripwire's on-disk state: what the session owes (schema + delivery), how the
/// loop is going (attempts / blocks), and its outcome (fulfilled result or failed).
public struct StructuredOutputState: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case armed, fulfilled, failed }
    public enum Delivery: String, Codable, Sendable {
        case jsonText = "json_text"
        case toolUse = "tool_use"
    }

    public var schema: JSONValue
    public var delivery: Delivery
    /// The forced tool's name (delivery == .toolUse); echoed in the tool_use response block.
    public var toolName: String?
    /// Failed `set_structured_output` validations so far — the tool gives up at `maxAttempts`.
    public var attempts: Int
    /// Stop-hook blocks issued without the tool resolving — force-disarm at `maxBlocks`
    /// so a session that ignores the instruction cannot loop forever.
    public var blocks: Int
    public var status: Status
    /// The validated result (status == .fulfilled).
    public var result: JSONValue?
    /// The `output` slot only: which turn this is, counted up at every re-arm, so a follower
    /// can tell one turn's outcome from the next. Nil on the other slots.
    public var round: Int?
    /// When the slot left `armed` (fulfilled, or failed by the attempt budget or the Stop
    /// block budget). Nil while armed and in files written before this field existed.
    public var completedAt: Date?
    /// Why the slot failed: the last validation errors, or the Stop budget's reason when the
    /// session never even tried. Nil unless failed (and in older files).
    public var violations: [String]?
    /// The `output` slot only: a Stop already let this fulfilled round go. A further Stop in the
    /// same prompt means the run continued past it (background-task wake-up, a goals-review
    /// block), so the Stop hook re-arms the slot for the continuation's answer.
    public var settled: Bool?

    public static let maxAttempts = 3
    public static let maxBlocks = 3

    public init(schema: JSONValue, delivery: Delivery, toolName: String? = nil,
                attempts: Int = 0, blocks: Int = 0, status: Status = .armed,
                result: JSONValue? = nil, round: Int? = nil,
                completedAt: Date? = nil, violations: [String]? = nil, settled: Bool? = nil) {
        self.schema = schema
        self.delivery = delivery
        self.toolName = toolName
        self.attempts = attempts
        self.blocks = blocks
        self.status = status
        self.result = result
        self.round = round
        self.completedAt = completedAt
        self.violations = violations
        self.settled = settled
    }
}

/// Every slot a session currently owes, keyed by `ArmType.rawValue` so the file stays
/// readable when you cat it during a debug session.
public struct StructuredOutputSlots: Codable, Equatable, Sendable {
    public var slots: [String: StructuredOutputState]

    public init(slots: [String: StructuredOutputState] = [:]) { self.slots = slots }

    public subscript(type: ArmType) -> StructuredOutputState? {
        get { slots[type.rawValue] }
        set { slots[type.rawValue] = newValue }
    }

    /// Armed slots in Stop-hook priority order (see `ArmType`).
    public var armed: [ArmType] {
        ArmType.allCases.filter { self[$0]?.status == .armed }
    }

    public var isEmpty: Bool { slots.isEmpty }
}

/// File I/O for the tripwire — one owner for its location and encoding, shared by the
/// endpoint (app process) and the Stop hook (helper process), the same way
/// `SessionContextStore` is shared.
///
/// Every mutation is a read-modify-write of the whole map, because two processes touch it:
/// the app arms and clears, the hook counts blocks. That was already true of the single-slot
/// file; keying it does not widen the window, since each writer only ever touches its own key.
public enum StructuredOutputStore {
    public static func readAll(base: URL, token: String) -> StructuredOutputSlots {
        let url = AdmiralPaths.structuredOutputFile(base: base, token: token)
        guard let data = try? Data(contentsOf: url) else { return StructuredOutputSlots() }
        if let slots = try? JSONDecoder().decode(StructuredOutputSlots.self, from: data) {
            return slots
        }
        // A pre-typing file holds one bare state, and that arm was always the endpoint's.
        guard let legacy = try? JSONDecoder().decode(StructuredOutputState.self, from: data) else {
            return StructuredOutputSlots()
        }
        var slots = StructuredOutputSlots()
        slots[.api] = legacy
        return slots
    }

    public static func read(base: URL, token: String,
                            type: ArmType = .api) -> StructuredOutputState? {
        readAll(base: base, token: token)[type]
    }

    @discardableResult
    public static func write(_ state: StructuredOutputState, base: URL, token: String,
                             type: ArmType = .api) -> Bool {
        var slots = readAll(base: base, token: token)
        slots[type] = state
        return writeAll(slots, base: base, token: token)
    }

    @discardableResult
    public static func writeAll(_ slots: StructuredOutputSlots, base: URL, token: String) -> Bool {
        guard !slots.isEmpty else { clearAll(base: base, token: token); return true }
        guard let data = try? JSONEncoder().encode(slots) else { return false }
        let url = AdmiralPaths.structuredOutputFile(base: base, token: token)
        do { try data.write(to: url, options: .atomic) } catch { return false }
        return true
    }

    /// Release one slot. The file disappears once the last slot goes, so "no file" keeps
    /// meaning "this session owes nothing".
    public static func clear(base: URL, token: String, type: ArmType = .api) {
        var slots = readAll(base: base, token: token)
        guard slots[type] != nil else { return }
        slots[type] = nil
        writeAll(slots, base: base, token: token)
    }

    public static func clearAll(base: URL, token: String) {
        try? FileManager.default.removeItem(
            at: AdmiralPaths.structuredOutputFile(base: base, token: token))
    }
}
