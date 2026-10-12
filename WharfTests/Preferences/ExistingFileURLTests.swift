import XCTest
@testable import Wharf

/// `DockyPreferences.existingFileURL(at:)` backs every divider-image lookup. It
/// is a plain `fileExists` check: it follows symlinks and accepts directories.
final class ExistingFileURLTests: DockyPreferencesTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = makeTempDirectory()
    }

    func testNilPathIsNil() {
        XCTAssertNil(DockyPreferences.existingFileURL(at: nil))
    }

    func testEmptyPathIsNil() {
        XCTAssertNil(DockyPreferences.existingFileURL(at: ""))
    }

    func testNonexistentPathIsNil() {
        XCTAssertNil(DockyPreferences.existingFileURL(at: directory.appendingPathComponent("missing.png").path))
    }

    func testExistingFileReturnsItsURL() throws {
        let file = directory.appendingPathComponent("real.png")
        try Data([1, 2, 3]).write(to: file)
        let url = DockyPreferences.existingFileURL(at: file.path)
        XCTAssertEqual(url?.path, file.path)
        XCTAssertEqual(url?.isFileURL, true)
    }

    func testExistingDirectoryIsAccepted() {
        XCTAssertEqual(DockyPreferences.existingFileURL(at: directory.path)?.path, directory.path)
    }

    func testRelativePathResolvesAgainstTheCurrentDirectory() throws {
        let name = "wharf-relative-\(UUID().uuidString).png"
        let manager = FileManager.default
        let original = manager.currentDirectoryPath
        XCTAssertTrue(manager.changeCurrentDirectoryPath(directory.path))
        addTeardownBlock { _ = FileManager.default.changeCurrentDirectoryPath(original) }
        try Data([1]).write(to: directory.appendingPathComponent(name))

        XCTAssertNotNil(DockyPreferences.existingFileURL(at: name))
        XCTAssertNil(DockyPreferences.existingFileURL(at: "absent-\(name)"))
    }

    func testParentTraversalIsResolvedByTheFileSystem() throws {
        let nested = directory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("target.png")
        try Data([1]).write(to: file)

        let viaDotDot = nested.path + "/../target.png"
        XCTAssertNotNil(DockyPreferences.existingFileURL(at: viaDotDot))
        XCTAssertNil(DockyPreferences.existingFileURL(at: nested.path + "/../absent.png"))
    }

    func testTraversalThroughAMissingDirectoryIsNil() {
        XCTAssertNil(DockyPreferences.existingFileURL(at: directory.path + "/no-such-dir/../x.png"))
    }

    func testSymlinkToExistingFileIsAccepted() throws {
        let file = directory.appendingPathComponent("target.png")
        try Data([1]).write(to: file)
        let link = directory.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertNotNil(DockyPreferences.existingFileURL(at: link.path))
    }

    func testDanglingSymlinkIsNil() throws {
        let link = directory.appendingPathComponent("dangling.png")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: directory.appendingPathComponent("gone.png")
        )
        XCTAssertNil(DockyPreferences.existingFileURL(at: link.path))
    }

    func testSymlinkLoopIsNilAndDoesNotHang() throws {
        let a = directory.appendingPathComponent("a")
        let b = directory.appendingPathComponent("b")
        try FileManager.default.createSymbolicLink(at: a, withDestinationURL: b)
        try FileManager.default.createSymbolicLink(at: b, withDestinationURL: a)
        XCTAssertNil(DockyPreferences.existingFileURL(at: a.path))
    }

    func testFileURLStringIsNotTreatedAsAPath() throws {
        let file = directory.appendingPathComponent("real.png")
        try Data([1]).write(to: file)
        XCTAssertNil(DockyPreferences.existingFileURL(at: file.absoluteString))
    }

    func testTildeIsNotExpanded() {
        XCTAssertNil(DockyPreferences.existingFileURL(at: "~"))
        XCTAssertNil(DockyPreferences.existingFileURL(at: "~/Library"))
    }

    func testHostilePathStringsDoNotTrap() {
        let paths = [
            "\0", "/tmp/\0/x", String(repeating: "a", count: 100_000), String(repeating: "/..", count: 5_000),
            "\u{1F642}", "   ", "\n", "/", "//", "///", ".", "..",
        ]
        for path in paths {
            _ = DockyPreferences.existingFileURL(at: path)
        }
    }

    func testDividerAccessorsRejectMissingFilesBeforeConsultingThemes() throws {
        // A real user override resolves without ThemeManager involvement.
        let file = directory.appendingPathComponent("divider.png")
        try Data([1]).write(to: file)
        let prefs = makePrefs()
        prefs.dividerImagePath = file.path
        prefs.leftDividerImagePath = file.path
        prefs.rightDividerImagePath = file.path
        pinMirrorFlagOff(prefs)
        // Overrides are only honored while their key is marked user-overridden,
        // which the setters above did.
        XCTAssertEqual(prefs.effectiveDividerImageURL?.path, file.path)
        XCTAssertEqual(prefs.effectiveLeftDividerImageURL?.path, file.path)
        XCTAssertEqual(prefs.effectiveRightDividerImageURL?.path, file.path)
    }

    func testResolvedDividerImageMirrorsLeftOntoRight() throws {
        let left = directory.appendingPathComponent("left.png")
        let right = directory.appendingPathComponent("right.png")
        try Data([1]).write(to: left)
        try Data([2]).write(to: right)
        let prefs = makePrefs()
        prefs.leftDividerImagePath = left.path
        prefs.rightDividerImagePath = right.path
        pinMirrorFlagOff(prefs)

        XCTAssertEqual(prefs.resolvedDividerImage(forPositionClass: .left)?.url.path, left.path)
        XCTAssertEqual(prefs.resolvedDividerImage(forPositionClass: .left)?.mirrored, false)
        XCTAssertEqual(prefs.resolvedDividerImage(forPositionClass: .right)?.url.path, right.path)

        prefs.mirrorsLeftDividerOnRight = true
        let mirrored = prefs.resolvedDividerImage(forPositionClass: .right)
        XCTAssertEqual(mirrored?.url.path, left.path)
        XCTAssertEqual(mirrored?.mirrored, true)
    }

    /// Marks the mirror flag as user-set (to false) so an active theme on the
    /// machine running the tests cannot change which image the right divider uses.
    private func pinMirrorFlagOff(_ prefs: DockyPreferences) {
        prefs.mirrorsLeftDividerOnRight = true
        prefs.mirrorsLeftDividerOnRight = false
    }
}
