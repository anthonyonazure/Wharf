import CoreAudio
import Darwin
import XCTest
@testable import Wharf

// MARK: - Audio

final class AudioControlPureTests: XCTestCase {

    func testVolumeClampOrdinaryValues() {
        let cases: [(Float, Float)] = [(0, 0), (1, 1), (0.5, 0.5), (0.001, 0.001), (0.999, 0.999)]
        for (input, expected) in cases {
            XCTAssertEqual(AudioControlService.clampedVolume(input), expected, accuracy: 0.0001)
        }
    }

    func testVolumeClampOutOfRange() {
        let cases: [(Float, Float)] = [
            (-0.0001, 0), (-1, 0), (1.0001, 1), (2, 1), (1e30, 1), (-1e30, 0),
            (.infinity, 1), (-.infinity, 0), (.greatestFiniteMagnitude, 1), (-.greatestFiniteMagnitude, 0),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(AudioControlService.clampedVolume(input), expected, "\(input)")
        }
    }

    func testNaNVolumeIsNotWrittenToTheDevice() {
        expectKnownBug("clampedVolume(.nan) returns NaN, because min/max propagate the first operand when the comparison is false. setVolume would then hand NaN to CoreAudio. Unreachable from the slider, so low severity.")
        XCTAssertFalse(AudioControlService.clampedVolume(.nan).isNaN)
    }

    func testClampIsIdempotent() {
        for value in stride(from: Float(-2), through: 3, by: 0.37) {
            let once = AudioControlService.clampedVolume(value)
            XCTAssertEqual(AudioControlService.clampedVolume(once), once)
            XCTAssertTrue((0...1).contains(once))
        }
    }

    func testDeviceStructEquality() {
        XCTAssertEqual(AudioOutputDevice(id: 5, name: "A"), AudioOutputDevice(id: 5, name: "A"))
        XCTAssertNotEqual(AudioOutputDevice(id: 5, name: "A"), AudioOutputDevice(id: 6, name: "A"))
        XCTAssertEqual(AudioOutputDevice(id: 5, name: "A").id, 5)
    }

    // The read-only CoreAudio queries below talk to the real system but never
    // write. Assertions are conditional so a machine without audio hardware
    // (a CI runner) still passes.

    func testReadsOnTheNullDeviceAreSafe() {
        XCTAssertNil(AudioControlService.readVolume(0))
        XCTAssertFalse(AudioControlService.readMuted(0))
    }

    func testReadsOnAnInvalidDeviceAreSafe() {
        let bogus = AudioDeviceID(0xFFFF_FFF0)
        XCTAssertNil(AudioControlService.readVolume(bogus))
        XCTAssertFalse(AudioControlService.readMuted(bogus))
    }

    func testDefaultDeviceVolumeIsAFraction() {
        let device = AudioControlService.readDefaultOutputDevice()
        guard device != 0, let volume = AudioControlService.readVolume(device) else { return }
        XCTAssertTrue((0...1).contains(volume), "volume \(volume)")
    }

    func testOutputDeviceListIsWellFormed() {
        let devices = AudioControlService.readOutputDevices()
        XCTAssertEqual(devices.count, Set(devices.map(\.id)).count, "ids are unique")
        for device in devices {
            XCTAssertNotEqual(device.id, 0)
            XCTAssertFalse(device.name.isEmpty)
        }
    }
}

// MARK: - Media

final class MediaPlaybackPureTests: XCTestCase {

    // MARK: State helpers

    private func state(
        _ bundle: String = "com.example.player",
        name: String = "Player",
        title: String = "Song",
        artist: String = "Artist",
        album: String = "Album",
        currentTime: TimeInterval = 10,
        duration: TimeInterval = 100,
        playing: Bool = false,
        available: Bool = true,
        artwork: Data? = nil,
        updated: Date = Date(timeIntervalSince1970: 1_000)
    ) -> MediaPlaybackState {
        MediaPlaybackState(
            bundleIdentifier: bundle, displayName: name, title: title, artist: artist, album: album,
            currentTime: currentTime, duration: duration, isPlaying: playing, isAvailable: available,
            supportsFavorite: false, isFavorite: false, artworkData: artwork, lastUpdated: updated
        )
    }

    // MARK: Presentability

    func testHasContentNeedsTitleArtistOrArtwork() {
        XCTAssertTrue(state(title: "T", artist: "").hasContent)
        XCTAssertTrue(state(title: "", artist: "A").hasContent)
        XCTAssertTrue(state(title: "", artist: "", artwork: Data([1])).hasContent)
        XCTAssertFalse(state(title: "", artist: "", album: "Only album").hasContent)
        XCTAssertFalse(state(title: "", artist: "", artwork: nil).hasContent)
    }

    func testPresentableRequiresAvailabilityAndContent() {
        XCTAssertTrue(state().isPresentable)
        XCTAssertFalse(state(available: false).isPresentable)
        XCTAssertFalse(state(title: "", artist: "").isPresentable)
    }

    // MARK: Estimated position

    func testPausedPositionIsTheReportedPosition() {
        XCTAssertEqual(state(currentTime: 42, duration: 100, playing: false).estimatedCurrentTime, 42)
    }

    func testPausedPositionIsClampedIntoTheTrack() {
        XCTAssertEqual(state(currentTime: 500, duration: 100).estimatedCurrentTime, 100)
        XCTAssertEqual(state(currentTime: -30, duration: 100).estimatedCurrentTime, 0)
    }

    func testPlayingPositionAdvancesWithWallClock() {
        let started = Date().addingTimeInterval(-5)
        let estimate = state(currentTime: 10, duration: 100, playing: true, updated: started).estimatedCurrentTime
        XCTAssertEqual(estimate, 15, accuracy: 0.5)
    }

    func testPlayingPositionNeverExceedsDuration() {
        let longAgo = Date().addingTimeInterval(-10_000)
        XCTAssertEqual(state(currentTime: 90, duration: 100, playing: true, updated: longAgo).estimatedCurrentTime, 100)
    }

    func testFutureTimestampDoesNotRewindBelowZero() {
        let future = Date().addingTimeInterval(10_000)
        let estimate = state(currentTime: 5, duration: 100, playing: true, updated: future).estimatedCurrentTime
        XCTAssertGreaterThanOrEqual(estimate, 0)
        XCTAssertLessThanOrEqual(estimate, 100)
    }

    func testZeroDurationPinsPositionToZero() {
        XCTAssertEqual(state(currentTime: 30, duration: 0, playing: true).estimatedCurrentTime, 0)
        XCTAssertEqual(state(currentTime: 30, duration: 0, playing: false).estimatedCurrentTime, 0)
    }

    func testExtremeValuesDoNotTrap() {
        for time in [Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude, 1e300, 0] {
            for duration in [Double.greatestFiniteMagnitude, 1, 0] {
                _ = state(currentTime: time, duration: duration, playing: true).estimatedCurrentTime
                _ = state(currentTime: time, duration: duration, playing: false).estimatedCurrentTime
            }
        }
    }

    // MARK: Service bookkeeping

    private func makeService() -> MediaPlaybackService {
        MediaPlaybackService(connectsToMediaRemote: false)
    }

    func testEmptyServiceHasNoState() {
        let service = makeService()
        XCTAssertNil(service.currentState)
        XCTAssertTrue(service.availableMediaApps().isEmpty)
        XCTAssertNil(service.state(for: "com.example.player"))
    }

    func testSupportsWidgetAcceptsAnyNonEmptyIdentifier() {
        let service = makeService()
        XCTAssertTrue(service.supportsWidget(bundleIdentifier: "com.apple.Music"))
        XCTAssertTrue(service.supportsWidget(bundleIdentifier: MediaPlaybackService.genericNowPlayingOwnerBundleIdentifier))
        XCTAssertFalse(service.supportsWidget(bundleIdentifier: ""))
    }

    func testStateIsStoredPerBundleIdentifier() {
        let service = makeService()
        service.apply(state("a", title: "One"))
        service.apply(state("b", title: "Two"))
        XCTAssertEqual(service.state(for: "a")?.title, "One")
        XCTAssertEqual(service.state(for: "b")?.title, "Two")
        XCTAssertNil(service.state(for: "c"))
    }

    func testNewerUpdateReplacesOlderForTheSameApp() {
        let service = makeService()
        service.apply(state("a", title: "Old"))
        service.apply(state("a", title: "New"))
        XCTAssertEqual(service.state(for: "a")?.title, "New")
        XCTAssertEqual(service.statesByBundleIdentifier.count, 1)
    }

    func testCurrentStateIsTheMostRecentlyUpdatedWithContent() {
        let service = makeService()
        service.apply(state("old", updated: Date(timeIntervalSince1970: 100)))
        service.apply(state("new", updated: Date(timeIntervalSince1970: 300)))
        service.apply(state("empty", title: "", artist: "", updated: Date(timeIntervalSince1970: 900)))
        XCTAssertEqual(service.currentState?.bundleIdentifier, "new")
    }

    func testGenericOwnerResolvesToTheCurrentApp() {
        let service = makeService()
        let generic = MediaPlaybackService.genericNowPlayingOwnerBundleIdentifier
        XCTAssertNil(service.resolvedBundleIdentifier(for: generic), "nothing playing")
        service.apply(state("com.spotify.client", title: "Track"))
        XCTAssertEqual(service.resolvedBundleIdentifier(for: generic), "com.spotify.client")
        XCTAssertEqual(service.state(for: generic)?.title, "Track")
    }

    func testResolvedIdentifierRejectsEmpty() {
        let service = makeService()
        XCTAssertNil(service.resolvedBundleIdentifier(for: ""))
        XCTAssertEqual(service.resolvedBundleIdentifier(for: "com.example"), "com.example")
    }

    func testAvailableAppsAreSortedCaseInsensitivelyByName() {
        let service = makeService()
        service.apply(state("c", name: "zebra"))
        service.apply(state("a", name: "Apple Music"))
        service.apply(state("b", name: "banjo"))
        XCTAssertEqual(service.availableMediaApps().map(\.displayName), ["Apple Music", "banjo", "zebra"])
    }

    func testAvailableAppsBreakNameTiesByIdentifier() {
        let service = makeService()
        service.apply(state("com.z", name: "Same"))
        service.apply(state("com.a", name: "Same"))
        XCTAssertEqual(service.availableMediaApps().map(\.bundleIdentifier), ["com.a", "com.z"])
    }

    func testAvailableAppsExcludeTheGenericPlaceholder() {
        let service = makeService()
        service.apply(state(MediaPlaybackService.genericNowPlayingOwnerBundleIdentifier, name: "Generic"))
        service.apply(state("real", name: "Real"))
        XCTAssertEqual(service.availableMediaApps().map(\.bundleIdentifier), ["real"])
    }

    func testClearingStateBlanksEveryApp() {
        let service = makeService()
        service.apply(state("a", playing: true, artwork: Data([1, 2, 3])))
        service.apply(nil)
        let cleared = service.state(for: "a")
        XCTAssertEqual(cleared?.title, "")
        XCTAssertEqual(cleared?.artist, "")
        XCTAssertEqual(cleared?.duration, 0)
        XCTAssertNil(cleared?.artworkData)
        XCTAssertEqual(cleared?.isPlaying, false)
        XCTAssertEqual(cleared?.isAvailable, false)
        XCTAssertNil(service.currentState)
    }

    func testClearingKeepsAppsInThePicker() {
        let service = makeService()
        service.apply(state("a", name: "Player"))
        service.apply(nil)
        XCTAssertEqual(service.availableMediaApps().map(\.bundleIdentifier), ["a"])
    }

    func testTrackKeyAndLyricsSupport() {
        let service = makeService()
        service.apply(state("a", title: "T", artist: "A", album: "Al"))
        XCTAssertEqual(service.currentTrackKey(for: "a"), "a|T|A|Al")
        XCTAssertTrue(service.supportsLyrics(for: "a"))
    }

    func testTrackKeyAndLyricsAreUnavailableWithoutContent() {
        let service = makeService()
        XCTAssertNil(service.currentTrackKey(for: "missing"))
        XCTAssertFalse(service.supportsLyrics(for: "missing"))
        service.apply(state("a", title: "T", artist: ""))
        XCTAssertFalse(service.supportsLyrics(for: "a"), "lyrics lookup needs both title and artist")
        XCTAssertNotNil(service.currentTrackKey(for: "a"))
    }

    func testTrackKeysDifferByAnyField() {
        let service = makeService()
        var keys = Set<String>()
        for variant in [("T", "A", "Al"), ("T2", "A", "Al"), ("T", "A2", "Al"), ("T", "A", "Al2")] {
            service.apply(state("a", title: variant.0, artist: variant.1, album: variant.2))
            keys.insert(service.currentTrackKey(for: "a") ?? "")
        }
        XCTAssertEqual(keys.count, 4)
    }

    func testLyricsStateIsAbsentUntilRequested() {
        let service = makeService()
        service.apply(state("a"))
        XCTAssertNil(service.lyricsState(for: "a"))
    }

    func testRequestingLyricsWithoutTitleOrArtistDoesNothing() {
        let service = makeService()
        service.apply(state("a", title: "", artist: "Only Artist"))
        service.requestLyrics(for: "a")
        service.requestLyrics(for: "ghost")
        XCTAssertTrue(service.lyricsByTrackKey.isEmpty)
    }

    func testCommandsWithoutPlayableStateAreNoOps() async {
        // With no content, every guard returns before a media key is sent.
        let service = makeService()
        await service.togglePlayPause(for: "ghost")
        await service.skipToNext(for: "ghost")
        await service.skipToPrevious(for: "ghost")
        await service.setFavorite(true, for: "ghost")
        XCTAssertTrue(service.statesByBundleIdentifier.isEmpty)
    }

    // MARK: Lyrics URL construction

    func testLyricsGetURLEncodesHostileText() throws {
        let url = try XCTUnwrap(MediaPlaybackService.lrclibGetURL(
            title: "A&B=C #1 ?x /y", artist: "Ünï \"q\" +plus", album: "Al bum", duration: 215
        ))
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.host, "lrclib.net")
        XCTAssertEqual(parts.path, "/api/get")
        let items = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["track_name"], "A&B=C #1 ?x /y")
        XCTAssertEqual(items["artist_name"], "Ünï \"q\" +plus")
        XCTAssertEqual(items["album_name"], "Al bum")
        XCTAssertEqual(items["duration"], "215")
        XCTAssertEqual(parts.queryItems?.count, 4, "no injected parameters")
    }

    func testLyricsGetURLOmitsEmptyAlbumAndNonPositiveDuration() throws {
        for duration in [0, -1, Int.min] {
            let url = try XCTUnwrap(MediaPlaybackService.lrclibGetURL(title: "T", artist: "A", album: "", duration: duration))
            let names = Set(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? [])
            XCTAssertEqual(names, ["track_name", "artist_name"], "duration \(duration)")
        }
    }

    func testLyricsGetURLWithHugeDuration() throws {
        let url = try XCTUnwrap(MediaPlaybackService.lrclibGetURL(title: "T", artist: "A", album: "", duration: Int.max))
        XCTAssertTrue(url.absoluteString.contains("duration=9223372036854775807"))
    }

    func testLyricsSearchURL() throws {
        let url = try XCTUnwrap(MediaPlaybackService.lrclibSearchURL(title: "T&x", artist: "A"))
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.path, "/api/search")
        XCTAssertEqual(parts.queryItems?.first { $0.name == "track_name" }?.value, "T&x")
    }

    func testLyricsURLsSurviveVeryLongInput() {
        let long = String(repeating: "界", count: 50_000)
        XCTAssertNotNil(MediaPlaybackService.lrclibGetURL(title: long, artist: long, album: long, duration: 1))
        XCTAssertNotNil(MediaPlaybackService.lrclibSearchURL(title: long, artist: long))
    }

    // MARK: LRC parsing

    private func parse(_ text: String) -> [SyncedLyricsLine] { MediaPlaybackService.parseLRC(text) }

    func testParsesBasicTimestamps() {
        let lines = parse("[00:12.34] Hello\n[01:05.00] World")
        XCTAssertEqual(lines, [
            SyncedLyricsLine(time: 12.34, text: "Hello"),
            SyncedLyricsLine(time: 65.0, text: "World"),
        ])
    }

    func testTimestampWithoutFractionAndShortFields() {
        XCTAssertEqual(parse("[1:2] x"), [SyncedLyricsLine(time: 62, text: "x")])
        XCTAssertEqual(parse("[00:00] start"), [SyncedLyricsLine(time: 0, text: "start")])
    }

    func testFractionDigitsAreDecimalPlaces() {
        XCTAssertEqual(parse("[00:01.5] a").first?.time ?? 0, 1.5, accuracy: 1e-9)
        XCTAssertEqual(parse("[00:01.05] a").first?.time ?? 0, 1.05, accuracy: 1e-9)
        XCTAssertEqual(parse("[00:01.500] a").first?.time ?? 0, 1.5, accuracy: 1e-9)
        XCTAssertEqual(parse("[00:01.123] a").first?.time ?? 0, 1.123, accuracy: 1e-9)
    }

    func testMultipleTimestampsOnOneLineRepeatTheText() {
        let lines = parse("[00:10.00][00:50.00] Chorus")
        XCTAssertEqual(lines.map(\.time), [10, 50])
        XCTAssertEqual(lines.map(\.text), ["Chorus", "Chorus"])
    }

    func testResultIsSortedByTime() {
        let lines = parse("[00:30.00] c\n[00:10.00] a\n[00:20.00] b")
        XCTAssertEqual(lines.map(\.text), ["a", "b", "c"])
    }

    func testMetadataAndGarbageLinesAreSkipped() {
        let lyrics = """
        [ar:Some Artist]
        [ti:Some Title]
        [by:someone]
        just a plain line
        [xx:yy] not a time
        [00:05.00] real
        """
        XCTAssertEqual(parse(lyrics).map(\.text), ["real"])
    }

    func testEmptyLyricTextIsKeptAsABlankLine() {
        XCTAssertEqual(parse("[00:05.00]"), [SyncedLyricsLine(time: 5, text: "")])
        XCTAssertEqual(parse("[00:05.00]    "), [SyncedLyricsLine(time: 5, text: "")])
    }

    func testEmptyAndTimestampFreeInputYieldNothing() {
        XCTAssertTrue(parse("").isEmpty)
        XCTAssertTrue(parse("\n\n\n").isEmpty)
        XCTAssertTrue(parse("hello world").isEmpty)
    }

    func testOversizedMinuteFieldsAreNotTimestamps() {
        XCTAssertTrue(parse("[100:00.00] too long").isEmpty)
        XCTAssertTrue(parse("[00:100.00] too long").isEmpty)
        XCTAssertEqual(parse("[99:59.99] max").first?.time ?? 0, 99 * 60 + 59.99, accuracy: 1e-6)
    }

    func testUnicodeLyricsAreKept() {
        XCTAssertEqual(parse("[00:01.00] 日本語の歌詞 🎵").first?.text, "日本語の歌詞 🎵")
    }

    func testCRLFLyricsAreSplitIntoLines() {
        expectKnownBug("parseLRC splits with split(separator: \"\\n\"), but Swift treats \"\\r\\n\" as ONE Character, so a CRLF file is never split: every timestamp lands on a single 'line' and all of them show the last lyric (with a trailing CRLF). Medium severity for synced lyrics from Windows-authored files.")
        let lines = parse("[00:01.00] one\r\n[00:02.00] two\r\n")
        XCTAssertEqual(lines.map(\.text), ["one", "two"])
    }

    func testLargeLyricsParseQuickly() {
        let lyrics = (0..<30_000).map { index in
            String(format: "[%02d:%02d.%02d] line %d", (index / 60) % 100, index % 60, index % 100, index)
        }.joined(separator: "\n")
        let start = Date()
        XCTAssertEqual(parse(lyrics).count, 30_000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testPathologicalLinesDoNotBackTrack() {
        let evil = String(repeating: "[", count: 100_000) + "00:00"
        let start = Date()
        XCTAssertTrue(parse(evil).isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    // MARK: Resolving a lyrics entry

    private func entry(_ json: String) throws -> MediaPlaybackService.LRCEntry {
        try JSONDecoder().decode(MediaPlaybackService.LRCEntry.self, from: Data(json.utf8))
    }

    func testInstrumentalTracksShowAMarker() throws {
        let content = MediaPlaybackService.resolvedLyrics(from: try entry(#"{"instrumental": true, "plainLyrics": "ignored"}"#))
        XCTAssertEqual(content, LyricsContent(plain: "♪ Instrumental ♪", lines: []))
    }

    func testPlainOnlyLyrics() throws {
        let content = MediaPlaybackService.resolvedLyrics(from: try entry(#"{"plainLyrics": "  line one\nline two \n"}"#))
        XCTAssertEqual(content?.plain, "line one\nline two")
        XCTAssertEqual(content?.hasSyncedLines, false)
    }

    func testSyncedOnlyLyricsDerivePlainText() throws {
        let content = MediaPlaybackService.resolvedLyrics(from: try entry(#"{"syncedLyrics": "[00:01.00] one\n[00:02.00] two"}"#))
        XCTAssertEqual(content?.plain, "one\ntwo")
        XCTAssertEqual(content?.lines.count, 2)
        XCTAssertEqual(content?.hasSyncedLines, true)
    }

    func testBothKindsPreferTheSuppliedPlainText() throws {
        let content = MediaPlaybackService.resolvedLyrics(
            from: try entry(#"{"plainLyrics": "plain", "syncedLyrics": "[00:01.00] synced"}"#)
        )
        XCTAssertEqual(content?.plain, "plain")
        XCTAssertEqual(content?.lines.first?.text, "synced")
    }

    func testEmptyEntriesResolveToNothing() throws {
        for json in ["{}", #"{"plainLyrics": ""}"#, #"{"plainLyrics": "   \n "}"#, #"{"syncedLyrics": ""}"#,
                     #"{"instrumental": false}"#, #"{"plainLyrics": null, "syncedLyrics": null}"#] {
            XCTAssertNil(MediaPlaybackService.resolvedLyrics(from: try entry(json)), json)
        }
    }

    func testEntryDecodingToleratesUnknownKeysAndRejectsWrongTypes() throws {
        XCTAssertNoThrow(try entry(#"{"id": 5, "trackName": "x", "duration": 100.5, "plainLyrics": "a"}"#))
        XCTAssertThrowsError(try entry(#"{"plainLyrics": 5}"#))
        XCTAssertThrowsError(try entry(#"{"instrumental": "yes"}"#))
    }

    // MARK: MediaRemote helper payloads

    private func snapshot(_ json: String) throws -> MediaRemoteSnapshot {
        try JSONDecoder().decode(MediaRemoteSnapshot.self, from: Data(json.utf8))
    }

    func testSnapshotDecodesTypicalHelperLine() throws {
        let s = try snapshot("""
        {"type": "data", "diff": false, "payload": {"bundleIdentifier": "com.apple.Music", "title": "T",
         "artist": "A", "album": "Al", "duration": 200.5, "elapsedTime": 12.25, "playing": true,
         "artworkData": "AQID", "artworkMimeType": "image/png", "timestamp": "2026-10-12T10:00:00Z"}}
        """)
        XCTAssertEqual(s.payload.bundleIdentifier, "com.apple.Music")
        XCTAssertEqual(s.payload.duration, 200.5)
        XCTAssertEqual(s.payload.playing, true)
        XCTAssertEqual(s.diff, false)
    }

    func testSnapshotRequiresAPayloadObject() {
        for json in ["{}", #"{"payload": null}"#, #"{"payload": []}"#, #"{"type": "data"}"#, "null", "[]"] {
            XCTAssertThrowsError(try snapshot(json), json)
        }
    }

    func testSnapshotFieldsAreOptional() throws {
        let s = try snapshot(#"{"payload": {}}"#)
        XCTAssertNil(s.payload.title)
        XCTAssertNil(s.payload.bundleIdentifier)
        XCTAssertNil(s.diff)
    }

    func testSnapshotRejectsWrongFieldTypes() {
        for json in [
            #"{"payload": {"title": 5}}"#, #"{"payload": {"duration": "long"}}"#,
            #"{"payload": {"playing": "yes"}}"#, #"{"payload": {"artworkData": 7}}"#,
        ] {
            XCTAssertThrowsError(try snapshot(json), json)
        }
    }

    func testDiffPayloadMergesOverTheBase() throws {
        let base = try snapshot(#"{"payload": {"bundleIdentifier": "b", "title": "Old", "artist": "A", "elapsedTime": 1, "playing": true}}"#).payload
        let diff = try snapshot(#"{"diff": true, "payload": {"title": "New", "elapsedTime": 9}}"#).payload
        let merged = diff.merged(over: base)
        XCTAssertEqual(merged.title, "New")
        XCTAssertEqual(merged.artist, "A")
        XCTAssertEqual(merged.bundleIdentifier, "b")
        XCTAssertEqual(merged.elapsedTime, 9)
        XCTAssertEqual(merged.playing, true)
    }

    func testMergeWithoutBaseKeepsPayloadAsIs() throws {
        let payload = try snapshot(#"{"payload": {"title": "Only"}}"#).payload
        let merged = payload.merged(over: nil)
        XCTAssertEqual(merged.title, "Only")
        XCTAssertNil(merged.artist)
    }

    func testHugeNumbersInPayloadDoNotTrapDecoding() throws {
        let s = try snapshot(#"{"payload": {"duration": 1e308, "elapsedTime": -1e308}}"#)
        let estimate = MediaPlaybackState(
            bundleIdentifier: "b", displayName: "B", title: "T", artist: "", album: "",
            currentTime: s.payload.elapsedTime ?? 0, duration: s.payload.duration ?? 0,
            isPlaying: true, isAvailable: true, supportsFavorite: false, isFavorite: false,
            artworkData: nil, lastUpdated: Date()
        ).estimatedCurrentTime
        XCTAssertTrue(estimate.isFinite)
    }
}

// MARK: - Batteries

final class BatteriesPureTests: XCTestCase {

    // MARK: Number coercion

    func testBoundedPercentage() {
        let cases: [(Any?, Int?)] = [
            (NSNumber(value: 50), 50), (NSNumber(value: 0), 0), (NSNumber(value: 100), 100),
            (NSNumber(value: 101), 100), (NSNumber(value: 250), 100), (NSNumber(value: -1), 0),
            (NSNumber(value: -1_000_000), 0), (75, 75), (Int.max, 100), (Int.min, 0),
            ("50", nil), (nil, nil), (50.5 as Double, 50), (true, 1), ([50], nil),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(BatteriesService.boundedPercentage(input), expected, "\(String(describing: input))")
        }
    }

    func testBoundedPercentageAcceptsFloatingNSNumbers() {
        XCTAssertEqual(BatteriesService.boundedPercentage(NSNumber(value: 55.9)), 55)
        XCTAssertEqual(BatteriesService.boundedPercentage(NSNumber(value: Double.nan)).map { (0...100).contains($0) }, true)
        XCTAssertEqual(BatteriesService.boundedPercentage(NSNumber(value: 1e30)).map { (0...100).contains($0) }, true)
    }

    func testNumberValue() {
        XCTAssertEqual(BatteriesService.numberValue(NSNumber(value: 7)), 7)
        XCTAssertEqual(BatteriesService.numberValue(7), 7)
        XCTAssertEqual(BatteriesService.numberValue(NSNumber(value: true)), 1)
        XCTAssertNil(BatteriesService.numberValue("7"))
        XCTAssertNil(BatteriesService.numberValue(nil))
        XCTAssertNil(BatteriesService.numberValue(Data()))
    }

    func testUInt32Value() {
        XCTAssertEqual(BatteriesService.uint32Value(NSNumber(value: 5)), 5)
        XCTAssertEqual(BatteriesService.uint32Value(UInt32(9)), 9)
        XCTAssertEqual(BatteriesService.uint32Value(UInt64(7)), 7)
        XCTAssertEqual(BatteriesService.uint32Value(Int(3)), 3)
        XCTAssertEqual(BatteriesService.uint32Value(UInt64.max), UInt32.max)
        XCTAssertNil(BatteriesService.uint32Value("5"))
        XCTAssertNil(BatteriesService.uint32Value(nil))
    }

    func testUInt32ValueGoesThroughNSNumberForEverySwiftNumber() {
        // Swift Int and UInt64 boxes bridge to NSNumber, so they match the
        // first switch case and NSNumber's wrapping conversion applies. The
        // `UInt32(clamping:)` branches below it are never reached. Harmless
        // for IOKit location ids (always in range); pinned for clarity.
        XCTAssertEqual(BatteriesService.uint32Value(Int(-3)), UInt32.max - 2)
        XCTAssertEqual(BatteriesService.uint32Value(UInt64(0x1_0000_0005)), 5)
    }

    func testTrimmedNonEmptyString() {
        XCTAssertEqual(BatteriesService.trimmedNonEmptyString("  Magic Mouse \n"), "Magic Mouse")
        XCTAssertNil(BatteriesService.trimmedNonEmptyString(""))
        XCTAssertNil(BatteriesService.trimmedNonEmptyString(" \t\n "))
        XCTAssertNil(BatteriesService.trimmedNonEmptyString(5))
        XCTAssertNil(BatteriesService.trimmedNonEmptyString(nil))
        XCTAssertEqual(BatteriesService.trimmedNonEmptyString("日本"), "日本")
    }

    // MARK: Durations and descriptions

    func testDurationText() {
        let cases: [(Int, String)] = [
            (0, "0m"), (1, "1m"), (59, "59m"), (60, "1h"), (61, "1h 1m"), (90, "1h 30m"),
            (120, "2h"), (1_440, "24h"), (1_441, "24h 1m"), (59_999, "999h 59m"),
        ]
        for (minutes, text) in cases {
            XCTAssertEqual(BatteriesService.durationText(minutes: minutes), text, "\(minutes)")
        }
    }

    func testDurationTextHandlesExtremesWithoutTrapping() {
        _ = BatteriesService.durationText(minutes: Int.max)
        _ = BatteriesService.durationText(minutes: Int.min + 1)
        _ = BatteriesService.durationText(minutes: -90)
    }

    func testChargingDescriptions() {
        XCTAssertEqual(
            BatteriesService.internalPowerStateDescription(isCharging: true, powerSourceState: nil, timeToEmpty: nil, timeToFull: 75),
            "Charging • 1h 15m until full"
        )
        XCTAssertEqual(
            BatteriesService.internalPowerStateDescription(isCharging: true, powerSourceState: nil, timeToEmpty: nil, timeToFull: nil),
            "Charging"
        )
        for unknown in [0, -1, -999] {
            XCTAssertEqual(
                BatteriesService.internalPowerStateDescription(isCharging: true, powerSourceState: nil, timeToEmpty: nil, timeToFull: unknown),
                "Charging", "IOKit reports -1 while it is still estimating"
            )
        }
    }

    func testDischargingDescriptions() {
        let ac = kIOPSACPowerValueForTests
        let battery = kIOPSBatteryPowerValueForTests
        XCTAssertEqual(
            BatteriesService.internalPowerStateDescription(isCharging: false, powerSourceState: ac, timeToEmpty: 30, timeToFull: nil),
            "On power"
        )
        XCTAssertEqual(
            BatteriesService.internalPowerStateDescription(isCharging: false, powerSourceState: battery, timeToEmpty: 125, timeToFull: nil),
            "2h 5m remaining"
        )
        XCTAssertEqual(
            BatteriesService.internalPowerStateDescription(isCharging: false, powerSourceState: battery, timeToEmpty: -1, timeToFull: nil),
            "On battery"
        )
        XCTAssertNil(BatteriesService.internalPowerStateDescription(isCharging: false, powerSourceState: nil, timeToEmpty: nil, timeToFull: nil))
        XCTAssertNil(BatteriesService.internalPowerStateDescription(isCharging: false, powerSourceState: "Weird", timeToEmpty: 0, timeToFull: nil))
    }

    // MARK: Accessories

    func testInferredNamesFromNotificationType() {
        let cases: [(String, String)] = [("KB1", "Keyboard"), ("TP2", "Trackpad"), ("M3", "Mouse"), ("Z9", "Accessory")]
        for (type, name) in cases {
            XCTAssertEqual(BatteriesService.inferredAccessoryName(from: ["ConnectionNotificationType": type]), name)
        }
    }

    func testInferredNamesFromIOClass() {
        XCTAssertEqual(BatteriesService.inferredAccessoryName(from: ["IOClass": "AppleBluetoothHIDKeyboard"]), "Keyboard")
        XCTAssertEqual(BatteriesService.inferredAccessoryName(from: ["IOClass": "AppleMultitouchTrackpad"]), "Trackpad")
        XCTAssertEqual(BatteriesService.inferredAccessoryName(from: ["IOClass": "BNBMouseDevice"]), "Mouse")
        XCTAssertEqual(BatteriesService.inferredAccessoryName(from: ["IOClass": "Something"]), "Accessory")
        XCTAssertEqual(BatteriesService.inferredAccessoryName(from: [:]), "Accessory")
    }

    func testNotificationTypeWinsOverIOClass() {
        let name = BatteriesService.inferredAccessoryName(from: ["ConnectionNotificationType": "KB", "IOClass": "Mouse"])
        XCTAssertEqual(name, "Keyboard")
    }

    func testWrongTypedPropertiesAreIgnored() {
        XCTAssertEqual(BatteriesService.inferredAccessoryName(from: ["ConnectionNotificationType": 5, "IOClass": ["x"]]), "Accessory")
    }

    func testAccessoryKindFromName() {
        let cases: [(String, BatteryDeviceSnapshot.Kind)] = [
            ("Magic Keyboard", .keyboard), ("MAGIC TRACKPAD", .trackpad), ("Logitech MX Mouse", .mouse),
            ("Anthony's AirPods Pro", .headphones), ("Beats Studio", .headphones), ("Sony Headphones", .headphones),
            ("Gamepad", .accessory), ("", .accessory),
        ]
        for (name, kind) in cases {
            XCTAssertEqual(BatteriesService.accessoryKind(for: name, properties: [:]), kind, name)
        }
        XCTAssertEqual(BatteriesService.accessoryKind(for: "Thing", properties: ["Transport": "Bluetooth"]), .accessory)
    }

    func testAccessoryIdentifierPriority() {
        XCTAssertEqual(
            BatteriesService.accessoryIdentifier(locationID: 77, properties: ["DeviceAddress": "aa", "SerialNumber": "s"], fallbackName: "N"),
            "battery-accessory-location-77"
        )
        XCTAssertEqual(
            BatteriesService.accessoryIdentifier(locationID: nil, properties: ["DeviceAddress": " aa-bb ", "SerialNumber": "s"], fallbackName: "N"),
            "battery-accessory-address-aa-bb"
        )
        XCTAssertEqual(
            BatteriesService.accessoryIdentifier(locationID: nil, properties: ["SerialNumber": "S123"], fallbackName: "N"),
            "battery-accessory-serial-S123"
        )
        XCTAssertEqual(
            BatteriesService.accessoryIdentifier(locationID: nil, properties: [:], fallbackName: "Magic Mouse 2"),
            "battery-accessory-magic-mouse-2"
        )
        XCTAssertEqual(
            BatteriesService.accessoryIdentifier(locationID: nil, properties: ["DeviceAddress": "  "], fallbackName: "X"),
            "battery-accessory-x"
        )
    }

    func testBatteryLevelsFromRegistryProperties() {
        let levels = BatteriesService.batteryLevels(from: [
            "BatteryPercent": 80, "BatteryPercentLeft": NSNumber(value: 55), "BatteryPercentRight": 130,
            "BatteryPercentCase": -4,
        ])
        XCTAssertEqual(levels.map(\.component), [.main, .left, .right, .caseBattery])
        XCTAssertEqual(levels.map(\.percentage), [80, 55, 100, 0])
    }

    func testBatteryLevelsSkipMissingAndMalformedValues() {
        let levels = BatteriesService.batteryLevels(from: [
            "BatteryPercent": "high", "BatteryPercentLeft": NSNull(), "BatteryPercentCase": 40, "Other": 5,
        ])
        XCTAssertEqual(levels.map(\.component), [.caseBattery])
        XCTAssertTrue(BatteriesService.batteryLevels(from: [:]).isEmpty)
    }

    // MARK: Snapshots

    private func device(
        _ id: String, _ name: String, kind: BatteryDeviceSnapshot.Kind, levels: [(BatteryLevelSnapshot.Component, Int)]
    ) -> BatteryDeviceSnapshot {
        BatteryDeviceSnapshot(
            id: id, name: name, kind: kind, transport: nil, isCharging: false,
            levels: levels.map { BatteryLevelSnapshot(component: $0.0, percentage: $0.1) },
            powerStateDescription: nil
        )
    }

    func testPrimaryPercentagePrefersMainLevel() {
        let d = device("a", "A", kind: .headphones, levels: [(.left, 20), (.main, 70), (.right, 40)])
        XCTAssertEqual(d.primaryPercentage, 70)
    }

    func testPrimaryPercentageAveragesAndRounds() {
        XCTAssertEqual(device("a", "A", kind: .headphones, levels: [(.left, 20), (.right, 41)]).primaryPercentage, 31)
        XCTAssertEqual(device("a", "A", kind: .headphones, levels: [(.left, 1), (.right, 2)]).primaryPercentage, 2)
        XCTAssertEqual(device("a", "A", kind: .headphones, levels: [(.left, 100), (.right, 100), (.caseBattery, 100)]).primaryPercentage, 100)
    }

    func testPrimaryPercentageWithoutLevelsIsNil() {
        let d = device("a", "A", kind: .mouse, levels: [])
        XCTAssertNil(d.primaryPercentage)
        XCTAssertNil(d.minimumPercentage)
    }

    func testMinimumPercentageIsTheLowestComponent() {
        XCTAssertEqual(device("a", "A", kind: .headphones, levels: [(.left, 30), (.right, 12), (.caseBattery, 90)]).minimumPercentage, 12)
    }

    func testSnapshotAccessors() {
        let mac = device("m", "Mac", kind: .mac, levels: [(.main, 60)])
        let mouse = device("x", "Mouse", kind: .mouse, levels: [(.main, 15)])
        let snapshot = BatteriesSnapshot(devices: [mouse, mac])
        XCTAssertEqual(snapshot.internalBattery, mac)
        XCTAssertEqual(snapshot.accessoryDevices, [mouse])
        XCTAssertEqual(snapshot.primaryDevice, mac)
        XCTAssertEqual(snapshot.lowestPercentage, 15)
        XCTAssertFalse(snapshot.isEmpty)
    }

    func testSnapshotWithoutAMacUsesFirstAccessory() {
        let a = device("a", "A", kind: .mouse, levels: [(.main, 50)])
        let b = device("b", "B", kind: .keyboard, levels: [(.main, 70)])
        let snapshot = BatteriesSnapshot(devices: [a, b])
        XCTAssertNil(snapshot.internalBattery)
        XCTAssertEqual(snapshot.primaryDevice, a)
    }

    func testEmptySnapshot() {
        let snapshot = BatteriesSnapshot(devices: [])
        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertNil(snapshot.primaryDevice)
        XCTAssertNil(snapshot.lowestPercentage)
    }

    func testLevelLabels() {
        XCTAssertNil(BatteryLevelSnapshot.Component.main.shortLabel)
        XCTAssertEqual(BatteryLevelSnapshot.Component.left.shortLabel, "L")
        XCTAssertEqual(BatteryLevelSnapshot.Component.right.shortLabel, "R")
        XCTAssertEqual(BatteryLevelSnapshot.Component.caseBattery.shortLabel, "C")
        XCTAssertEqual(BatteryLevelSnapshot(component: .left, percentage: 5).id, "left")
    }

    func testSortOrderIsKindThenChargeThenName() {
        let devices = [
            device("1", "zeta", kind: .mouse, levels: [(.main, 50)]),
            device("2", "Alpha", kind: .mouse, levels: [(.main, 50)]),
            device("3", "low", kind: .mouse, levels: [(.main, 5)]),
            device("4", "kb", kind: .keyboard, levels: [(.main, 90)]),
            device("5", "mac", kind: .mac, levels: [(.main, 100)]),
            device("6", "unknown", kind: .mouse, levels: []),
            device("7", "buds", kind: .headphones, levels: [(.main, 1)]),
            device("8", "thing", kind: .accessory, levels: [(.main, 1)]),
            device("9", "pad", kind: .trackpad, levels: [(.main, 1)]),
        ]
        let sorted = BatteriesService.sortedForDisplay(devices).map(\.id)
        XCTAssertEqual(sorted, ["5", "4", "9", "3", "2", "1", "6", "7", "8"])
    }

    func testSortRankIsTotalAndOrdered() {
        let kinds: [BatteryDeviceSnapshot.Kind] = [.mac, .keyboard, .trackpad, .mouse, .headphones, .accessory]
        XCTAssertEqual(kinds.map(\.sortRank), [0, 1, 2, 3, 4, 5])
    }

    func testSortHandlesManyDevices() {
        let devices = (0..<2_000).map { index in
            device("d\(index)", "Device \(index % 17)", kind: [.mouse, .keyboard, .accessory][index % 3], levels: [(.main, index % 101)])
        }
        XCTAssertEqual(BatteriesService.sortedForDisplay(devices).count, 2_000)
    }
}

// IOKit's power-source constants are C macros that Swift exposes as macros;
// the strings below are their documented values.
private let kIOPSACPowerValueForTests = "AC Power"
private let kIOPSBatteryPowerValueForTests = "Battery Power"

// MARK: - System status

final class SystemStatusPureTests: XCTestCase {

    // MARK: CPU

    private func cpu(_ user: UInt64, _ system: UInt64, _ idle: UInt64, _ nice: UInt64 = 0) -> CPUSample {
        CPUSample(user: user, system: system, idle: idle, nice: nice)
    }

    func testCPUUsagePercent() {
        XCTAssertEqual(SystemStatusService.cpuUsagePercent(from: cpu(0, 0, 0), to: cpu(25, 25, 50)), 50, accuracy: 0.0001)
        XCTAssertEqual(SystemStatusService.cpuUsagePercent(from: cpu(10, 10, 10, 10), to: cpu(10, 10, 110, 10)), 0, accuracy: 0.0001)
        XCTAssertEqual(SystemStatusService.cpuUsagePercent(from: cpu(0, 0, 0), to: cpu(100, 0, 0)), 100, accuracy: 0.0001)
        XCTAssertEqual(SystemStatusService.cpuUsagePercent(from: cpu(0, 0, 0), to: cpu(10, 10, 60, 20)), 40, accuracy: 0.0001)
    }

    func testCPUUsageWithNoElapsedTicksIsZero() {
        let same = cpu(100, 100, 100, 100)
        XCTAssertEqual(SystemStatusService.cpuUsagePercent(from: same, to: same), 0)
    }

    func testCPUUsageAcrossAThirtyTwoBitCounterWrap() {
        expectKnownBug("The ticks are 32-bit counters widened to UInt64. After a wrap, current < previous, `&-` yields about 2^64 and the result is a bogus 100% (two counters wrapping in one interval would trap on `+`). The delta needs to be computed modulo 2^32.")
        let previous = cpu(4_294_967_290, 100, 100)
        let current = cpu(10, 116, 116) // user advanced 16, system 16, idle 16
        let percent = SystemStatusService.cpuUsagePercent(from: previous, to: current)
        XCTAssertEqual(percent, 66.6667, accuracy: 0.01)
    }

    func testCPUUsageIsAlwaysAFraction() {
        let samples: [(CPUSample, CPUSample)] = [
            (cpu(0, 0, 0), cpu(1, 0, 0)), (cpu(5, 5, 5), cpu(5, 5, 5)), (cpu(0, 0, 0), cpu(0, 0, 1)),
            (cpu(1_000_000, 0, 0), cpu(2_000_000, 0, 1)),
        ]
        for (a, b) in samples {
            let value = SystemStatusService.cpuUsagePercent(from: a, to: b)
            XCTAssertTrue((0...100).contains(value))
        }
    }

    // MARK: Memory

    func testMemoryUsagePercent() {
        XCTAssertEqual(MemorySample(usedBytes: 4, totalBytes: 16).usagePercent, 25)
        XCTAssertEqual(MemorySample(usedBytes: 0, totalBytes: 16).usagePercent, 0)
        XCTAssertEqual(MemorySample(usedBytes: 16, totalBytes: 16).usagePercent, 100)
    }

    func testMemoryUsageIsClampedAndSafe() {
        XCTAssertEqual(MemorySample(usedBytes: 32, totalBytes: 16).usagePercent, 100)
        XCTAssertEqual(MemorySample(usedBytes: 5, totalBytes: 0).usagePercent, 0)
        XCTAssertEqual(MemorySample(usedBytes: .max, totalBytes: 1).usagePercent, 100)
        XCTAssertTrue((0...100).contains(MemorySample(usedBytes: .max, totalBytes: .max).usagePercent))
    }

    // MARK: Network

    private func counters(_ offset: TimeInterval, rx: UInt64, tx: UInt64) -> NetworkCounters {
        NetworkCounters(timestamp: Date(timeIntervalSince1970: 1_000 + offset), receivedBytes: rx, sentBytes: tx)
    }

    func testThroughputIsDeltaOverElapsed() {
        let t = SystemStatusService.networkThroughput(
            from: counters(0, rx: 1_000, tx: 500),
            to: counters(2, rx: 5_000, tx: 1_500)
        )
        XCTAssertEqual(t.receivedBytesPerSecond, 2_000, accuracy: 0.001)
        XCTAssertEqual(t.sentBytesPerSecond, 500, accuracy: 0.001)
    }

    func testThroughputIsZeroWithoutElapsedTime() {
        for elapsed in [0.0, -5.0] {
            let t = SystemStatusService.networkThroughput(
                from: counters(10, rx: 0, tx: 0), to: counters(10 + elapsed, rx: 999, tx: 999)
            )
            XCTAssertEqual(t.receivedBytesPerSecond, 0)
            XCTAssertEqual(t.sentBytesPerSecond, 0)
        }
    }

    func testCounterResetReadsAsZeroNotNegative() {
        let t = SystemStatusService.networkThroughput(
            from: counters(0, rx: 10_000, tx: 10_000),
            to: counters(1, rx: 50, tx: 20_000)
        )
        XCTAssertEqual(t.receivedBytesPerSecond, 0)
        XCTAssertEqual(t.sentBytesPerSecond, 10_000, accuracy: 0.001)
    }

    func testThroughputWithHugeCountersIsFinite() {
        let t = SystemStatusService.networkThroughput(
            from: counters(0, rx: 0, tx: 0),
            to: counters(1, rx: .max, tx: .max)
        )
        XCTAssertTrue(t.receivedBytesPerSecond.isFinite)
        XCTAssertTrue(t.sentBytesPerSecond.isFinite)
    }

    func testInterfaceFilter() {
        let up = Int32(IFF_UP)
        let loopback = Int32(IFF_LOOPBACK)
        XCTAssertTrue(SystemStatusService.shouldIncludeNetworkInterface(named: "en0", flags: up))
        XCTAssertTrue(SystemStatusService.shouldIncludeNetworkInterface(named: "pdp_ip0", flags: up))
        XCTAssertFalse(SystemStatusService.shouldIncludeNetworkInterface(named: "en0", flags: 0), "down")
        XCTAssertFalse(SystemStatusService.shouldIncludeNetworkInterface(named: "lo0", flags: up | loopback))
        for name in ["awdl0", "llw0", "utun3", "bridge100", "anpi1"] {
            XCTAssertFalse(SystemStatusService.shouldIncludeNetworkInterface(named: name, flags: up), name)
        }
    }

    func testInterfaceFilterIsPrefixBased() {
        let up = Int32(IFF_UP)
        XCTAssertTrue(SystemStatusService.shouldIncludeNetworkInterface(named: "xutun0", flags: up))
        XCTAssertTrue(SystemStatusService.shouldIncludeNetworkInterface(named: "", flags: up))
    }

    // MARK: Text

    func testPercentText() {
        let cases: [(Double, String)] = [
            (0, "0%"), (0.4, "0%"), (0.5, "1%"), (49.5, "50%"), (99.5, "100%"), (100, "100%"),
            (12.34, "12%"), (-0.4, "0%"),
        ]
        for (value, text) in cases {
            XCTAssertEqual(SystemStatusSnapshot.percentText(value), text, "\(value)")
        }
    }

    func testCompactRateText() {
        let cases: [(Double, String)] = [
            (0, "0B"), (1, "1B"), (999, "999B"), (1_023, "1023B"), (1_023.6, "1024B"),
            (1_024, "1.0K"), (1_536, "1.5K"), (10_239, "10.0K"), (10_240, "10K"), (1_000_000, "977K"),
            (1_048_576, "1.0M"), (5_242_880, "5.0M"), (1_073_741_824, "1.0G"), (1_099_511_627_776, "1024G"),
            (-5, "0B"), (-1e300, "0B"), (.nan, "0B"),
        ]
        for (value, text) in cases {
            XCTAssertEqual(SystemStatusSnapshot.compactRateText(value), text, "\(value)")
        }
    }

    func testNetworkProgress() {
        XCTAssertEqual(SystemStatusSnapshot.networkProgress(0), 0)
        XCTAssertEqual(SystemStatusSnapshot.networkProgress(-100), 0)
        XCTAssertEqual(SystemStatusSnapshot.networkProgress(.nan), 0)
        XCTAssertEqual(SystemStatusSnapshot.networkProgress(25 * 1_024 * 1_024), 1, accuracy: 0.0001)
        XCTAssertEqual(SystemStatusSnapshot.networkProgress(1e12), 1)
        XCTAssertEqual(SystemStatusSnapshot.networkProgress(.infinity), 1)
    }

    func testNetworkProgressIsMonotonic() {
        var previous = -1.0
        for rate in [0.0, 1, 10, 1_000, 100_000, 10_000_000, 30_000_000] {
            let value = SystemStatusSnapshot.networkProgress(rate)
            XCTAssertGreaterThanOrEqual(value, previous)
            XCTAssertTrue((0...1).contains(value))
            previous = value
        }
    }

    // MARK: Snapshot

    private func snapshot(cpu: Double, memory: Double, rx: Double = 0, tx: Double = 0) -> SystemStatusSnapshot {
        SystemStatusSnapshot(
            cpuUsagePercent: cpu, memoryUsagePercent: memory, usedMemoryBytes: 1, totalMemoryBytes: 2,
            receivedBytesPerSecond: rx, sentBytesPerSecond: tx
        )
    }

    func testMetricsShape() {
        let metrics = snapshot(cpu: 12.4, memory: 50, rx: 1_024, tx: 1_024).metrics
        XCTAssertEqual(metrics.map(\.kind), [.cpu, .memory, .network])
        XCTAssertEqual(metrics.map(\.primaryText), ["12%", "50%", "2.0K"])
        XCTAssertEqual(metrics.map(\.secondaryText), ["CPU", "MEM", "NET"])
        XCTAssertEqual(metrics[0].progress, 0.124, accuracy: 0.0001)
        XCTAssertEqual(metrics.map(\.id), ["cpu", "memory", "network"])
    }

    func testMetricProgressIsClampedForOutOfRangeInputs() {
        let high = snapshot(cpu: 250, memory: 400).metrics
        XCTAssertEqual(high[0].progress, 1)
        XCTAssertEqual(high[1].progress, 1)
        let low = snapshot(cpu: -50, memory: -1).metrics
        XCTAssertEqual(low[0].progress, 0)
        XCTAssertEqual(low[1].progress, 0)
    }

    func testTotalNetworkRate() {
        XCTAssertEqual(snapshot(cpu: 0, memory: 0, rx: 3, tx: 4).totalNetworkBytesPerSecond, 7)
    }

    func testKindSymbols() {
        XCTAssertEqual(SystemStatusMetricKind.allCases.count, 3)
        XCTAssertEqual(Set(SystemStatusMetricKind.allCases.map(\.symbolName)).count, 3)
    }
}
