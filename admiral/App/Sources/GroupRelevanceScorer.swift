import Foundation
import AdmiralCore

/// Scores one `GroupRelevance.prompt` with a headless `claude -p` on haiku, on the user's own
/// login. nil on any failure (spawn, timeout, unparseable output), which `GroupRelevance.select`
/// treats as "no answer".
enum GroupRelevanceScorer {
    static let timeout: TimeInterval = 30

    static func score(prompt: String, claude: String) async -> Double? {
        await Task.detached(priority: .utility) { run(prompt: prompt, claude: claude) }.value
    }

    private static func run(prompt: String, claude: String) -> Double? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = ["-p", "--model", "haiku", "--no-session-persistence"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        // A claude started from inside a claude session skips its own transcript otherwise.
        process.environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("CLAUDECODE") && !$0.key.hasPrefix("CLAUDE_CODE_") && $0.key != "ADMIRAL_SESSION"
        }
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        input.fileHandleForWriting.write(Data(prompt.utf8))
        try? input.fileHandleForWriting.close()

        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async { process.waitUntilExit(); done.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return GroupRelevance.parseScore(text)
    }
}
