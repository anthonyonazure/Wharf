//
//  GreenButtonReviewTests.swift
//  Standalone checks for the green button fixes from the chunk 1 code
//  review re-check. Built and run by scripts/test-window-behavior.sh as its
//  own program; not part of the app target.
//

import CoreGraphics
import Foundation

var passed = 0
var failed = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if condition() {
        passed += 1
    } else {
        failed += 1
        print("FAIL line \(line): \(message)")
    }
}

func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String, line: Int = #line) {
    check(actual == expected, "\(message): got \(actual), expected \(expected)", line: line)
}

func window(_ id: UInt32, pid: Int32, _ rect: CGRect, layer: Int = 0, alpha: Double = 1) -> [String: Any] {
    [
        kCGWindowNumber as String: NSNumber(value: id),
        kCGWindowOwnerPID as String: NSNumber(value: pid),
        kCGWindowLayer as String: NSNumber(value: layer),
        kCGWindowAlpha as String: NSNumber(value: alpha),
        kCGWindowBounds as String: rect.dictionaryRepresentation as NSDictionary,
    ]
}

@main
struct GreenButtonReviewTests {
    static func main() {
        let own: Int32 = 1
        let app: Int32 = 50
        let appFrame = CGRect(x: 100, y: 100, width: 800, height: 600)
        let greenPoint = CGPoint(x: 170, y: 112)

        // Item 5: Wharf's own mouse-transparent panel (the quit protection
        // HUD) over a green button no longer ends the scan.
        let hud = window(900, pid: own, CGRect(x: 120, y: 90, width: 300, height: 80), layer: 25)
        let list = [hud, window(7, pid: app, appFrame)]
        check(TrafficLightHitTest.candidate(in: list, at: greenPoint, button: .zoom, ownProcessID: own) == nil,
              "an unknown overlay still ends the scan")
        expect(TrafficLightHitTest.candidate(in: list, at: greenPoint, button: .zoom, ownProcessID: own,
                                             ignoredWindowIDs: [900])?.windowID, 7,
               "a known click-through Wharf panel is seen through")
        expect(TrafficLightHitTest.frontWindow(in: list, at: greenPoint, ownProcessID: own, ignoredWindowIDs: [900])?.windowID, 7,
               "frontWindow skips ignored windows too")
        // An ignored id never makes a window behind an ordinary one win.
        let covered = [window(8, pid: 60, CGRect(x: 120, y: 90, width: 400, height: 400)), window(7, pid: app, appFrame)]
        expect(TrafficLightHitTest.frontWindow(in: covered, at: greenPoint, ownProcessID: own, ignoredWindowIDs: [900])?.windowID, 8,
               "an ordinary window in front still wins")

        // Item 3: a failed snap is no action only when the frame is readable
        // and unchanged.
        let before = CGRect(x: 0, y: 0, width: 500, height: 400)
        expect(GreenButtonLogic.outcome(succeeded: true, before: before, after: nil), .completed, "success")
        expect(GreenButtonLogic.outcome(succeeded: false, before: before, after: before), .noAction, "unchanged")
        expect(GreenButtonLogic.outcome(succeeded: false, before: before, after: before.offsetBy(dx: 0.5, dy: 0)), .noAction,
               "sub point jitter is unchanged")
        expect(GreenButtonLogic.outcome(succeeded: false, before: before, after: before.offsetBy(dx: 40, dy: 0)), .partialOrUnknown,
               "moved but size refused is partial")
        expect(GreenButtonLogic.outcome(succeeded: false, before: before, after: CGRect(x: 0, y: 0, width: 600, height: 400)),
               .partialOrUnknown, "resized is partial")
        expect(GreenButtonLogic.outcome(succeeded: false, before: before, after: nil), .partialOrUnknown, "unreadable after")
        expect(GreenButtonLogic.outcome(succeeded: false, before: nil, after: before), .partialOrUnknown, "unreadable before")

        // Item 1: replay only onto the exact original window and control.
        func may(_ id: UInt32?, _ bounds: CGRect?, hit: Bool = true) -> Bool {
            GreenButtonLogic.mayReplay(frontWindowID: id, frontBounds: bounds, targetWindowID: 7, targetBounds: appFrame, hitIsOnButton: hit)
        }
        check(may(7, appFrame), "same window, same place, on the button")
        check(!may(8, appFrame), "a different window in front cancels")
        check(!may(nil, nil), "nothing ordinary in front cancels")
        check(!may(7, appFrame.offsetBy(dx: 30, dy: 0)), "the window moved: cancel")
        check(!may(7, CGRect(x: 100, y: 100, width: 700, height: 600)), "the window resized: cancel")
        check(!may(7, appFrame, hit: false), "a different control under the point cancels")

        // Item 4: late work is dropped after a newer press or a shutdown.
        check(GreenButtonLogic.isCurrent(clickGeneration: 2, clickSerial: 9, generation: 2, serial: 9, enabled: true), "current")
        check(!GreenButtonLogic.isCurrent(clickGeneration: 2, clickSerial: 9, generation: 2, serial: 10, enabled: true), "newer press")
        check(!GreenButtonLogic.isCurrent(clickGeneration: 2, clickSerial: 9, generation: 3, serial: 9, enabled: true), "tap rebuilt")
        check(!GreenButtonLogic.isCurrent(clickGeneration: 2, clickSerial: 9, generation: 2, serial: 9, enabled: false), "switched off")

        // Item 2: the replay guard, independent of the event marker.
        var guardian = GreenButtonReplayGuard()
        let p = CGPoint(x: 170, y: 112)
        check(guardian.shouldReplay(serial: 1, point: p, now: 10), "first replay of a press")
        check(!guardian.shouldReplay(serial: 1, point: p, now: 10.01), "a press is replayed at most once")
        check(guardian.isOwnReplay(point: CGPoint(x: 171, y: 113), now: 10.02), "the replay is recognized near its point")
        check(!guardian.isOwnReplay(point: p, now: 10.03), "a token is spent once")
        check(guardian.shouldReplay(serial: 2, point: p, now: 11), "next press")
        check(!guardian.isOwnReplay(point: p, now: 11.6), "a token expires")
        check(guardian.shouldReplay(serial: 3, point: p, now: 11.7), "third")
        check(!guardian.isOwnReplay(point: CGPoint(x: 400, y: 400), now: 11.71), "a press elsewhere is the user's")
        check(guardian.shouldReplay(serial: 4, point: p, now: 11.8), "fourth")
        check(!guardian.shouldReplay(serial: 5, point: p, now: 11.9), "a fifth replay within two seconds is refused")
        check(guardian.shouldReplay(serial: 6, point: p, now: 12.1), "the oldest one aged out")
        check(!guardian.shouldReplay(serial: 7, point: p, now: 12.2), "a burst of replays stops replaying")
        check(guardian.shouldReplay(serial: 8, point: p, now: 14.5), "replays resume after the burst window")

        // A simulated loop where both the marker and the token failed: each
        // round the replay is swallowed again under a new serial. The burst
        // cap ends it within a handful of rounds.
        var looping = GreenButtonReplayGuard()
        var rounds = 0
        var serial = 100
        var now: TimeInterval = 50
        while looping.shouldReplay(serial: serial, point: p, now: now), rounds < 1000 {
            rounds += 1
            serial += 1
            now += 0.001
        }
        check(rounds <= GreenButtonReplayGuard.burstLimit, "a replay loop is cut off after at most \(GreenButtonReplayGuard.burstLimit) rounds, ran \(rounds)")

        print("Green button review checks: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
