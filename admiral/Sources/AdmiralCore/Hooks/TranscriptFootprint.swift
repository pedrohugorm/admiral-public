import Foundation

/// Seeds a session's footprint from its EXISTING transcript. Scans the Claude transcript JSONL
/// for past write-tool calls (Write/Edit/MultiEdit/NotebookEdit) and aggregates the distinct
/// git repos they touched — so resuming an older session, whose writes predate the live hook,
/// still populates the panel. Resolves git per distinct directory (cached). Call OFF-MAIN.
public enum TranscriptFootprint {
    public static func repos(transcriptPath: String, cwd: String) -> [TouchedRepo] {
        guard let text = try? String(contentsOfFile: transcriptPath, encoding: .utf8) else { return [] }
        let sessionRoot = cwd.isEmpty ? nil : Git.repoRoot(at: cwd)
        let decoder = JSONDecoder()
        var rootCache: [String: String?] = [:]    // file's dir → repo root
        var branchCache: [String: String?] = [:]  // repo root → branch
        var byRoot: [String: TouchedRepo] = [:]
        var order: [String] = []

        for sub in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let raw = try? decoder.decode(RawLine.self, from: Data(sub.utf8)),
                  raw.type == "assistant", let msg = raw.message?.content else { continue }
            for block in msg.blocks where block["type"]?.stringValue == "tool_use" {
                guard let name = block["name"]?.stringValue,
                      PostToolUseHandler.writeTools.contains(name) else { continue }
                let input = block["input"]
                guard let rawPath = input?["file_path"]?.stringValue ?? input?["notebook_path"]?.stringValue,
                      !rawPath.isEmpty else { continue }
                let absPath = rawPath.hasPrefix("/") ? rawPath : (cwd as NSString).appendingPathComponent(rawPath)
                let dir = (absPath as NSString).deletingLastPathComponent
                let repoRoot: String?
                if let cached = rootCache[dir] { repoRoot = cached }
                else { let r = Git.repoRoot(at: dir); rootCache[dir] = r; repoRoot = r }
                guard let root = repoRoot else { continue }
                if var repo = byRoot[root] {
                    repo.filesWritten += 1
                    byRoot[root] = repo
                } else {
                    let branch: String?
                    if let cached = branchCache[root] { branch = cached }
                    else { let b = Git.branch(at: root); branchCache[root] = b; branch = b }
                    byRoot[root] = TouchedRepo(root: root, branches: [branch].compactMap { $0 },
                                              filesWritten: 1, insideSessionRoot: root == sessionRoot)
                    order.append(root)
                }
            }
        }
        return order.compactMap { byRoot[$0] }
    }
}
