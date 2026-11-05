import XCTest
@testable import NoteIsland

final class AcceptancePathsTests: XCTestCase {
    func testProductionKeepsExistingLibraryEvenIfAcceptancePropertyWasAccidentallyAdded() throws {
        let base=URL(fileURLWithPath: "/tmp/synthetic-support")
        XCTAssertEqual(try NoteIslandPaths.resolveDirectory(bundleID: "dev.raven.note-island", acceptancePath: "/tmp/ignored", applicationSupport: base).path,
                       "/tmp/synthetic-support/NoteIsland")
    }

    func testAcceptanceFilesStayInExplicitSyntheticDirectoryAndInvalidConfigurationFailsClosed() throws {
        let base=URL(fileURLWithPath: "/tmp/synthetic-support")
        XCTAssertEqual(try NoteIslandPaths.resolveDirectory(bundleID: "dev.raven.note-island.acceptance", acceptancePath: "/tmp/note-island-qa", applicationSupport: base).path,
                       "/tmp/note-island-qa")
        for path in [nil,"relative", "/"] as [String?] {
            XCTAssertThrowsError(try NoteIslandPaths.resolveDirectory(bundleID: "dev.raven.note-island.acceptance", acceptancePath: path, applicationSupport: base))
        }
    }
}
