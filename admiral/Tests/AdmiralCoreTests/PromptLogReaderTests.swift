import XCTest
@testable import AdmiralCore

final class PromptLogReaderTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompts-\(UUID().uuidString).jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    private func append(_ text: String) {
        let data = Data(text.utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    private func line(_ prompt: String) -> String {
        let data = try! JSONEncoder().encode(PromptEvent(ts: "T", prompt: prompt))
        return String(data: data, encoding: .utf8)! + "\n"
    }

    func testMissingFileReturnsEmpty() {
        let r = PromptLogReader.read(url: url, offset: 0)
        XCTAssertEqual(r.events, [])
        XCTAssertEqual(r.offset, 0)
    }

    func testIncrementalReads() {
        append(line("one"))
        let first = PromptLogReader.read(url: url, offset: 0)
        XCTAssertEqual(first.events.map(\.prompt), ["one"])

        append(line("two"))
        let second = PromptLogReader.read(url: url, offset: first.offset)
        XCTAssertEqual(second.events.map(\.prompt), ["two"])

        let third = PromptLogReader.read(url: url, offset: second.offset)
        XCTAssertEqual(third.events, [])
        XCTAssertEqual(third.offset, second.offset)
    }

    func testPartialTrailingLineNotConsumed() {
        append(line("one"))
        append("{\"ts\":\"T\",\"prom")  // torn write: no trailing newline
        let r = PromptLogReader.read(url: url, offset: 0)
        XCTAssertEqual(r.events.map(\.prompt), ["one"])
        // Completing the line later must yield the second event from the returned offset.
        append("pt\":\"two\"}\n")
        let r2 = PromptLogReader.read(url: url, offset: r.offset)
        XCTAssertEqual(r2.events.map(\.prompt), ["two"])
    }

    func testShrunkFileRestartsFromZero() {
        append(line("one") + line("two"))
        let r = PromptLogReader.read(url: url, offset: 0)
        try? FileManager.default.removeItem(at: url)
        append(line("fresh"))
        let r2 = PromptLogReader.read(url: url, offset: r.offset)
        XCTAssertEqual(r2.events.map(\.prompt), ["fresh"])
    }

    func testMalformedLineSkipped() {
        append("not json\n" + line("ok"))
        let r = PromptLogReader.read(url: url, offset: 0)
        XCTAssertEqual(r.events.map(\.prompt), ["ok"])
    }
}
