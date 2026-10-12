import Combine
import XCTest
@testable import Wharf

// MARK: - App folder naming

final class AppFolderNamingTests: XCTestCase {

    private func apps(_ names: [String]) -> [AppTile] {
        names.enumerated().map { AppTile(bundleIdentifier: "com.test.\($0.offset)", displayName: $0.element) }
    }

    private func seed(_ names: [String]) -> String { appFolderSeedName(for: apps(names)) }

    // MARK: Seed names

    func testNoAppsGetsTheGenericName() {
        XCTAssertEqual(seed([]), "Folder")
    }

    func testBlankNamesAreIgnored() {
        XCTAssertEqual(seed(["", "   ", "\n\t"]), "Folder")
        XCTAssertEqual(seed(["", "Safari", "  "]), "Safari")
        XCTAssertEqual(seed(["Mail", "", "Notes"]), "Mail + Notes")
    }

    func testSingleAppUsesItsOwnName() {
        XCTAssertEqual(seed(["Safari"]), "Safari")
    }

    func testWhitespaceInsideNamesIsCollapsed() {
        XCTAssertEqual(seed(["  Visual   Studio \n Code  "]), "Visual Studio Code")
        XCTAssertEqual(seed(["A\u{00A0}B"]), "A B", "no-break space is whitespace")
    }

    func testTwoAppsAreJoinedWithPlus() {
        XCTAssertEqual(seed(["Mail", "Notes"]), "Mail + Notes")
    }

    func testThreeOrMoreAppsSummarizeTheRest() {
        XCTAssertEqual(seed(["Mail", "Notes", "Pages"]), "Mail + 2")
        XCTAssertEqual(seed(["Mail", "Notes", "Pages", "Keynote", "Numbers"]), "Mail + 4")
        XCTAssertEqual(seed((0..<100).map { "App\($0)" }), "App0 + 99")
    }

    func testJoinedNameIsCappedAtTwentyEightCharacters() {
        let name = seed([String(repeating: "A", count: 40), "B"])
        XCTAssertEqual(name.count, 28)
        XCTAssertEqual(name, String(repeating: "A", count: 28))
    }

    func testCapTrimsTrailingSpaceLeftByTheCut() {
        // "AAAAAAAAAAAAAAAAAAAAAAAAAAA + B": the 28-character prefix ends in a space.
        let name = seed([String(repeating: "A", count: 27), "B"])
        XCTAssertEqual(name, String(repeating: "A", count: 27))
    }

    func testCapCountsCharactersNotBytes() {
        let name = seed([String(repeating: "界", count: 40), "x"])
        XCTAssertEqual(name.count, 28)
        let emoji = seed([String(repeating: "👨‍👩‍👧", count: 40), "x"])
        XCTAssertEqual(emoji.count, 28, "ZWJ family sequences are single characters")
    }

    func testSurroundingQuotesAndPunctuationAreStrippedInJoinedNames() {
        XCTAssertEqual(seed(["\"Quoted\"", "'Single'"]), "Quoted\" + 'Single")
    }

    func testLeadingAndTrailingPunctuationIsStrippedInJoinedNames() {
        XCTAssertEqual(seed(["...Wow!!!", "Next?"]), "Wow!!! + Next")
    }

    func testNameThatIsOnlyPunctuationFallsBack() {
        XCTAssertEqual(seed(["...", "---"]), "+")
        XCTAssertEqual(seed(["!!!"]), "!!!", "single names are used as given")
    }

    func testNewlinesInNamesDoNotSurvive() {
        let name = seed(["Line\nBreak", "Other\r\nApp"])
        XCTAssertFalse(name.contains("\n"))
        XCTAssertFalse(name.contains("\r"))
    }

    func testRightToLeftAndCombiningNamesAreHandled() {
        XCTAssertFalse(seed(["مرحبا", "שלום"]).isEmpty)
        XCTAssertEqual(seed(["e\u{0301}"]), "e\u{0301}")
    }

    func testSingleVeryLongNameIsReturnedWhole() {
        // Current behavior: only the joined forms are capped. A lone app's
        // name passes through untouched, whatever its length.
        let long = String(repeating: "x", count: 5_000)
        XCTAssertEqual(seed([long]).count, 5_000)
    }

    func testSeedIsDeterministic() {
        let input = ["Mail", "Notes", "Pages"]
        XCTAssertEqual(seed(input), seed(input))
    }

    func testHugeAppListIsFast() {
        let names = (0..<50_000).map { "Application number \($0)" }
        let start = Date()
        XCTAssertEqual(seed(names), "Application number 0 + 49999")
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    // MARK: Sanitizer

    func testSanitizeCollapsesWhitespaceAndTrims() {
        XCTAssertEqual(_appFolderSanitize("  a   b  ", fallback: "F"), "a b")
        XCTAssertEqual(_appFolderSanitize("a\nb", fallback: "F"), "a b")
    }

    func testSanitizeStripsTypographicQuotes() {
        XCTAssertEqual(_appFolderSanitize("“Hello”", fallback: "F"), "Hello")
        XCTAssertEqual(_appFolderSanitize("‘Hello’.", fallback: "F"), "Hello")
    }

    func testSanitizeFallsBackWhenNothingRemains() {
        for value in ["", "   ", "\"\"", "...", "-", "“”", " . : , "] {
            XCTAssertEqual(_appFolderSanitize(value, fallback: "Fallback"), "Fallback", value.debugDescription)
        }
    }

    func testSanitizeKeepsInteriorPunctuation() {
        XCTAssertEqual(_appFolderSanitize("Mac - Tools", fallback: "F"), "Mac - Tools")
        XCTAssertEqual(_appFolderSanitize("A, B", fallback: "F"), "A, B")
    }

    func testSanitizeLimitIsTwentyEight() {
        XCTAssertEqual(_appFolderSanitize(String(repeating: "z", count: 29), fallback: "F").count, 28)
        XCTAssertEqual(_appFolderSanitize(String(repeating: "z", count: 28), fallback: "F").count, 28)
        XCTAssertEqual(_appFolderSanitize(String(repeating: "z", count: 27), fallback: "F").count, 27)
    }

    func testSanitizeOfHugeInputIsBounded() {
        let result = _appFolderSanitize(String(repeating: "word ", count: 200_000), fallback: "F")
        XCTAssertLessThanOrEqual(result.count, 28)
    }

    func testNormalizeJoinsOnSingleSpaces() {
        XCTAssertEqual(_appFolderNormalizeName("a \t\n b"), "a b")
        XCTAssertEqual(_appFolderNormalizeName(""), "")
        XCTAssertEqual(_appFolderNormalizeName(" \n "), "")
    }

    // MARK: Service wrapper

    func testServiceSeedMatchesTheFreeFunction() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("macOS 26 only") }
        let tiles = apps(["Mail", "Notes", "Pages"])
        XCTAssertEqual(AppFolderNamingService.shared.seedName(for: tiles), appFolderSeedName(for: tiles))
    }

    func testSuggestionForFewerThanTwoAppsNeverAsksTheModel() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("macOS 26 only") }
        let service = AppFolderNamingService.shared
        let none = await service.suggestInitialName(for: [])
        XCTAssertEqual(none, "Folder")
        let one = await service.suggestInitialName(for: apps(["Safari"]))
        XCTAssertEqual(one, "Safari")
        let blanks = await service.suggestInitialName(for: apps(["Safari", "  ", ""]))
        XCTAssertEqual(blanks, "Safari", "blank names do not count toward the two-app threshold")
    }
}

// MARK: - Folder access

final class FolderAccessServiceTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    @discardableResult
    private func touch(_ name: String, in directory: URL, bytes: Int = 1, modified: Date? = nil, created: Date? = nil) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        var attributes: [FileAttributeKey: Any] = [:]
        if let modified { attributes[.modificationDate] = modified }
        if let created { attributes[.creationDate] = created }
        if !attributes.isEmpty {
            try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
        }
        return url
    }

    private func names(_ urls: [URL]) -> [String] { urls.map(\.lastPathComponent) }

    // MARK: Reading folders

    func testContentsListsVisibleItemsNewestFirst() throws {
        let dir = try makeScratchDirectory("folder")
        try touch("old.txt", in: dir, modified: Date(timeIntervalSince1970: 1_000))
        try touch("new.txt", in: dir, modified: Date(timeIntervalSince1970: 3_000))
        try touch("mid.txt", in: dir, modified: Date(timeIntervalSince1970: 2_000))
        let service = FolderAccessService()
        XCTAssertEqual(names(service.contents(of: dir)), ["new.txt", "mid.txt", "old.txt"])
    }

    func testHiddenItemsAreSkipped() throws {
        let dir = try makeScratchDirectory("folder")
        try touch(".hidden", in: dir)
        try touch(".DS_Store", in: dir)
        try touch("visible.txt", in: dir)
        XCTAssertEqual(names(FolderAccessService().contents(of: dir)), ["visible.txt"])
    }

    func testEmptyFolderIsLoadedNotUnreadable() throws {
        let dir = try makeScratchDirectory("folder")
        XCTAssertEqual(FolderAccessService().snapshot(of: dir), .loaded([]))
    }

    func testMissingFolderIsUnreadable() throws {
        let dir = try makeScratchDirectory("folder").appendingPathComponent("absent")
        XCTAssertEqual(FolderAccessService().snapshot(of: dir), .unreadable)
        XCTAssertTrue(FolderAccessService().contents(of: dir).isEmpty)
    }

    func testRegularFileIsNotAFolder() throws {
        let dir = try makeScratchDirectory("folder")
        let file = try touch("plain.txt", in: dir)
        XCTAssertEqual(FolderAccessService().snapshot(of: file), .unreadable)
    }

    func testPermissionDeniedFolderIsUnreadable() throws {
        let dir = try makeScratchDirectory("folder")
        let locked = dir.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try touch("inside.txt", in: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: locked.path), "running with privileges that ignore modes")
        XCTAssertEqual(FolderAccessService().snapshot(of: locked), .unreadable)
    }

    func testUnicodeAndAwkwardNamesAreListed() throws {
        let dir = try makeScratchDirectory("folder")
        let awkward = ["日本語.txt", "café ☕️.md", "-leading-dash", "with space.txt", "new\nline.txt", "emoji🙂🙃.png", "a#b%c?.txt"]
        for name in awkward { try touch(name, in: dir) }
        XCTAssertEqual(Set(names(FolderAccessService().contents(of: dir))), Set(awkward))
    }

    func testMaximumLengthNameIsListed() throws {
        let dir = try makeScratchDirectory("folder")
        let name = String(repeating: "n", count: 255)
        try touch(name, in: dir)
        XCTAssertEqual(names(FolderAccessService().contents(of: dir)), [name])
    }

    func testDotDotInTheFolderPathIsStandardized() throws {
        let dir = try makeScratchDirectory("folder")
        let sub = dir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try touch("top.txt", in: dir)
        let viaDots = URL(fileURLWithPath: sub.path + "/../")
        XCTAssertEqual(Set(names(FolderAccessService().contents(of: viaDots))), ["sub", "top.txt"])
    }

    func testSymlinkedFolderIsFollowed() throws {
        expectKnownBug("FileManager.contentsOfDirectory(at:) returns nil for a URL that is itself a symlink to a directory, so a folder tile whose path is a symlink (for example /tmp, or a folder redirected to iCloud) reports .unreadable and renders empty. Resolving symlinks before listing would fix it.")
        let dir = try makeScratchDirectory("folder")
        let real = dir.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try touch("inside.txt", in: real)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertEqual(names(FolderAccessService().contents(of: link)), ["inside.txt"])
    }

    func testSymlinkLoopIsUnreadableNotAHang() throws {
        let dir = try makeScratchDirectory("folder")
        let a = dir.appendingPathComponent("a")
        let b = dir.appendingPathComponent("b")
        try FileManager.default.createSymbolicLink(at: a, withDestinationURL: b)
        try FileManager.default.createSymbolicLink(at: b, withDestinationURL: a)
        XCTAssertEqual(FolderAccessService().snapshot(of: a), .unreadable)
    }

    func testDanglingSymlinkFolderIsUnreadable() throws {
        let dir = try makeScratchDirectory("folder")
        let link = dir.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir.appendingPathComponent("gone"))
        XCTAssertEqual(FolderAccessService().snapshot(of: link), .unreadable)
    }

    func testDirectoryWithManyEntriesIsHandled() throws {
        let dir = try makeScratchDirectory("folder")
        for index in 0..<1_500 { try touch("f\(index).txt", in: dir) }
        let start = Date()
        XCTAssertEqual(FolderAccessService().contents(of: dir).count, 1_500)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    // MARK: Caching

    func testResultIsCachedUntilInvalidated() throws {
        let dir = try makeScratchDirectory("cache")
        try touch("one.txt", in: dir)
        let service = FolderAccessService()
        XCTAssertEqual(service.contents(of: dir).count, 1)
        try touch("two.txt", in: dir)
        XCTAssertEqual(service.contents(of: dir).count, 1, "served from the 15 second cache")
        service.invalidateCache()
        XCTAssertEqual(service.contents(of: dir).count, 2)
    }

    func testCachesAreNotSharedBetweenInstances() throws {
        let dir = try makeScratchDirectory("cache")
        try touch("one.txt", in: dir)
        let first = FolderAccessService()
        XCTAssertEqual(first.contents(of: dir).count, 1)
        try touch("two.txt", in: dir)
        XCTAssertEqual(FolderAccessService().contents(of: dir).count, 2)
    }

    func testUnreadableFoldersAreNotCached() throws {
        let dir = try makeScratchDirectory("cache")
        let later = dir.appendingPathComponent("later", isDirectory: true)
        let service = FolderAccessService()
        XCTAssertEqual(service.snapshot(of: later), .unreadable)
        try FileManager.default.createDirectory(at: later, withIntermediateDirectories: true)
        XCTAssertEqual(service.snapshot(of: later), .loaded([]))
    }

    // MARK: Sorting

    func testNameSortIsNumericAware() throws {
        let dir = try makeScratchDirectory("sort")
        let urls = try ["file10.txt", "file2.txt", "File1.txt", "file20.txt"].map { try touch($0, in: dir) }
        let sorted = FolderAccessService().sortedItems(in: urls, sortMode: .name)
        XCTAssertEqual(names(sorted), ["File1.txt", "file2.txt", "file10.txt", "file20.txt"])
    }

    func testDateModifiedSortIsNewestFirstWithNameTiebreak() throws {
        let dir = try makeScratchDirectory("sort")
        let stamp = Date(timeIntervalSince1970: 5_000)
        let urls = [
            try touch("b.txt", in: dir, modified: stamp),
            try touch("a.txt", in: dir, modified: stamp),
            try touch("c.txt", in: dir, modified: Date(timeIntervalSince1970: 9_000)),
        ]
        XCTAssertEqual(names(FolderAccessService().sortedItems(in: urls, sortMode: .dateModified)), ["c.txt", "a.txt", "b.txt"])
    }

    func testDateCreatedSortIsNewestFirst() throws {
        let dir = try makeScratchDirectory("sort")
        let urls = [
            try touch("older.txt", in: dir, created: Date(timeIntervalSince1970: 1_000)),
            try touch("newer.txt", in: dir, created: Date(timeIntervalSince1970: 2_000)),
        ]
        XCTAssertEqual(names(FolderAccessService().sortedItems(in: urls, sortMode: .dateCreated)), ["newer.txt", "older.txt"])
    }

    func testSizeSortIsLargestFirst() throws {
        let dir = try makeScratchDirectory("sort")
        let urls = [
            try touch("small.bin", in: dir, bytes: 10),
            try touch("large.bin", in: dir, bytes: 100_000),
            try touch("medium.bin", in: dir, bytes: 5_000),
        ]
        XCTAssertEqual(names(FolderAccessService().sortedItems(in: urls, sortMode: .size)), ["large.bin", "medium.bin", "small.bin"])
    }

    func testKindSortGroupsByType() throws {
        let dir = try makeScratchDirectory("sort")
        let urls = [
            try touch("b.txt", in: dir), try touch("a.png", in: dir), try touch("c.txt", in: dir), try touch("d.png", in: dir),
        ]
        let sorted = names(FolderAccessService().sortedItems(in: urls, sortMode: .kind))
        // Items of one kind are adjacent, and names ascend within a kind.
        XCTAssertEqual(Set(sorted.prefix(2).map { ($0 as NSString).pathExtension }).count, 1)
        XCTAssertEqual(Set(sorted.suffix(2).map { ($0 as NSString).pathExtension }).count, 1)
    }

    func testDateAddedSortFallsBackToNameWhenTimesTie() throws {
        let dir = try makeScratchDirectory("sort")
        let urls = [try touch("b.txt", in: dir), try touch("a.txt", in: dir)]
        let sorted = names(FolderAccessService().sortedItems(in: urls, sortMode: .dateAdded))
        XCTAssertEqual(Set(sorted), ["a.txt", "b.txt"])
    }

    func testEveryModeIsAStableTotalOrderOnMissingFiles() {
        // Files that cannot be stat'ed get sentinel values; ordering must
        // still be total (path breaks every tie) and never crash.
        let urls = ["z", "a", "m", "a2", "10", "9"].map { URL(fileURLWithPath: "/nonexistent/\($0)") }
        let service = FolderAccessService()
        for mode in FolderTileSortMode.allCases {
            let once = service.sortedItems(in: urls, sortMode: mode)
            let twice = service.sortedItems(in: once.reversed(), sortMode: mode)
            XCTAssertEqual(once, twice, "\(mode)")
            XCTAssertEqual(Set(once), Set(urls))
        }
    }

    func testSortOfEmptyAndSingleInputs() {
        let service = FolderAccessService()
        for mode in FolderTileSortMode.allCases {
            XCTAssertTrue(service.sortedItems(in: [], sortMode: mode).isEmpty)
            let one = URL(fileURLWithPath: "/x/only")
            XCTAssertEqual(service.sortedItems(in: [one], sortMode: mode), [one])
        }
    }

    func testSortingUnreadableSnapshotYieldsNothing() {
        let service = FolderAccessService()
        XCTAssertTrue(service.sortedItems(in: .unreadable, sortMode: .name).isEmpty)
        let url = URL(fileURLWithPath: "/x/y")
        XCTAssertEqual(service.sortedItems(in: .loaded([url]), sortMode: .name), [url])
    }

    func testSortedContentsOfAFolder() throws {
        let dir = try makeScratchDirectory("sort")
        try touch("b.txt", in: dir)
        try touch("a.txt", in: dir)
        XCTAssertEqual(names(FolderAccessService().sortedContents(of: dir, sortMode: .name)), ["a.txt", "b.txt"])
    }

    func testRecentContentsHonorsTheLimit() throws {
        let dir = try makeScratchDirectory("recent")
        for index in 0..<6 { try touch("f\(index).txt", in: dir, modified: Date(timeIntervalSince1970: Double(index) * 100)) }
        let service = FolderAccessService()
        XCTAssertEqual(service.recentContents(of: dir, sortMode: .dateModified).count, 3, "default limit")
        XCTAssertEqual(names(service.recentContents(of: dir, sortMode: .dateModified, limit: 2)), ["f5.txt", "f4.txt"])
        XCTAssertTrue(service.recentContents(of: dir, sortMode: .name, limit: 0).isEmpty)
        XCTAssertEqual(service.recentContents(of: dir, sortMode: .name, limit: 1_000).count, 6)
    }

    func testSortingAThousandURLsIsFast() throws {
        let urls = (0..<1_000).map { URL(fileURLWithPath: "/nonexistent/item\($0)") }
        let start = Date()
        _ = FolderAccessService().sortedItems(in: urls, sortMode: .name)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    // MARK: Watching

    private func waitForChange(_ service: FolderAccessService, timeout: TimeInterval = 3, trigger: () throws -> Void) rethrows -> Bool {
        let changed = expectation(description: "folder change")
        changed.assertForOverFulfill = false
        service.$changeToken
            .dropFirst()
            .sink { _ in changed.fulfill() }
            .store(in: &cancellables)
        try trigger()
        return XCTWaiter().wait(for: [changed], timeout: timeout) == .completed
    }

    func testWatcherReportsChangesAndDropsTheCache() throws {
        let dir = try makeScratchDirectory("watch")
        try touch("one.txt", in: dir)
        let service = FolderAccessService()
        XCTAssertEqual(service.contents(of: dir).count, 1)
        service.beginWatching(dir, ownerID: "tile-1")
        defer { service.endWatching(dir, ownerID: "tile-1") }

        let sawChange = try waitForChange(service) { try touch("two.txt", in: dir) }
        XCTAssertTrue(sawChange)
        XCTAssertEqual(service.contents(of: dir).count, 2, "the event invalidated the 15 second cache")
    }

    func testWatchingAMissingFolderIsHarmless() throws {
        let dir = try makeScratchDirectory("watch").appendingPathComponent("absent")
        let service = FolderAccessService()
        service.beginWatching(dir, ownerID: "x")
        service.endWatching(dir, ownerID: "x")
    }

    func testEndingAnUnknownWatchIsHarmless() throws {
        let dir = try makeScratchDirectory("watch")
        let service = FolderAccessService()
        service.endWatching(dir, ownerID: "never-began")
        service.beginWatching(dir, ownerID: "a")
        service.endWatching(dir, ownerID: "b")
        service.endWatching(dir, ownerID: "a")
        service.endWatching(dir, ownerID: "a")
    }

    func testWatchSurvivesOneOwnerLeaving() throws {
        let dir = try makeScratchDirectory("watch")
        let service = FolderAccessService()
        service.beginWatching(dir, ownerID: "a")
        service.beginWatching(dir, ownerID: "b")
        service.endWatching(dir, ownerID: "a")
        defer { service.endWatching(dir, ownerID: "b") }
        XCTAssertTrue(try waitForChange(service) { try touch("x.txt", in: dir) })
    }

    func testWatchStopsWhenTheLastOwnerLeaves() throws {
        let dir = try makeScratchDirectory("watch")
        let service = FolderAccessService()
        service.beginWatching(dir, ownerID: "a")
        service.endWatching(dir, ownerID: "a")
        XCTAssertFalse(try waitForChange(service, timeout: 0.2) { try touch("x.txt", in: dir) })
    }

    func testWatchPathsAreStandardizedForOwnership() throws {
        let dir = try makeScratchDirectory("watch")
        let service = FolderAccessService()
        let sub = dir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        service.beginWatching(dir, ownerID: "a")
        service.endWatching(URL(fileURLWithPath: sub.path + "/.."), ownerID: "a")
        XCTAssertFalse(try waitForChange(service, timeout: 0.2) { try touch("x.txt", in: dir) })
    }
}

// MARK: - Recents

@MainActor
final class RecentFilesServiceTests: XCTestCase {

    func testURLAttributeIsPreferred() {
        let url = URL(fileURLWithPath: "/tmp/a.txt")
        XCTAssertEqual(RecentFilesService.resolveURL(urlValue: url, pathValue: "/tmp/b.txt"), url)
    }

    func testNSURLIsAccepted() {
        let nsurl = NSURL(fileURLWithPath: "/tmp/a.txt")
        XCTAssertEqual(RecentFilesService.resolveURL(urlValue: nsurl, pathValue: nil), nsurl as URL)
    }

    func testPathStringIsTheFallback() {
        XCTAssertEqual(
            RecentFilesService.resolveURL(urlValue: nil, pathValue: "/tmp/with space/ü.txt"),
            URL(fileURLWithPath: "/tmp/with space/ü.txt")
        )
    }

    func testWrongTypedURLAttributeFallsBackToPath() {
        XCTAssertEqual(
            RecentFilesService.resolveURL(urlValue: 42, pathValue: "/tmp/a.txt"),
            URL(fileURLWithPath: "/tmp/a.txt")
        )
        XCTAssertEqual(
            RecentFilesService.resolveURL(urlValue: "/tmp/a.txt", pathValue: "/tmp/b.txt"),
            URL(fileURLWithPath: "/tmp/b.txt"),
            "a String in the URL slot is not trusted as a URL"
        )
    }

    func testNothingUsableYieldsNil() {
        XCTAssertNil(RecentFilesService.resolveURL(urlValue: nil, pathValue: nil))
        XCTAssertNil(RecentFilesService.resolveURL(urlValue: nil, pathValue: 5))
        XCTAssertNil(RecentFilesService.resolveURL(urlValue: [1], pathValue: ["x"]))
    }

    func testEmptyPathIsNotTurnedIntoTheWorkingDirectory() {
        expectKnownBug("An empty path attribute becomes URL(fileURLWithPath: \"\"), which resolves to the process working directory, so a malformed Spotlight item would show the current directory in Recents. Low severity.")
        XCTAssertNil(RecentFilesService.resolveURL(urlValue: nil, pathValue: ""))
    }

    func testRelativeAndTraversalPathsAreKeptAsGiven() {
        let url = RecentFilesService.resolveURL(urlValue: nil, pathValue: "/Users/x/../y/file.txt")
        XCTAssertEqual(url?.lastPathComponent, "file.txt")
        XCTAssertTrue(url?.isFileURL == true)
    }

    func testHugeAndOddPathsDoNotTrap() {
        _ = RecentFilesService.resolveURL(urlValue: nil, pathValue: "/" + String(repeating: "a/", count: 20_000))
        _ = RecentFilesService.resolveURL(urlValue: nil, pathValue: "/tmp/\u{0}nul")
        _ = RecentFilesService.resolveURL(urlValue: nil, pathValue: "\n")
    }

    func testResultLimitIsFifty() {
        XCTAssertEqual(RecentFilesService.maxResults, 50)
    }

    func testPredicateRestrictsToUsedContentOfKnownKinds() {
        let format = RecentFilesService.recentsPredicate().predicateFormat
        XCTAssertTrue(format.contains("kMDItemLastUsedDate"))
        XCTAssertTrue(format.contains("public.content"))
        XCTAssertTrue(format.contains("public.archive"))
        XCTAssertTrue(format.contains("com.microsoft."))
    }

    func testPredicateIsStaticAndRepeatable() {
        XCTAssertEqual(
            RecentFilesService.recentsPredicate().predicateFormat,
            RecentFilesService.recentsPredicate().predicateFormat
        )
    }
}
