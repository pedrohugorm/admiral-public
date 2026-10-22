import Foundation

/// Docker-style names for API-created scratch tabs (`quirky_otter`). Pure — the
/// caller injects the random pick so tests are deterministic.
public enum ScratchTabNamer {
    static let adjectives = [
        "amber", "bold", "brisk", "calm", "clever", "cosmic", "crisp", "eager",
        "fuzzy", "gentle", "jolly", "keen", "lively", "lucid", "mellow", "nifty",
        "quirky", "rapid", "silent", "smooth", "solar", "spry", "vivid", "witty",
    ]
    static let nouns = [
        "otter", "falcon", "harbor", "comet", "willow", "badger", "lantern", "maple",
        "onyx", "puffin", "quartz", "raven", "sable", "thistle", "walrus", "zephyr",
        "beacon", "cedar", "delta", "ember", "fjord", "garnet", "heron", "isle",
    ]

    /// A name not present in `existing` (case-insensitive). Tries `attempts` random
    /// pairs, then appends a numeric suffix to the last pair until it is free.
    /// `random(n)` returns a value in `0..<n` (injected for deterministic tests).
    public static func name(
        existing: Set<String>, attempts: Int = 8,
        random: (Int) -> Int = { Int.random(in: 0..<$0) }
    ) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        var candidate = ""
        for _ in 0..<max(attempts, 1) {
            candidate = "\(adjectives[random(adjectives.count)])_\(nouns[random(nouns.count)])"
            if !taken.contains(candidate) { return candidate }
        }
        var n = 2
        while taken.contains("\(candidate)\(n)") { n += 1 }
        return "\(candidate)\(n)"
    }
}
