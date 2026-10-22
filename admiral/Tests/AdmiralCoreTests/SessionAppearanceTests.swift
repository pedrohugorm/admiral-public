import XCTest
@testable import AdmiralCore

@MainActor
final class SessionAppearanceTests: XCTestCase {
    private func tempDefaults() -> UserDefaults {
        UserDefaults(suiteName: "admiral-test-\(UUID().uuidString)")!
    }

    private func makeManager(_ store: SessionAppearanceStore) -> SessionManager {
        SessionManager(
            host: FakeTerminalHost(), claudeHome: URL(fileURLWithPath: "/tmp/none"),
            executablePath: "/usr/bin/claude", appearanceStore: store
        )
    }

    func testStoreRoundTripKeyedBySession() {
        let store = SessionAppearanceStore(defaults: tempDefaults())
        XCTAssertEqual(store.appearance(forSession: "s1"), SessionAppearance())

        let a = SessionAppearance(name: "API", colorHex: "#E8912D", symbol: "server.rack")
        store.setAppearance(a, forSession: "s1")
        XCTAssertEqual(store.appearance(forSession: "s1"), a)
        XCTAssertEqual(store.appearance(forSession: "s2"), SessionAppearance(), "keyed by session, not cwd")

        store.remove(forSession: "s1")
        XCTAssertEqual(store.appearance(forSession: "s1"), SessionAppearance())
    }

    func testDisplayTitlePrecedenceAndSymbolFallback() {
        var s = AgentSession(callsign: "cs", cwd: "/x", title: "AI Title")
        XCTAssertEqual(s.displayTitle, "cs")                // callsign — claude's title is ignored
        s.customName = "Custom"
        XCTAssertEqual(s.displayTitle, "Custom")            // rename wins
        s.customName = ""
        XCTAssertEqual(s.displayTitle, "cs")                // blank rename → callsign

        XCTAssertEqual(s.avatarSymbolName, s.agentType.symbolName)
        s.avatarSymbol = "anchor"
        XCTAssertEqual(s.avatarSymbolName, "anchor")
    }

    /// Appearance is persisted against the session's own id and restored when THAT SAME
    /// session is re-commissioned on relaunch.
    func testAppearancePersistsAndRestoresForTheSameSession() {
        let store = SessionAppearanceStore(defaults: tempDefaults())
        let manager = makeManager(store)
        let s = manager.commission(callsign: "ai", cwd: "/Users/me/code/ai", sessionID: "00000000-0000-4000-8000-000000000001")
        manager.rename(s.id, to: "My API")  // a name is an address: the space becomes a hyphen
        manager.setAppearance(s.id, colorHex: "#2BA84A", symbol: "bolt")

        XCTAssertEqual(manager.sessions.first?.displayTitle, "My-API")
        XCTAssertEqual(store.appearance(forSession: "00000000-0000-4000-8000-000000000001"),
                       SessionAppearance(name: "My-API", colorHex: "#2BA84A", symbol: "bolt"))

        // Relaunch: a fresh manager restoring the SAME session id gets its look back.
        let manager2 = makeManager(store)
        let restored = manager2.commission(callsign: "ai", cwd: "/Users/me/code/ai", sessionID: "00000000-0000-4000-8000-000000000001")
        XCTAssertEqual(restored.customName, "My-API")
        XCTAssertEqual(restored.avatarColorHex, "#2BA84A")
        XCTAssertEqual(restored.avatarSymbol, "bolt")
    }

    /// The reported bug: two terminals in the SAME folder must be independent. Customizing
    /// one must not bleed into the other (they were colliding on a shared cwd key).
    func testTwoSessionsInSameFolderAreIndependent() {
        let store = SessionAppearanceStore(defaults: tempDefaults())
        let manager = makeManager(store)
        let a = manager.commission(callsign: "work", cwd: "/x")
        let b = manager.commission(callsign: "work", cwd: "/x")  // same folder
        XCTAssertNotEqual(a.claudeSessionID, b.claudeSessionID)

        manager.rename(b.id, to: "Renamed B")
        manager.setAppearance(b.id, colorHex: "#FF0000", symbol: "flame")

        let aNow = manager.sessions.first { $0.id == a.id }
        XCTAssertNil(aNow?.customName, "editing B must not rename A")
        XCTAssertNil(aNow?.avatarColorHex, "editing B must not recolor A")
        XCTAssertNil(aNow?.avatarSymbol, "editing B must not re-icon A")
    }

    /// A brand-new terminal in a previously-customized folder starts fresh (no
    /// inheritance), and deleting a session forgets only its own look.
    func testNewTerminalIsFreshAndDeleteClearsOwnAppearance() {
        let store = SessionAppearanceStore(defaults: tempDefaults())
        let manager = makeManager(store)
        let s = manager.commission(callsign: "work", cwd: "/Users/me/code/ai", sessionID: "00000000-0000-4000-8000-00000000000a")
        manager.rename(s.id, to: "PROJ-123")
        XCTAssertEqual(store.appearance(forSession: "00000000-0000-4000-8000-00000000000a").name, "PROJ-123")

        // A NEW terminal in the same folder is fresh (different id → nothing inherited).
        let fresh = manager.commission(callsign: "work", cwd: "/Users/me/code/ai")
        XCTAssertNil(fresh.customName, "a new terminal must not reuse a sibling's name")
        XCTAssertEqual(fresh.displayTitle, "work")

        // Deleting the renamed session forgets only its look.
        manager.delete(s.id)
        XCTAssertEqual(store.appearance(forSession: "00000000-0000-4000-8000-00000000000a"), SessionAppearance())
    }
}
