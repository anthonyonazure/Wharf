import XCTest
@testable import Wharf

/// Badge text is whatever an app chooses to put on its Dock tile, so every
/// rule here is exercised with hostile strings. The folder total is the sum
/// that overflowed before the clamp and wrapping add (audit finding).
final class DockBadgeTextTests: XCTestCase {

    // MARK: Normalizing the raw label

    func testNormalizedTrimsWhitespace() {
        let cases: [(String, String?)] = [
            ("5", "5"), (" 5 ", "5"), ("\t5\n", "5"), ("99+", "99+"), ("•", "•"), ("  •  ", "•"),
            ("", nil), ("   ", nil), ("\n\t\r ", nil), ("a b", "a b"), (" a  b ", "a  b"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(DockBadgeText.normalized(input), expected, input.debugDescription)
        }
    }

    func testNormalizedTrimsUnicodeWhitespace() {
        XCTAssertNil(DockBadgeText.normalized("\u{00A0}"), "no-break space")
        XCTAssertNil(DockBadgeText.normalized("\u{2003}\u{2009}"), "em and thin space")
        XCTAssertNil(DockBadgeText.normalized("\u{2028}"), "line separator")
        XCTAssertEqual(DockBadgeText.normalized("\u{00A0}7\u{00A0}"), "7")
    }

    func testZeroWidthSpaceCountsAsWhitespace() {
        // Foundation's whitespace set includes U+200B, so an "invisible"
        // badge is dropped rather than drawn as an empty pill.
        XCTAssertNil(DockBadgeText.normalized("\u{200B}"))
        XCTAssertNil(DockBadgeText.normalized(" \u{200B} "))
    }

    func testNormalizedIsLinearOnHugeInput() {
        let huge = String(repeating: "9", count: 2_000_000)
        let start = Date()
        XCTAssertEqual(DockBadgeText.normalized(" \(huge) ")?.count, 2_000_000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    // MARK: One app's count

    func testCleanIntegers() {
        let cases: [(String, Int)] = [("0", 0), ("1", 1), ("42", 42), ("99999", 99_999), ("007", 7)]
        for (text, expected) in cases {
            XCTAssertEqual(DockBadgeText.clampedCount(from: text), expected, text)
        }
    }

    func testNilAndEmptyAreZero() {
        XCTAssertEqual(DockBadgeText.clampedCount(from: nil), 0)
        XCTAssertEqual(DockBadgeText.clampedCount(from: ""), 0)
    }

    func testValuesAboveTheCeilingAreClamped() {
        let cases = ["100000", "99999999", "2147483648", "9223372036854775807"]
        for text in cases {
            XCTAssertEqual(DockBadgeText.clampedCount(from: text), 99_999, text)
        }
    }

    func testValuesBeyondIntAreZeroNotAnError() {
        // Int("9223372036854775808") is nil: treated as "no number".
        for text in ["9223372036854775808", "99999999999999999999999999", String(repeating: "9", count: 5_000)] {
            XCTAssertEqual(DockBadgeText.clampedCount(from: text), 0, String(text.prefix(30)))
        }
    }

    func testNegativeValuesAreZero() {
        for text in ["-1", "-99999", "-9223372036854775808", "-0"] {
            XCTAssertEqual(DockBadgeText.clampedCount(from: text), 0, text)
        }
    }

    func testNonNumericLabelsAreZero() {
        let labels = [
            "99+", "5+", "•", "!", "new", "NaN", "inf", "1e3", "1.5", "1,000", "0x10", "١٢٣", "५", "１２", "⑤",
            "five", " 5", "5 ", "5\n", "+", "-", "--5", "5-", "٣",
        ]
        for label in labels {
            XCTAssertEqual(DockBadgeText.clampedCount(from: label), 0, label.debugDescription)
        }
    }

    func testPlusSignedIntegerIsAccepted() {
        // Swift's Int(String) accepts a leading plus; pinned so a switch to a
        // stricter parser is a conscious choice.
        XCTAssertEqual(DockBadgeText.clampedCount(from: "+5"), 5)
        XCTAssertEqual(DockBadgeText.clampedCount(from: "+99999999"), 99_999)
    }

    func testWhitespaceMustBeStrippedBeforeCounting() {
        // The service normalizes first; the count itself does not trim.
        XCTAssertEqual(DockBadgeText.clampedCount(from: " 5"), 0)
        XCTAssertEqual(DockBadgeText.clampedCount(from: DockBadgeText.normalized(" 5 ")), 5)
    }

    // MARK: Folder totals

    func testTotalOfOrdinaryBadges() {
        XCTAssertEqual(DockBadgeText.folderTotal(of: ["3", "4", nil, "5"]), 12)
        XCTAssertEqual(DockBadgeText.folderTotal(of: []), 0)
        XCTAssertEqual(DockBadgeText.folderTotal(of: [nil, nil]), 0)
    }

    func testTotalIgnoresNonNumericAndNegativeBadges() {
        XCTAssertEqual(DockBadgeText.folderTotal(of: ["3", "99+", "•", "-50", "2"]), 5)
    }

    func testIntMaxBadgesDoNotOverflowTheTotal() {
        let maxText = String(Int.max)
        let total = DockBadgeText.folderTotal(of: Array(repeating: maxText, count: 1_000))
        XCTAssertEqual(total, 1_000 * 99_999)
    }

    func testEveryAppAtTheCeilingSumsExactly() {
        let total = DockBadgeText.folderTotal(of: Array(repeating: "99999", count: 10))
        XCTAssertEqual(total, 999_990)
    }

    func testTotalNeverTrapsEvenWithAbsurdAppCounts() {
        let total = DockBadgeText.folderTotal(of: Array(repeating: String(Int.max), count: 200_000))
        XCTAssertEqual(total, 200_000 * 99_999)
    }

    func testPerAppClampHoldsForNegativeIntMin() {
        XCTAssertEqual(DockBadgeText.folderTotal(of: [String(Int.min), "7"]), 7)
    }

    func testCeilingConstant() {
        XCTAssertEqual(DockBadgeText.perAppCeiling, 99_999)
    }

    // MARK: Folder badge text

    func testFolderBadgeTextIsNilWhenTotalIsZero() {
        XCTAssertNil(DockBadgeText.folderBadgeText(of: []))
        XCTAssertNil(DockBadgeText.folderBadgeText(of: [nil, "0", "•", "-3", "99+"]))
    }

    func testFolderBadgeTextIsTheDecimalTotal() {
        XCTAssertEqual(DockBadgeText.folderBadgeText(of: ["1", "2"]), "3")
        XCTAssertEqual(DockBadgeText.folderBadgeText(of: ["99999", "99999"]), "199998")
        XCTAssertEqual(DockBadgeText.folderBadgeText(of: [String(Int.max)]), "99999")
    }

    func testFolderBadgeTextHasNoSeparatorsOrSigns() {
        let text = DockBadgeText.folderBadgeText(of: ["99999", "99999", "99999"])
        XCTAssertEqual(text, "299997")
        XCTAssertNotNil(Int(text ?? ""))
    }

    // MARK: Attention (numeric drop)

    func testNumericDropIsNotAnAttentionSignal() {
        XCTAssertTrue(DockBadgeText.isNumericDrop(previous: "5", current: "3"))
        XCTAssertTrue(DockBadgeText.isNumericDrop(previous: "100", current: "0"))
    }

    func testNumericIncreaseAndEqualityAreNotDrops() {
        XCTAssertFalse(DockBadgeText.isNumericDrop(previous: "3", current: "5"))
        XCTAssertFalse(DockBadgeText.isNumericDrop(previous: "3", current: "3"))
    }

    func testNewBadgeIsNotADrop() {
        XCTAssertFalse(DockBadgeText.isNumericDrop(previous: nil, current: "1"))
    }

    func testNonNumericBadgesAreNeverDrops() {
        XCTAssertFalse(DockBadgeText.isNumericDrop(previous: "5", current: "•"))
        XCTAssertFalse(DockBadgeText.isNumericDrop(previous: "•", current: "5"))
        XCTAssertFalse(DockBadgeText.isNumericDrop(previous: "99+", current: "98+"))
        XCTAssertFalse(DockBadgeText.isNumericDrop(previous: "5", current: ""))
    }

    func testDropLogicHandlesExtremes() {
        XCTAssertTrue(DockBadgeText.isNumericDrop(previous: String(Int.max), current: "0"))
        XCTAssertFalse(DockBadgeText.isNumericDrop(previous: "0", current: String(Int.max)))
        XCTAssertTrue(DockBadgeText.isNumericDrop(previous: "0", current: String(Int.min)))
        XCTAssertFalse(DockBadgeText.isNumericDrop(previous: "9223372036854775808", current: "1"))
    }
}
