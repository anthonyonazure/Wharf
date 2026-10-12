import XCTest
@testable import Wharf

/// `DataIntegrityReporter.makeDictionary` is the shared guard that replaced
/// `Dictionary(uniqueKeysWithValues:)` after hostile plist entries with
/// duplicate GUIDs trapped the app. It must never trap and must be
/// deterministic: the first value for a key wins.
@MainActor
final class DataIntegrityReporterTests: XCTestCase {
    func testEmptyInputGivesEmptyDictionary() {
        let result = DataIntegrityReporter.makeDictionary([(String, Int)](), site: "test.empty")
        XCTAssertTrue(result.isEmpty)
    }

    func testUniqueKeysAreAllKept() {
        let result = DataIntegrityReporter.makeDictionary(
            [("a", 1), ("b", 2), ("c", 3)],
            site: "test.unique"
        )
        XCTAssertEqual(result, ["a": 1, "b": 2, "c": 3])
    }

    func testDuplicateKeyKeepsFirstValue() {
        let result = DataIntegrityReporter.makeDictionary(
            [("a", 1), ("a", 2)],
            site: "test.dup"
        )
        XCTAssertEqual(result, ["a": 1])
    }

    func testDuplicateInTheMiddleKeepsFirstAndOtherKeys() {
        let result = DataIntegrityReporter.makeDictionary(
            [("a", 1), ("b", 2), ("a", 3), ("c", 4), ("b", 5)],
            site: "test.middle"
        )
        XCTAssertEqual(result, ["a": 1, "b": 2, "c": 4])
    }

    func testAllKeysIdenticalCollapsesToFirst() {
        let pairs = (0..<50).map { ("same", $0) }
        let result = DataIntegrityReporter.makeDictionary(pairs, site: "test.same")
        XCTAssertEqual(result, ["same": 0])
    }

    func testSingleElement() {
        let result = DataIntegrityReporter.makeDictionary([("only", 7)], site: "test.single")
        XCTAssertEqual(result, ["only": 7])
    }

    func testIntegerKeys() {
        let result = DataIntegrityReporter.makeDictionary(
            [(1, "x"), (2, "y"), (1, "z")],
            site: "test.int"
        )
        XCTAssertEqual(result, [1: "x", 2: "y"])
    }

    func testStructKeys() {
        struct Key: Hashable { let a: Int; let b: String }
        let result = DataIntegrityReporter.makeDictionary(
            [(Key(a: 1, b: "x"), "first"), (Key(a: 1, b: "x"), "second"), (Key(a: 1, b: "y"), "third")],
            site: "test.struct"
        )
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[Key(a: 1, b: "x")], "first")
        XCTAssertEqual(result[Key(a: 1, b: "y")], "third")
    }

    func testEmptyStringKeyIsAValidKey() {
        let result = DataIntegrityReporter.makeDictionary([("", 1), ("", 2)], site: "test.emptykey")
        XCTAssertEqual(result, ["": 1])
    }

    func testUnicodeCanonicalEquivalenceCountsAsDuplicate() {
        // Swift String equality is canonical equivalence, so these collide.
        let composed = "caf\u{00E9}"
        let decomposed = "cafe\u{0301}"
        let result = DataIntegrityReporter.makeDictionary(
            [(composed, 1), (decomposed, 2)],
            site: "test.unicode"
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.values.first, 1)
    }

    func testLargeUniqueInput() {
        let pairs = (0..<10_000).map { ("k\($0)", $0) }
        let result = DataIntegrityReporter.makeDictionary(pairs, site: "test.large")
        XCTAssertEqual(result.count, 10_000)
        XCTAssertEqual(result["k0"], 0)
        XCTAssertEqual(result["k9999"], 9_999)
    }

    func testLargeInputWithManyDuplicates() {
        let pairs = (0..<10_000).map { ("k\($0 % 100)", $0) }
        let result = DataIntegrityReporter.makeDictionary(pairs, site: "test.largedup")
        XCTAssertEqual(result.count, 100)
        for slot in 0..<100 {
            XCTAssertEqual(result["k\(slot)"], slot, "first occurrence must win for k\(slot)")
        }
    }

    func testTilesKeyedByIdKeepFirstTile() {
        let first = Tile(id: "1", content: .spacer)
        let second = Tile(id: "1", content: .divider)
        let result = DataIntegrityReporter.makeDictionary(
            [first, second].map { ($0.id, $0) },
            site: "test.tiles"
        )
        XCTAssertEqual(result["1"], first)
    }

    func testReportDuplicateKeysWithEmptyListIsANoOp() {
        DataIntegrityReporter.reportDuplicateKeys(site: "test.report.empty", duplicates: [String]())
    }

    func testReportDuplicateKeysWithManyDuplicatesDoesNotTrap() {
        DataIntegrityReporter.reportDuplicateKeys(site: "test.report.many", duplicates: Array(0..<500))
    }
}
