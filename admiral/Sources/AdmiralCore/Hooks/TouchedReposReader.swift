import Foundation

/// Aggregates a session's `touched.jsonl` into the distinct git repos it has written to, in
/// first-touched order. Events with no repo root (non-git writes) are ignored. The whole
/// (small) log is read each time, mirroring how transcripts are tailed.
public enum TouchedReposReader {
    public static func read(base: URL, token: String) -> [TouchedRepo] {
        read(logURL: AdmiralPaths.touchedLog(base: base, token: token))
    }

    public static func read(logURL: URL) -> [TouchedRepo] {
        guard let content = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        var byRoot: [String: TouchedRepo] = [:]
        var order: [String] = []
        for sub in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let e = try? decoder.decode(TouchedRepoEvent.self, from: Data(sub.utf8)),
                  let root = e.repoRoot else { continue }
            if var repo = byRoot[root] {
                repo.filesWritten += 1
                if let b = e.branch, !repo.branches.contains(b) { repo.branches.append(b) }
                byRoot[root] = repo
            } else {
                byRoot[root] = TouchedRepo(
                    root: root, branches: [e.branch].compactMap { $0 },
                    filesWritten: 1, insideSessionRoot: e.insideSessionRoot)
                order.append(root)
            }
        }
        return order.compactMap { byRoot[$0] }
    }
}
