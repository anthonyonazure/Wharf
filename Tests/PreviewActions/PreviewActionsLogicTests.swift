//
//  PreviewActionsLogicTests.swift
//  Standalone checks for PreviewActionsLogic.swift. Built and run by
//  scripts/test-preview-actions.sh; not part of the app target.
//

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

@main
struct PreviewActionsLogicTests {
    static func main() {
        // MARK: Visible buttons

        let all = PreviewActionsSettings(showsClose: true, showsMinimize: true, showsSnapMenu: true)
        let none = PreviewActionsSettings(showsClose: false, showsMinimize: false, showsSnapMenu: false)

        expect(PreviewActionsPolicy.visibleActions(settings: all, isMinimized: false), [.snap, .minimize, .close], "all on, live window")
        expect(PreviewActionsPolicy.visibleActions(settings: all, isMinimized: true), [.restore, .close], "minimized gets restore, no snap")
        expect(PreviewActionsPolicy.visibleActions(settings: none, isMinimized: false), [], "all off shows nothing")
        expect(PreviewActionsPolicy.visibleActions(settings: none, isMinimized: true), [], "all off shows nothing when minimized")

        var closeOnly = none
        closeOnly.showsClose = true
        expect(PreviewActionsPolicy.visibleActions(settings: closeOnly, isMinimized: false), [.close], "close only")

        var snapOnly = none
        snapOnly.showsSnapMenu = true
        expect(PreviewActionsPolicy.visibleActions(settings: snapOnly, isMinimized: false), [.snap], "snap only")
        expect(PreviewActionsPolicy.visibleActions(settings: snapOnly, isMinimized: true), [], "snap hidden on a minimized window")

        var minimizeOnly = none
        minimizeOnly.showsMinimize = true
        expect(PreviewActionsPolicy.visibleActions(settings: minimizeOnly, isMinimized: true), [.restore], "minimize switch also governs restore")

        // MARK: Snap choices

        expect(PreviewActionsPolicy.snapChoices(displayCount: 1), [.leftHalf, .rightHalf, .maximize], "one display has no Next Display")
        expect(PreviewActionsPolicy.snapChoices(displayCount: 2), [.leftHalf, .rightHalf, .maximize, .nextDisplay], "two displays add Next Display")
        expect(PreviewActionsPolicy.snapChoices(displayCount: 0), [.leftHalf, .rightHalf, .maximize], "zero displays is safe")

        // MARK: Outcomes

        expect(PreviewActionsPolicy.outcome(after: .close, succeeded: true), .removeCard, "closed window drops its card")
        expect(PreviewActionsPolicy.outcome(after: .minimize, succeeded: true), .removeCard, "minimized window drops its card")
        expect(PreviewActionsPolicy.outcome(after: .restore, succeeded: true), .dismissPreview, "restore goes to the window")
        expect(PreviewActionsPolicy.outcome(after: .snap, succeeded: true), .dismissPreview, "snap goes to the window")
        for action in PreviewCardAction.allCases {
            expect(PreviewActionsPolicy.outcome(after: action, succeeded: false), .keepCard, "failed \(action) leaves the card")
        }

        // MARK: Layout menu rows

        expect(LayoutMenuModel.rows(layouts: [], canUndo: false), [.empty, .divider, .save], "empty list still offers save")
        expect(
            LayoutMenuModel.rows(layouts: [("b", "Work"), ("a", "Home")], canUndo: true),
            [.restore(id: "b", title: "Work"), .restore(id: "a", title: "Home"), .divider, .save, .undo],
            "keeps the user's order and adds undo"
        )
        expect(LayoutMenuModel.restoreTitle("Work", launchesMissingApps: false), "Work", "plain title")
        expect(LayoutMenuModel.restoreTitle("Work", launchesMissingApps: true), "Work and Open Missing Apps", "launch title")

        // MARK: Save names

        expect(LayoutMenuModel.suggestedName(existing: []), "Layout 1", "first suggestion")
        expect(LayoutMenuModel.suggestedName(existing: ["Layout 1", "layout 2", "Work"]), "Layout 3", "skips taken numbers, ignoring case")
        expect(LayoutMenuModel.suggestedName(existing: ["Layout 2"]), "Layout 1", "reuses a free low number")

        expect(LayoutMenuModel.validatedName("  Work  "), "Work", "trims")
        expect(LayoutMenuModel.validatedName("   \n"), nil, "blank is refused")
        expect(LayoutMenuModel.validatedName(String(repeating: "a", count: 80))?.count, 60, "long names are cut")
        expect(LayoutMenuModel.validatedName("abc def", maxLength: 4), "abc", "cut does not leave a trailing space")

        check(LayoutMenuModel.replacesExisting("Work", existing: ["Work", "Home"]), "exact name replaces")
        check(!LayoutMenuModel.replacesExisting("work", existing: ["Work"]), "capture matches names exactly, so a case change is a new layout")

        if failed == 0 {
            print("PASS: \(passed) checks")
            exit(0)
        } else {
            print("FAILED: \(failed) of \(passed + failed) checks")
            exit(1)
        }
    }
}
