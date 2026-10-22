import XCTest

extension XCUIApplication {
    /// Launch-ready app in ISOLATED mode: per-run temp ADMIRAL_SUPPORT_DIR (hooks.json,
    /// session dirs) + unique ADMIRAL_PROFILE (tab stores, bridge socket). UI tests must
    /// never read or mutate the user's real config — always launch via this helper.
    static func isolated() -> XCUIApplication {
        let app = XCUIApplication()
        let token = UUID().uuidString.prefix(8).lowercased()
        app.launchEnvironment["ADMIRAL_SUPPORT_DIR"] = FileManager.default.temporaryDirectory
            .appendingPathComponent("admiral-uitest-\(token)", isDirectory: true).path
        app.launchEnvironment["ADMIRAL_PROFILE"] = "uitest-\(token)"
        return app
    }
}
