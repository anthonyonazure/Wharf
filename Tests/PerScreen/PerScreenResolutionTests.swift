//
//  PerScreenResolutionTests.swift
//  Wharf
//
//  Standalone checks for Docky/Services/PerScreenResolution.swift, compiled
//  with that file into a small executable. Run: scripts/test-perscreen.sh
//

import Foundation

private var failures = 0
private var checks = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL line \(line): \(message)")
    }
}

private typealias R = PerScreenResolution

/// Stand-in for the app's DockWindowPosition, which lives in an AppKit file.
private enum Edge: String { case system, left, right, bottom }

private func decode(_ json: String) -> [String: DisplayOverride] {
    R.decodeOverrides(Data(json.utf8))
}

private let screenA = "AAAAAAAA-0000-0000-0000-000000000001"
private let screenB = "BBBBBBBB-0000-0000-0000-000000000002"

private func testFallbackWithNoOverride() {
    expect(R.position(override: nil, global: Edge.bottom) == .bottom, "no override uses the global edge")
    expect(R.tileSize(override: nil, global: 48) == 48, "no override uses the global size")
    expect(R.autohide(override: nil, global: true) == true, "no override uses global autohide")
    expect(decode("{}")[screenA] == nil, "a display with no entry has no override")
}

private func testOverrideWins() {
    expect(R.position(override: "left", global: Edge.bottom) == .left, "override edge wins")
    expect(R.tileSize(override: 64, global: 48) == 64, "override size wins")
    expect(R.autohide(override: false, global: true) == false, "override autohide wins, even when false")
}

private func testBadValuesFallBackPerField() {
    expect(R.position(override: "top-ish", global: Edge.right) == .right, "unknown edge name falls back")
    expect(R.position(override: "", global: Edge.right) == .right, "empty edge name falls back")
    expect(R.tileSize(override: .nan, global: 48) == 48, "NaN size falls back")
    expect(R.tileSize(override: .infinity, global: 48) == 48, "infinite size falls back")
    expect(R.tileSize(override: 4, global: 48) == 16, "tiny size is pulled up to the slider minimum")
    expect(R.tileSize(override: 900, global: 48) == 128, "huge size is pulled down to the slider maximum")
}

private func testPartialEntry() {
    let stored = decode(#"{"\#(screenA)": {"tileSize": 40}}"#)
    let entry = stored[screenA]
    expect(entry?.tileSize == 40, "partial entry keeps the field it has")
    expect(entry?.position == nil && entry?.autohide == nil, "partial entry leaves the rest unset")
    expect(R.position(override: entry?.position, global: Edge.bottom) == .bottom, "missing edge falls back")
    expect(R.autohide(override: entry?.autohide, global: true) == true, "missing autohide falls back")
}

private func testOldEntriesWithoutAutohideStillLoad() {
    let stored = decode(#"{"\#(screenA)": {"position": "left", "floatOffsetX": 12, "floatOffsetY": -3}}"#)
    expect(stored[screenA]?.position == "left", "entry saved before autohide existed still loads")
    expect(stored[screenA]?.floatOffsetX == 12, "float offset survives")
    expect(stored[screenA]?.autohide == nil, "autohide is unset on an old entry")
}

private func testCorruptFieldIsSalvaged() {
    // One field has the wrong type. The rest of that display's entry, and the
    // other display entirely, must survive.
    let stored = decode(#"""
    {
      "\#(screenA)": {"position": "right", "tileSize": "big", "autohide": 1},
      "\#(screenB)": {"position": "left", "tileSize": 52, "autohide": true}
    }
    """#)
    expect(stored[screenA]?.position == "right", "good field next to a bad one survives")
    expect(stored[screenA]?.tileSize == nil, "string tile size is dropped")
    expect(stored[screenA]?.autohide == nil, "a number is not accepted as autohide")
    expect(stored[screenB] == DisplayOverride(position: "left", tileSize: 52, autohide: true), "other display untouched")
}

private func testCorruptEntryDoesNotWipeOthers() {
    let stored = decode(#"""
    {
      "\#(screenA)": "not an object",
      "\#(screenB)": {"tileSize": 30},
      "CCCC": [1, 2, 3],
      "DDDD": {"tileSize": true, "position": 7}
    }
    """#)
    expect(stored[screenA] == nil, "a string entry is dropped")
    expect(stored["CCCC"] == nil, "an array entry is dropped")
    expect(stored["DDDD"] == nil, "an entry with nothing usable is dropped")
    expect(stored[screenB]?.tileSize == 30, "the good entry survives its corrupt neighbors")
}

private func testCorruptBlob() {
    expect(R.decodeOverrides(nil).isEmpty, "nothing stored")
    expect(R.decodeOverrides(Data("garbage".utf8)).isEmpty, "garbage bytes")
    expect(R.decodeOverrides(Data("[1,2]".utf8)).isEmpty, "a list instead of a dictionary")
    expect(R.decodeOverrides(Data(#""just text""#.utf8)).isEmpty, "a bare string")
    expect(R.decodeOverrides(Data([0xFF, 0x00, 0x7B])).isEmpty, "invalid UTF-8")
}

private func testVanishedDisplayIsHarmless() {
    // An override for a display that is no longer connected loads like any
    // other and simply is never asked for. Nothing deletes it, so it comes
    // back when the display does.
    let stored = decode(#"{"\#(screenB)": {"position": "left"}}"#)
    expect(stored[screenB]?.position == "left", "unplugged display keeps its override")
    expect(stored[screenA] == nil, "connected display without an entry gets nothing")
}

private func testRoundTripThroughStorage() throws {
    let original: [String: DisplayOverride] = [
        screenA: DisplayOverride(position: "bottom", tileSize: 72, autohide: false),
        screenB: DisplayOverride(floatOffsetX: 5, floatOffsetY: 6),
    ]
    let data = try JSONEncoder().encode(original)
    expect(R.decodeOverrides(data) == original, "what is saved is what is loaded")
}

private func testUseGlobalToggle() {
    let seeded = R.seeded(from: nil, globalPosition: "bottom", globalTileSize: 48, globalAutohide: true)
    expect(seeded == DisplayOverride(position: "bottom", tileSize: 48, autohide: true), "turning overrides on copies the global values")
    expect(seeded.hasDockSettings, "a seeded override counts as customized")

    let floating = DisplayOverride(floatOffsetX: 10, floatOffsetY: 0)
    let seededFloat = R.seeded(from: floating, globalPosition: "left", globalTileSize: 300, globalAutohide: false)
    expect(seededFloat.floatOffsetX == 10, "seeding keeps a float offset")
    expect(seededFloat.tileSize == 128, "seeding clamps a theme size outside the slider range")

    expect(R.clearingDockSettings(seeded) == nil, "back to global leaves nothing to store")
    let kept = R.clearingDockSettings(DisplayOverride(position: "left", themeIdentifier: "glass", floatOffsetX: 3))
    expect(kept == DisplayOverride(themeIdentifier: "glass", floatOffsetX: 3), "back to global keeps theme and float")
    expect(!DisplayOverride(floatOffsetX: 3).hasDockSettings, "a float offset alone is not a dock setting")
    expect(!DisplayOverride(autohide: false).isEmpty, "autohide false is still an override")
}

private func testDockMenuEditsTheRightStore() {
    expect(R.settingPosition("left", in: nil) == nil, "no override: the dock menu edits the global edge")
    expect(R.settingPosition("left", in: DisplayOverride(floatOffsetX: 3)) == nil, "float only is not customized")
    expect(R.settingAutohide(true, in: DisplayOverride(themeIdentifier: "glass")) == nil, "theme only is not customized")
    let seeded = DisplayOverride(position: "bottom", tileSize: 32, autohide: false)
    expect(R.settingPosition("left", in: seeded) == DisplayOverride(position: "left", tileSize: 32, autohide: false), "customized: edge changes, rest kept")
    expect(R.settingAutohide(true, in: seeded) == DisplayOverride(position: "bottom", tileSize: 32, autohide: true), "customized: hiding changes, rest kept")
}

private func testMagnificationUsesRestingSize() {
    expect(R.magnificationHasRoom(peakSize: 64, restingSize: 32), "global 64, override 32: still magnifies")
    expect(!R.magnificationHasRoom(peakSize: 64, restingSize: 64), "no room when peak equals resting")
    expect(!R.magnificationHasRoom(peakSize: 64, restingSize: 96), "no room when resting is larger")
}

@main
struct PerScreenResolutionTests {
    static func main() throws {
        testFallbackWithNoOverride()
        testOverrideWins()
        testBadValuesFallBackPerField()
        testPartialEntry()
        testOldEntriesWithoutAutohideStillLoad()
        testCorruptFieldIsSalvaged()
        testCorruptEntryDoesNotWipeOthers()
        testCorruptBlob()
        testVanishedDisplayIsHarmless()
        try testRoundTripThroughStorage()
        testUseGlobalToggle()
        testDockMenuEditsTheRightStore()
        testMagnificationUsesRestingSize()

        if failures == 0 {
            print("PASS: \(checks) checks")
            exit(0)
        } else {
            print("FAILED: \(failures) of \(checks) checks")
            exit(1)
        }
    }
}
