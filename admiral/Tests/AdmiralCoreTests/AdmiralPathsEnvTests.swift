import XCTest
@testable import AdmiralCore

/// The `ADMIRAL_SUPPORT_DIR` env override is the isolation seam: UI tests (and profiled
/// probe instances) point `defaultSupportDir` at a throwaway dir so hooks.json / session
/// dirs never touch the user's real support dir. One method, set → assert → unset → assert,
/// so the process-wide env mutation is deterministically scoped to this test.
final class AdmiralPathsEnvTests: XCTestCase {
    func testSupportDirEnvOverrideRedirectsThenRestores() {
        let real = AdmiralPaths.defaultSupportDir

        let override = FileManager.default.temporaryDirectory
            .appendingPathComponent("admiral-env-\(UUID().uuidString)", isDirectory: true)
        // Not pre-created: the override must create the dir itself.
        XCTAssertFalse(FileManager.default.fileExists(atPath: override.path))

        setenv("ADMIRAL_SUPPORT_DIR", override.path, 1)
        defer { unsetenv("ADMIRAL_SUPPORT_DIR") }

        let redirected = AdmiralPaths.defaultSupportDir
        XCTAssertEqual(redirected.path, override.path, "ADMIRAL_SUPPORT_DIR must win over the real support dir")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: override.path, isDirectory: &isDir),
                      "override dir must be auto-created")
        XCTAssertTrue(isDir.boolValue, "override path must be a directory")

        unsetenv("ADMIRAL_SUPPORT_DIR")
        XCTAssertEqual(AdmiralPaths.defaultSupportDir.path, real.path,
                       "unsetting the override must restore the real support dir")

        try? FileManager.default.removeItem(at: override)
    }
}
