import XCTest
@testable import AdmiralCore

/// Siri's "Commission Session" launches claude only in a folder that exists. Real paths in a
/// unique temp dir; nothing is launched.
final class CommissionDirectoryTests: XCTestCase {
    func testOnlyAnExistingFolderIsTaken() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("cwd-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }   // only this test's temp dir
        let project = home.appendingPathComponent("project")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let file = home.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: file)
        let h = home.standardizedFileURL.path

        XCTAssertEqual(CommissionDirectory.resolve(project.path, home: h), project.standardizedFileURL.path)
        XCTAssertEqual(CommissionDirectory.resolve("~/project", home: h), project.standardizedFileURL.path)
        XCTAssertEqual(CommissionDirectory.resolve(nil, home: h), h, "no folder named = home")
        XCTAssertEqual(CommissionDirectory.resolve("  ", home: h), h)

        XCTAssertNil(CommissionDirectory.resolve(home.appendingPathComponent("missing").path, home: h))
        XCTAssertNil(CommissionDirectory.resolve(file.path, home: h), "a file is not a folder")
        XCTAssertNil(CommissionDirectory.resolve("project", home: h), "a relative path is refused")
        XCTAssertNil(CommissionDirectory.resolve("~/missing", home: h))
    }
}
