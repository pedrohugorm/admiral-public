import XCTest
@testable import AdmiralCore

/// The plan is cumulative, so it must survive the tail window `loadTail` renders turns
/// through. Without this the Footprint panel's "n / m" shrinks as a session grows.
final class PlanTailWindowTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-tail-\(UUID().uuidString).jsonl")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: url) }

    private func taskCreate(_ id: String, _ subject: String) -> [String] {
        [
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"\#(id)","name":"TaskCreate","input":{"subject":"\#(subject)"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"\#(id)","content":"Task #\#(id.dropFirst(2)) created successfully: \#(subject)"}]}}"#,
        ]
    }
    private func taskUpdate(_ taskID: String, _ status: String) -> String {
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"u-\#(taskID)-\#(status)","name":"TaskUpdate","input":{"taskId":"\#(taskID)","status":"\#(status)"}}]}}"#
    }
    private func chatter(_ count: Int) -> [String] {
        (0..<count).map { #"{"type":"assistant","message":{"content":[{"type":"text","text":"line \#($0)"}]}}"# }
    }

    private func write(_ lines: [String]) {
        try! lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func testTasksOlderThanTheTailWindowStillCount() {
        var lines = taskCreate("id1", "early task") + taskCreate("id2", "second task")
        lines += [taskUpdate("1", "completed")]
        lines += chatter(900)                       // pushes the creates far out of the tail
        lines += taskCreate("id3", "recent task")
        write(lines)

        let convo = TranscriptStore.loadTail(path: url.path)
        let plan = convo.plan
        XCTAssertEqual(plan?.items.map(\.title),
                       ["early task", "second task", "recent task"])
        XCTAssertEqual(plan?.progress.done, 1, "the early completion still counts")
        XCTAssertEqual(plan?.progress.total, 3)
    }

    /// The turns stay windowed — this fix is about the plan, not about rendering everything.
    func testTurnsAreStillTailed() {
        write(chatter(900))
        XCTAssertLessThanOrEqual(TranscriptStore.loadTail(path: url.path).turns.count, 600)
    }

    func testShortTranscriptsAreUnaffected() {
        write(taskCreate("id1", "only task"))
        let convo = TranscriptStore.loadTail(path: url.path)
        XCTAssertEqual(convo.plan?.items.map(\.title), ["only task"])
    }

    func testGateSkipsUnrelatedLines() {
        XCTAssertFalse(TranscriptParser.isPlanRelevant(#"{"type":"assistant","text":"hello"}"#))
        XCTAssertTrue(TranscriptParser.isPlanRelevant(#"{"name":"TaskCreate"}"#))
        XCTAssertTrue(TranscriptParser.isPlanRelevant(#"{"content":"Task #4 created successfully"}"#))
    }
}
