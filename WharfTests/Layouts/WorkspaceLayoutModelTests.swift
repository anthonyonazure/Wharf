import XCTest
@testable import Wharf

/// The saved-layout data model and the pure geometry/matching behind capture
/// and restore: coordinate flips, clamping, display resolution and which
/// window each placement claims.
@MainActor
final class WorkspaceLayoutModelTests: LayoutTestCase {

    // MARK: - Codable

    func testPlacementRoundTrip() throws {
        let placement = makePlacement(title: "Inbox", frame: CGRect(x: -20.5, y: 10.25, width: 640, height: 480))
        let data = try JSONEncoder().encode(placement)
        XCTAssertEqual(try JSONDecoder().decode(WindowPlacement.self, from: data), placement)
    }

    func testPlacementWithNilDisplayRoundTrip() throws {
        let placement = makePlacement(display: nil)
        let decoded = try JSONDecoder().decode(WindowPlacement.self, from: JSONEncoder().encode(placement))
        XCTAssertNil(decoded.displayUUID)
        XCTAssertEqual(decoded, placement)
    }

    func testLayoutRoundTripKeepsPlacementOrder() throws {
        let placements = (0..<12).map { makePlacement(bundle: "com.test.app\($0)", title: "W\($0)") }
        let layout = makeLayout(name: "Ordered", placements: placements)
        let decoded = try JSONDecoder().decode(WorkspaceLayout.self, from: JSONEncoder().encode(layout))
        XCTAssertEqual(decoded.placements.map(\.windowTitle), placements.map(\.windowTitle))
        XCTAssertEqual(decoded, layout)
    }

    func testLayoutArrayRoundTrip() throws {
        let layouts = (0..<5).map { makeLayout(name: "Layout \($0)", placements: [makePlacement(title: "T\($0)")]) }
        let decoded = try JSONDecoder().decode([WorkspaceLayout].self, from: JSONEncoder().encode(layouts))
        XCTAssertEqual(decoded, layouts)
    }

    func testEveryTruncationOfStoredLayoutFailsToDecode() throws {
        let data = try JSONEncoder().encode([makeLayout(placements: [makePlacement()])])
        for length in stride(from: 0, to: data.count, by: 3) {
            let truncated = data.prefix(length)
            XCTAssertThrowsError(
                try JSONDecoder().decode([WorkspaceLayout].self, from: truncated),
                "a \(length) byte prefix of a \(data.count) byte blob must not decode"
            )
        }
    }

    func testMissingRequiredKeysFailToDecode() throws {
        let layout = makeLayout(placements: [makePlacement()])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(layout)) as! [String: Any]
        for key in ["id", "name", "placements", "bundleIdentifiers"] {
            var broken = json
            broken.removeValue(forKey: key)
            let data = try JSONSerialization.data(withJSONObject: broken)
            XCTAssertThrowsError(try JSONDecoder().decode(WorkspaceLayout.self, from: data), "missing \(key)")
        }
    }

    func testMissingPlacementKeysFailToDecode() throws {
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(makePlacement())) as! [String: Any]
        for key in ["bundleIdentifier", "windowTitle", "frame"] {
            var broken = json
            broken.removeValue(forKey: key)
            let data = try JSONSerialization.data(withJSONObject: broken)
            XCTAssertThrowsError(try JSONDecoder().decode(WindowPlacement.self, from: data), "missing \(key)")
        }
    }

    func testMissingDisplayUUIDDecodesAsNil() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(makePlacement())) as! [String: Any]
        json.removeValue(forKey: "displayUUID")
        let data = try JSONSerialization.data(withJSONObject: json)
        XCTAssertNil(try JSONDecoder().decode(WindowPlacement.self, from: data).displayUUID)
    }

    func testWrongTypesFailToDecode() {
        let blobs = [
            #"{"id":1,"name":"x","placements":[],"bundleIdentifiers":[]}"#,
            #"{"id":"a","name":null,"placements":[],"bundleIdentifiers":[]}"#,
            #"{"id":"a","name":"x","placements":{},"bundleIdentifiers":[]}"#,
            #"{"id":"a","name":"x","placements":[],"bundleIdentifiers":"com.a"}"#,
            #"[]"#,
            #"null"#,
            #""layout""#,
        ]
        for blob in blobs {
            XCTAssertThrowsError(try JSONDecoder().decode(WorkspaceLayout.self, from: Data(blob.utf8)), blob)
        }
    }

    func testUnknownExtraKeysAreIgnored() throws {
        let blob = #"{"id":"a","name":"x","placements":[],"bundleIdentifiers":[],"futureField":{"a":1}}"#
        let layout = try JSONDecoder().decode(WorkspaceLayout.self, from: Data(blob.utf8))
        XCTAssertEqual(layout.name, "x")
    }

    func testHugeFiniteFrameValuesRoundTrip() throws {
        let frame = CGRect(x: 1e300, y: -1e300, width: 1e299, height: 1e299)
        let placement = makePlacement(frame: frame)
        let decoded = try JSONDecoder().decode(WindowPlacement.self, from: JSONEncoder().encode(placement))
        XCTAssertEqual(decoded.frame, frame)
    }

    func testNonFiniteFrameCannotBeEncoded() {
        for value in [CGFloat.nan, .infinity, -.infinity] {
            let placement = makePlacement(frame: CGRect(x: value, y: 0, width: 10, height: 10))
            XCTAssertThrowsError(try JSONEncoder().encode(placement))
        }
    }

    func testLayoutIsIdentifiableByID() {
        XCTAssertEqual(makeLayout(id: "abc").id, "abc")
    }

    func testLayoutEqualityIncludesEveryField() {
        let base = makeLayout(id: "1", name: "A", placements: [makePlacement()], bundles: ["com.test.app"])
        var other = base
        XCTAssertEqual(base, other)
        other.name = "B"
        XCTAssertNotEqual(base, other)
        other = base
        other.bundleIdentifiers = []
        XCTAssertNotEqual(base, other)
        other = base
        other.placements = []
        XCTAssertNotEqual(base, other)
    }

    // MARK: - Coordinate flip

    func testFlipYKnownValue() {
        // AX top-left (100, 50), 800x600 on a 900pt tall primary display
        // sits at NSScreen y = 900 - (50 + 600) = 250.
        let flipped = WorkspaceLayoutService.flipY(CGRect(x: 100, y: 50, width: 800, height: 600), primaryHeight: 900)
        XCTAssertEqual(flipped, CGRect(x: 100, y: 250, width: 800, height: 600))
    }

    func testFlipYIsItsOwnInverse() {
        let frames = [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: -500, y: -300, width: 640, height: 480),
            CGRect(x: 3000, y: 2000, width: 1, height: 1),
            CGRect(x: 12.5, y: 7.25, width: 333.3, height: 222.2),
        ]
        for frame in frames {
            for height in [CGFloat(600), 900, 1440, 2160] {
                let twice = WorkspaceLayoutService.flipY(
                    WorkspaceLayoutService.flipY(frame, primaryHeight: height),
                    primaryHeight: height
                )
                XCTAssertEqual(twice.minX, frame.minX, accuracy: 1e-9)
                XCTAssertEqual(twice.minY, frame.minY, accuracy: 1e-9)
                XCTAssertEqual(twice.width, frame.width, accuracy: 1e-9)
                XCTAssertEqual(twice.height, frame.height, accuracy: 1e-9)
            }
        }
    }

    func testFlipYKeepsSizeAndX() {
        let frame = CGRect(x: 40, y: 10, width: 300, height: 200)
        let flipped = WorkspaceLayoutService.flipY(frame, primaryHeight: 1000)
        XCTAssertEqual(flipped.minX, 40)
        XCTAssertEqual(flipped.size, frame.size)
    }

    func testFlipYWithZeroNegativeAndHugeValuesDoesNotTrap() {
        let odd = [
            CGRect.zero,
            CGRect(x: 0, y: 0, width: -50, height: -50),
            CGRect(x: 1e300, y: 1e300, width: 1e300, height: 1e300),
            CGRect(x: -1e300, y: -1e300, width: 5, height: 5),
        ]
        for frame in odd {
            _ = WorkspaceLayoutService.flipY(frame, primaryHeight: 900)
            _ = WorkspaceLayoutService.flipY(frame, primaryHeight: 0)
            _ = WorkspaceLayoutService.flipY(frame, primaryHeight: -10)
        }
    }

    // MARK: - Clamp

    func testClampLeavesContainedFrameAlone() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let frame = CGRect(x: 100, y: 100, width: 300, height: 200)
        XCTAssertEqual(WorkspaceLayoutService.clamp(frame, into: visible), frame)
    }

    func testClampPullsOffscreenFramesBackInside() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = CGSize(width: 300, height: 200)
        let cases: [(name: String, origin: CGPoint, expected: CGPoint)] = [
            ("left", CGPoint(x: -500, y: 100), CGPoint(x: 0, y: 100)),
            ("right", CGPoint(x: 5000, y: 100), CGPoint(x: 700, y: 100)),
            ("below", CGPoint(x: 100, y: -900), CGPoint(x: 100, y: 0)),
            ("above", CGPoint(x: 100, y: 9000), CGPoint(x: 100, y: 600)),
            ("corner", CGPoint(x: 9000, y: 9000), CGPoint(x: 700, y: 600)),
        ]
        for item in cases {
            let result = WorkspaceLayoutService.clamp(CGRect(origin: item.origin, size: size), into: visible)
            XCTAssertEqual(result.origin, item.expected, item.name)
            XCTAssertEqual(result.size, size, item.name)
            XCTAssertTrue(visible.contains(result), item.name)
        }
    }

    func testClampShrinksFramesLargerThanTheScreen() {
        let visible = CGRect(x: 100, y: 50, width: 1000, height: 800)
        let result = WorkspaceLayoutService.clamp(CGRect(x: 0, y: 0, width: 4000, height: 3000), into: visible)
        XCTAssertEqual(result, visible)
    }

    func testClampOnlyShrinksTheOversizedAxis() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let result = WorkspaceLayoutService.clamp(CGRect(x: 0, y: 0, width: 4000, height: 100), into: visible)
        XCTAssertEqual(result.width, 1000)
        XCTAssertEqual(result.height, 100)
    }

    func testClampRespectsVisibleOrigin() {
        let visible = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
        let result = WorkspaceLayoutService.clamp(CGRect(x: 0, y: 0, width: 500, height: 400), into: visible)
        XCTAssertEqual(result.minX, 1440)
        XCTAssertTrue(visible.contains(result))
    }

    func testClampOfNegativeSizedRectUsesItsAbsoluteExtent() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let result = WorkspaceLayoutService.clamp(CGRect(x: 500, y: 500, width: -200, height: -100), into: visible)
        XCTAssertGreaterThanOrEqual(result.width, 0)
        XCTAssertGreaterThanOrEqual(result.height, 0)
        XCTAssertTrue(visible.contains(result))
    }

    func testClampOfZeroSizedRectStaysZeroSizedAndInside() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let result = WorkspaceLayoutService.clamp(CGRect(x: -100, y: 5000, width: 0, height: 0), into: visible)
        XCTAssertEqual(result.size, .zero)
        XCTAssertGreaterThanOrEqual(result.origin.x, visible.minX)
        XCTAssertLessThanOrEqual(result.origin.x, visible.maxX)
        XCTAssertGreaterThanOrEqual(result.origin.y, visible.minY)
        XCTAssertLessThanOrEqual(result.origin.y, visible.maxY)
    }

    func testClampWithHugeCoordinatesDoesNotTrapAndStaysInside() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        for value in [CGFloat(1e300), -1e300, 1e15, -1e15] {
            let result = WorkspaceLayoutService.clamp(
                CGRect(x: value, y: value, width: abs(value), height: abs(value)),
                into: visible
            )
            XCTAssertTrue(visible.contains(result), "\(value)")
        }
    }

    func testClampIsIdempotent() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let frames = [
            CGRect(x: -50, y: -50, width: 2000, height: 2000),
            CGRect(x: 900, y: 700, width: 300, height: 300),
            CGRect(x: 10, y: 10, width: 10, height: 10),
        ]
        for frame in frames {
            let once = WorkspaceLayoutService.clamp(frame, into: visible)
            XCTAssertEqual(WorkspaceLayoutService.clamp(once, into: visible), once)
        }
    }

    // MARK: - Display resolution for restore

    func testPlacementWithoutDisplayUUIDOffscreenIsClampedOntoMain() {
        let placement = makePlacement(frame: CGRect(x: -9000, y: -9000, width: 400, height: 300), display: nil)
        let resolved = WorkspaceLayoutService.resolvedFrame(for: placement, displays: [.primary], main: .primary)
        XCTAssertTrue(LayoutDisplay.primary.visibleFrame.contains(resolved))
        XCTAssertEqual(resolved.size, placement.frame.size)
    }

    func testPlacementWithoutDisplayUUIDOnScreenKeepsStoredFrame() {
        let visible = LayoutDisplay.primary.visibleFrame
        let frame = CGRect(x: visible.minX + 10, y: visible.minY + 10, width: 400, height: 300)
        let placement = makePlacement(frame: frame, display: nil)
        let resolved = WorkspaceLayoutService.resolvedFrame(for: placement, displays: [.primary], main: .primary)
        XCTAssertEqual(resolved, frame)
    }

    func testPlacementOnAttachedDisplayKeepsStoredFrameWhenInsideVisibleArea() {
        let placement = makePlacement(frame: CGRect(x: 1500, y: 100, width: 600, height: 400), display: "DISPLAY-B")
        let resolved = WorkspaceLayoutService.resolvedFrame(for: placement, displays: [.primary, .right], main: .primary)
        XCTAssertEqual(resolved, placement.frame)
    }

    func testPlacementOnAttachedDisplayThatMovedIsClampedOntoThatDisplay() {
        // Captured when B sat at x = 0; B now sits at x = 1440.
        let placement = makePlacement(frame: CGRect(x: 100, y: 100, width: 600, height: 400), display: "DISPLAY-B")
        let resolved = WorkspaceLayoutService.resolvedFrame(for: placement, displays: [.primary, .right], main: .primary)
        XCTAssertTrue(LayoutDisplay.right.visibleFrame.contains(resolved))
        XCTAssertEqual(resolved.size, placement.frame.size)
    }

    func testPlacementOnAttachedDisplayIsClampedAgainstVisibleNotFullFrame() {
        // Touches the menu bar strip, which is inside frame but outside visibleFrame.
        let placement = makePlacement(frame: CGRect(x: 100, y: 850, width: 400, height: 50), display: "DISPLAY-A")
        let resolved = WorkspaceLayoutService.resolvedFrame(for: placement, displays: [.primary], main: .primary)
        XCTAssertTrue(LayoutDisplay.primary.visibleFrame.contains(resolved))
    }

    func testPlacementWhoseDisplayIsGoneLandsOnMainDisplay() {
        let placement = makePlacement(frame: CGRect(x: 2000, y: 200, width: 600, height: 400), display: "DISPLAY-B")
        let resolved = WorkspaceLayoutService.resolvedFrame(for: placement, displays: [.primary], main: .primary)
        XCTAssertTrue(LayoutDisplay.primary.visibleFrame.contains(resolved))
        XCTAssertEqual(resolved.size, placement.frame.size, "unplugging a monitor must not resize windows")
    }

    func testPlacementWhoseDisplayIsGoneAndNoMainDisplayKeepsStoredFrame() {
        let placement = makePlacement(frame: CGRect(x: 2000, y: 200, width: 600, height: 400), display: "GONE")
        XCTAssertEqual(
            WorkspaceLayoutService.resolvedFrame(for: placement, displays: [], main: nil),
            placement.frame
        )
    }

    func testOversizedPlacementOnMissingDisplayIsShrunkToMainVisibleArea() {
        let placement = makePlacement(frame: CGRect(x: 0, y: 0, width: 5000, height: 4000), display: "GONE")
        let resolved = WorkspaceLayoutService.resolvedFrame(for: placement, displays: [.primary], main: .primary)
        XCTAssertEqual(resolved, LayoutDisplay.primary.visibleFrame)
    }

    func testPlacementSpanningTwoDisplaysIsClampedIntoItsRecordedDisplay() {
        // Straddles the A/B seam, recorded against A (the larger overlap).
        let placement = makePlacement(frame: CGRect(x: 1000, y: 100, width: 900, height: 500), display: "DISPLAY-A")
        let resolved = WorkspaceLayoutService.resolvedFrame(for: placement, displays: [.primary, .right], main: .primary)
        XCTAssertTrue(LayoutDisplay.primary.visibleFrame.contains(resolved))
    }

    func testDisplayWithNilUUIDNeverMatchesAPlacementUUID() {
        let unnamed = LayoutDisplay(uuid: nil, frame: LayoutDisplay.primary.frame, visibleFrame: LayoutDisplay.primary.visibleFrame)
        let placement = makePlacement(frame: CGRect(x: 5000, y: 5000, width: 100, height: 100), display: "X")
        let resolved = WorkspaceLayoutService.resolvedFrame(for: placement, displays: [unnamed], main: unnamed)
        // Falls through to the main display clamp rather than "attached".
        XCTAssertTrue(unnamed.visibleFrame.contains(resolved))
    }

    func testResolvedFrameWithHostileFramesDoesNotTrap() {
        let frames = [
            CGRect.zero,
            CGRect(x: 1e300, y: 1e300, width: 1e300, height: 1e300),
            CGRect(x: -1e300, y: -1e300, width: -1e300, height: -1e300),
            CGRect(x: 0, y: 0, width: -10, height: -10),
        ]
        for frame in frames {
            for uuid in [nil, "DISPLAY-A", "GONE"] as [String?] {
                let placement = makePlacement(frame: frame, display: uuid)
                _ = WorkspaceLayoutService.resolvedFrame(for: placement, displays: [.primary, .right], main: .primary)
                _ = WorkspaceLayoutService.resolvedFrame(for: placement, displays: [], main: nil)
            }
        }
    }

    // MARK: - Which display a frame belongs to

    func testDisplayUUIDPicksTheDisplayWithTheLargestOverlap() {
        let displays: [LayoutDisplay] = [.primary, .right]
        XCTAssertEqual(
            WorkspaceLayoutService.displayUUID(containing: CGRect(x: 100, y: 100, width: 400, height: 300), in: displays),
            "DISPLAY-A"
        )
        XCTAssertEqual(
            WorkspaceLayoutService.displayUUID(containing: CGRect(x: 1600, y: 100, width: 400, height: 300), in: displays),
            "DISPLAY-B"
        )
    }

    func testDisplayUUIDForWindowStraddlingTheSeamUsesTheBiggerShare() {
        let displays: [LayoutDisplay] = [.primary, .right]
        // 300 of 400 points on B.
        let frame = CGRect(x: 1340, y: 100, width: 400, height: 300)
        XCTAssertEqual(WorkspaceLayoutService.displayUUID(containing: frame, in: displays), "DISPLAY-B")
    }

    func testDisplayUUIDIsNilWhenNothingOverlaps() {
        let frame = CGRect(x: 9000, y: 9000, width: 100, height: 100)
        XCTAssertNil(WorkspaceLayoutService.displayUUID(containing: frame, in: [.primary, .right]))
    }

    func testDisplayUUIDIsNilForNoDisplays() {
        XCTAssertNil(WorkspaceLayoutService.displayUUID(containing: CGRect(x: 0, y: 0, width: 10, height: 10), in: []))
    }

    func testDisplayUUIDForZeroAreaFrameIsNil() {
        XCTAssertNil(WorkspaceLayoutService.displayUUID(containing: CGRect(x: 10, y: 10, width: 0, height: 0), in: [.primary]))
    }

    func testDisplayUUIDTieGoesToTheFirstDisplayListed() {
        let left = LayoutDisplay(uuid: "L", frame: CGRect(x: 0, y: 0, width: 100, height: 100), visibleFrame: .zero)
        let right = LayoutDisplay(uuid: "R", frame: CGRect(x: 100, y: 0, width: 100, height: 100), visibleFrame: .zero)
        let frame = CGRect(x: 50, y: 0, width: 100, height: 100)
        XCTAssertEqual(WorkspaceLayoutService.displayUUID(containing: frame, in: [left, right]), "L")
        XCTAssertEqual(WorkspaceLayoutService.displayUUID(containing: frame, in: [right, left]), "R")
    }

    func testDisplayUUIDForDisplayWithoutUUIDIsNil() {
        let unnamed = LayoutDisplay(uuid: nil, frame: LayoutDisplay.primary.frame, visibleFrame: .zero)
        XCTAssertNil(WorkspaceLayoutService.displayUUID(containing: CGRect(x: 10, y: 10, width: 50, height: 50), in: [unnamed]))
    }

    func testDisplayUUIDWithHugeFrameDoesNotTrap() {
        _ = WorkspaceLayoutService.displayUUID(
            containing: CGRect(x: -1e300, y: -1e300, width: 2e300, height: 2e300),
            in: [.primary, .right]
        )
    }

    // MARK: - Matching placements to windows

    func testMatchPrefersAnExactTitle() {
        let first = FakeWindows.make(title: "Alpha")
        let second = FakeWindows.make(title: "Beta")
        let result = WorkspaceLayoutService.match([makePlacement(title: "Beta")], to: [first, second])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0]?.windowIdentifier, second.windowIdentifier)
    }

    func testMatchFallsBackToTheFirstWindowOfTheApp() {
        let first = FakeWindows.make(title: "Alpha")
        let second = FakeWindows.make(title: "Beta")
        let result = WorkspaceLayoutService.match([makePlacement(title: "Renamed Doc")], to: [first, second])
        XCTAssertEqual(result[0]?.windowIdentifier, first.windowIdentifier)
    }

    func testMatchNeverUsesOneWindowTwice() {
        let only = FakeWindows.make(title: "Same")
        let placements = [makePlacement(title: "Same"), makePlacement(title: "Same")]
        let result = WorkspaceLayoutService.match(placements, to: [only])
        XCTAssertNotNil(result[0])
        XCTAssertNil(result[1])
    }

    func testMatchSplitsIdenticalTitlesAcrossPlacementsInOrder() {
        let a = FakeWindows.make(title: "Untitled")
        let b = FakeWindows.make(title: "Untitled")
        let placements = [makePlacement(title: "Untitled"), makePlacement(title: "Untitled")]
        let result = WorkspaceLayoutService.match(placements, to: [a, b])
        XCTAssertEqual(result[0]?.windowIdentifier, a.windowIdentifier)
        XCTAssertEqual(result[1]?.windowIdentifier, b.windowIdentifier)
    }

    func testMatchReturnsNilForAppsWithNoWindows() {
        let window = FakeWindows.make(bundle: "com.other")
        let result = WorkspaceLayoutService.match([makePlacement(bundle: "com.missing")], to: [window])
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result[0])
    }

    func testMatchKeepsAppsSeparate() {
        let mail = FakeWindows.make(bundle: "com.mail", title: "Inbox")
        let notes = FakeWindows.make(bundle: "com.notes", title: "Inbox")
        let placements = [makePlacement(bundle: "com.notes", title: "Inbox"), makePlacement(bundle: "com.mail", title: "Inbox")]
        let result = WorkspaceLayoutService.match(placements, to: [mail, notes])
        XCTAssertEqual(result[0]?.windowIdentifier, notes.windowIdentifier)
        XCTAssertEqual(result[1]?.windowIdentifier, mail.windowIdentifier)
    }

    func testMatchLeavesSurplusWindowsUnclaimed() {
        let windows = (0..<5).map { FakeWindows.make(title: "W\($0)") }
        let result = WorkspaceLayoutService.match([makePlacement(title: "W3")], to: windows)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0]?.windowIdentifier, windows[3].windowIdentifier)
    }

    func testMatchPadsWithNilWhenPlacementsOutnumberWindows() {
        let windows = [FakeWindows.make(title: "A")]
        let placements = (0..<4).map { makePlacement(title: "P\($0)") }
        let result = WorkspaceLayoutService.match(placements, to: windows)
        XCTAssertEqual(result.count, 4)
        XCTAssertNotNil(result[0])
        XCTAssertEqual(result[1...].compactMap { $0 }.count, 0)
    }

    func testMatchWithNoPlacementsOrNoWindows() {
        XCTAssertTrue(WorkspaceLayoutService.match([], to: [FakeWindows.make()]).isEmpty)
        XCTAssertEqual(WorkspaceLayoutService.match([makePlacement()], to: []).count, 1)
        XCTAssertNil(WorkspaceLayoutService.match([makePlacement()], to: [])[0])
    }

    func testMatchTitleComparisonIsCaseSensitive() {
        let lower = FakeWindows.make(title: "notes")
        let upper = FakeWindows.make(title: "Notes")
        let result = WorkspaceLayoutService.match([makePlacement(title: "Notes")], to: [lower, upper])
        XCTAssertEqual(result[0]?.windowIdentifier, upper.windowIdentifier)
    }

    func testMatchTreatsCanonicallyEquivalentUnicodeTitlesAsEqual() {
        let composed = "caf\u{00E9}"
        let decomposed = "cafe\u{0301}"
        let other = FakeWindows.make(title: "Other")
        let target = FakeWindows.make(title: decomposed)
        let result = WorkspaceLayoutService.match([makePlacement(title: composed)], to: [other, target])
        XCTAssertEqual(result[0]?.windowIdentifier, target.windowIdentifier)
    }

    func testMatchWithEmptyTitleMatchesEmptyTitledWindow() {
        let named = FakeWindows.make(title: "Named")
        let empty = FakeWindows.make(title: "")
        let result = WorkspaceLayoutService.match([makePlacement(title: "")], to: [named, empty])
        XCTAssertEqual(result[0]?.windowIdentifier, empty.windowIdentifier)
    }

    func testMatchCollapsesDuplicateWindowIdentifiers() {
        // The same AX element listed twice is one window, so it can satisfy
        // only one placement.
        let element = FakeWindows.element()
        let one = FakeWindows.make(title: "Same", element: element)
        let again = FakeWindows.make(title: "Same", element: element)
        XCTAssertEqual(one.windowIdentifier, again.windowIdentifier)
        let placements = [makePlacement(title: "Same"), makePlacement(title: "Same")]
        let result = WorkspaceLayoutService.match(placements, to: [one, again])
        XCTAssertNotNil(result[0])
        XCTAssertNil(result[1])
    }

    func testMatchHandlesAHundredPlacementsAndWindows() {
        let windows = (0..<100).map { FakeWindows.make(title: "Window \($0)") }
        let placements = (0..<100).reversed().map { makePlacement(title: "Window \($0)") }
        let result = WorkspaceLayoutService.match(placements, to: windows)
        XCTAssertEqual(result.compactMap { $0 }.count, 100)
        for (index, window) in result.enumerated() {
            XCTAssertEqual(window?.windowTitle, "Window \(99 - index)")
        }
    }

    func testPositionalFallbackDoesNotStealAnotherPlacementsExactTitleMatch() {
        // "Gone" no longer has a window, so it falls back to position and
        // takes "Report", which the second placement names exactly. Exact
        // title matches should be settled before positional guesses.
        let report = FakeWindows.make(title: "Report")
        let other = FakeWindows.make(title: "Scratch")
        let placements = [makePlacement(title: "Gone"), makePlacement(title: "Report")]
        let result = WorkspaceLayoutService.match(placements, to: [report, other])
        XCTAssertEqual(result[1]?.windowIdentifier, report.windowIdentifier)
    }
}
