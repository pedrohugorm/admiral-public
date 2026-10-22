import XCTest
@testable import AdmiralCore

final class ScratchTabNamerTests: XCTestCase {
    func testDockerStyleAdjectiveNoun() {
        // Deterministic random: always pick index 0.
        let name = ScratchTabNamer.name(existing: [], random: { _ in 0 })
        XCTAssertEqual(name, "\(ScratchTabNamer.adjectives[0])_\(ScratchTabNamer.nouns[0])")
    }

    func testAvoidsExistingNamesCaseInsensitively() {
        // First pick collides (index 0), the retry (index 1) is free.
        var calls = 0
        let taken = "\(ScratchTabNamer.adjectives[0])_\(ScratchTabNamer.nouns[0])".uppercased()
        let name = ScratchTabNamer.name(existing: [taken], random: { n in
            defer { calls += 1 }
            return calls < 2 ? 0 : 1 % n
        })
        XCTAssertNotEqual(name.lowercased(), taken.lowercased())
    }

    func testExhaustedAttemptsFallBackToNumericSuffix() {
        // Every random pick returns index 0, and that pair is taken: suffix appears.
        let base = "\(ScratchTabNamer.adjectives[0])_\(ScratchTabNamer.nouns[0])"
        let name = ScratchTabNamer.name(existing: [base, "\(base)2"], random: { _ in 0 })
        XCTAssertEqual(name, "\(base)3")
    }
}
