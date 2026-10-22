import XCTest
@testable import AdmiralCore

/// `touched.jsonl` is written by the `admiral-hook` helper, and Claude Code runs hooks for
/// parallel tool calls concurrently — so several short-lived processes append at once.
final class HookLogTests: XCTestCase {
    private var url: URL!

    override func setUpWithError() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hooklog-\(UUID().uuidString)")
            .appendingPathComponent("touched.jsonl")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func event(_ path: String) -> TouchedRepoEvent {
        TouchedRepoEvent(ts: "2026-07-09T00:00:00Z", tool: "Write", filePath: path,
                         repoRoot: "/repo", branch: "main", insideSessionRoot: true)
    }

    private func lineCount() throws -> Int {
        let data = try Data(contentsOf: url)
        return data.split(separator: 0x0A).filter { !$0.isEmpty }.count
    }

    func testAppendCreatesTheFileAndWritesOneLine() throws {
        HookLog.append(event("/a.txt"), to: url)

        XCTAssertEqual(try lineCount(), 1)
    }

    func testSequentialAppendsAccumulate() throws {
        HookLog.append(event("/a.txt"), to: url)
        HookLog.append(event("/b.txt"), to: url)

        XCTAssertEqual(try lineCount(), 2)
    }

    /// The real-world case: several hook processes appending at once. `seekToEnd` + `write`
    /// is not atomic across descriptors — two writers seek to the same offset and one
    /// clobbers the other. Only `O_APPEND` makes the seek-and-write atomic.
    func testConcurrentAppendsDoNotLoseLines() throws {
        DispatchQueue.concurrentPerform(iterations: 100) { i in
            HookLog.append(event("/file-\(i).txt"), to: url)
        }

        XCTAssertEqual(try lineCount(), 100)
    }

    /// Every surviving line must be independently parseable — an interleaved write would
    /// corrupt neighbours, not merely drop them.
    func testConcurrentAppendsProduceOnlyWellFormedLines() throws {
        DispatchQueue.concurrentPerform(iterations: 50) { i in
            HookLog.append(event("/file-\(i).txt"), to: url)
        }

        let data = try Data(contentsOf: url)
        let decoded = data.split(separator: 0x0A).filter { !$0.isEmpty }.compactMap {
            try? JSONDecoder().decode(TouchedRepoEvent.self, from: Data($0))
        }
        XCTAssertEqual(decoded.count, 50)
    }
}
