//
//  CommandBarCoreTests.swift
//  Wharf
//
//  Standalone checks for Docky/Services/CommandBarCore.swift (calculator,
//  unit conversion, ranking). Compiled with the core file and
//  WindowSnapGeometry.swift into a small executable by
//  scripts/test-command-bar.sh. A watchdog thread fails the run if anything
//  hangs.
//

import Foundation

private var failures = 0
private var checks = 0
private let posix = Locale(identifier: "en_US_POSIX")

private func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL line \(line): \(message)")
    }
}

private func calc(_ input: String) -> Double? {
    CommandBarCalculator.value(of: input, locale: posix)
}

private func expectCalc(_ input: String, _ expected: Double, line: Int = #line) {
    let value = calc(input)
    expect(value.map { abs($0 - expected) <= max(1e-9, abs(expected) * 1e-12) } ?? false,
           "\(input) should be \(expected), got \(String(describing: value))", line: line)
}

private func expectNoCalc(_ input: String, line: Int = #line) {
    let value = calc(input)
    expect(value == nil, "\(input.prefix(40)) should not evaluate, got \(String(describing: value))", line: line)
}

/// Runs `body` and fails if it takes longer than `limit` seconds.
private func expectFast(_ label: String, limit: TimeInterval = 0.05, line: Int = #line, _ body: () -> Void) {
    let start = Date()
    body()
    let elapsed = Date().timeIntervalSince(start)
    expect(elapsed < limit, "\(label) took \(elapsed)s", line: line)
}

// MARK: - Calculator

private func testArithmetic() {
    expectCalc("1+2", 3)
    expectCalc("2 + 3 * 4", 14)
    expectCalc("(2 + 3) * 4", 20)
    expectCalc("10 / 4", 2.5)
    expectCalc("2^10", 1024)
    expectCalc("2**10", 1024)
    expectCalc("2^3^2", 512)
    expectCalc("-2^2", -4)
    expectCalc("2^-1", 0.5)
    expectCalc("--1+0", 1)
    expectCalc("50%", 0.5)
    expectCalc("200 * 15%", 30)
    expectCalc("0.1 + 0.2", 0.30000000000000004)
    expectCalc("sqrt(16)", 4)
    expectCalc("sqrt(2)^2", 2.0000000000000004)
    expectCalc("abs(-3)", 3)
    expectCalc("floor(2.7) + ceil(2.1)", 5)
    expectCalc("2 * pi", 2 * Double.pi)
    expectCalc("e^1", M_E)
    expectCalc("1,000 * 2", 2000)
    expectCalc("1,234,567 + 1", 1234568)
    expectCalc("3 \u{00D7} 4", 12)
    expectCalc("8 \u{00F7} 2", 4)
    expectCalc("5 \u{2212} 7", -2)
    expectCalc("2*(3+4", 14)
    expectCalc("[1+1]*3", 6)
    expectCalc("1.5e3 + 1", 1501)
    expectCalc("6 * 7 =", 42)
    expectCalc("log(1000)", 3)
    expectCalc("ln(e)", 1)
    expectCalc("0 * -1", 0)

    // Not calculations: plain numbers and words stay with the search.
    expectNoCalc("42")
    expectNoCalc("-5")
    expectNoCalc("safari")
    expectNoCalc("left half")
    expectNoCalc("2 apples")
    expectNoCalc("1 2")
    expectNoCalc("e")
    expectNoCalc("pi")

    let formatted = CommandBarCalculator.evaluate("0.1 + 0.2", locale: posix)?.formatted
    expect(formatted == "0.3", "0.1 + 0.2 should display 0.3, got \(String(describing: formatted))")
    let big = CommandBarCalculator.evaluate("1000 * 1000", locale: posix)?.formatted
    expect(big == "1000000" || big == "1,000,000", "grouping, got \(String(describing: big))")
}

private func testHostileCalculator() {
    let hostile: [String] = [
        "1/0", "0/0", "-1/0", "1/(1-1)", "5 % 0 / 0",
        "9^9^9^9", "2^999999", "10^309", "(-8)^(1/3)", "1e999", "1e-999 / 0",
        "sqrt(-1)", "ln(0)", "log(-1)", "asin(2)", "exp(1000)",
        "", " ", "\n\t", "+", "-", "*", "/", "^", "%%%%", "1+", "*1", "1**", "1***2",
        ".", "..", "1..2", "1.2.3", "()", "(", ")", ")))))", "(((((", "((((( 1",
        "1 + ) 2", "sqrt", "sqrt()", "sqrt 4", "sin(", "foo(1)", "1 + x",
        "NaN", "nan + 1", "inf * 0", "infinity", "1e", "1e+", "e1e1e1",
        "\u{0000}", "1\u{0000}+1", "💥+1", "١+١", "1 + 1 ; rm", "$(1+1)",
        "1,,000 + 1", ",5+1", "1,5 + 1", "1,50 * 2", "1,0000 + 1", "1.5,000 + 1",
    ]
    for input in hostile {
        expectFast("calc \(input.debugDescription)") {
            expectNoCalc(input)
        }
    }

    // Long and deep inputs: must refuse quickly, never overflow the stack.
    let deepOpen = String(repeating: "(", count: 5000)
    let deepSqrt = String(repeating: "sqrt(", count: 1000) + "4"
    let manyPlus = String(repeating: "1+", count: 10_000) + "1"
    let manySigns = String(repeating: "-", count: 5000) + "1"
    let hugeNumber = String(repeating: "9", count: 10_000) + "+1"
    let nested40 = String(repeating: "(", count: 40) + "1+1" + String(repeating: ")", count: 40)
    let signs40 = String(repeating: "-", count: 40) + "1+0"
    for input in [deepOpen, deepSqrt, manyPlus, manySigns, hugeNumber, nested40, signs40] {
        expectFast("long input of \(input.count)") {
            expectNoCalc(input)
        }
    }
    // Moderate nesting still works.
    expectCalc(String(repeating: "(", count: 10) + "1+1" + String(repeating: ")", count: 10), 2)
    expectCalc(String(repeating: "-", count: 10) + "1+0", 1)

    // Random junk: whatever comes back must be finite, and fast.
    var generator = SplitMix(seed: 0xC0FFEE)
    let alphabet = Array("0123456789+-*/^%().e pi sqrt(,")
    expectFast("10k random expressions", limit: 5) {
        var nonFinite = 0
        for _ in 0..<10_000 {
            let length = Int(generator.next() % 40)
            let input = String((0..<length).map { _ in alphabet[Int(generator.next() % UInt64(alphabet.count))] })
            if let value = calc(input), !value.isFinite { nonFinite += 1 }
        }
        expect(nonFinite == 0, "random expressions produced \(nonFinite) non-finite results")
    }
}

private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - Units

private func expectUnit(_ input: String, _ expected: Double, symbol: String, line: Int = #line) {
    let result = CommandBarUnits.convert(input, locale: posix)
    expect(result.map { abs($0.value - expected) <= abs(expected) * 1e-6 + 1e-9 && $0.unitSymbol == symbol } ?? false,
           "\(input) should be \(expected) \(symbol), got \(String(describing: result))", line: line)
}

private func testUnits() {
    expectUnit("100 km to mi", 62.137119, symbol: "mi")
    expectUnit("100km to mi", 62.137119, symbol: "mi")
    expectUnit("20 c to f", 68, symbol: "°F")
    expectUnit("-40 f in c", -40, symbol: "°C")
    expectUnit("0 c to k", 273.15, symbol: "K")
    expectUnit("5 gb to mb", 5000, symbol: "MB")
    expectUnit("1 gib to mib", 1024, symbol: "MiB")
    expectUnit("2 lb to kg", 0.90718474, symbol: "kg")
    expectUnit("5 in to cm", 12.7, symbol: "cm")
    expectUnit("90 min to h", 1.5, symbol: "h")
    expectUnit("1 gal to l", 3.785412, symbol: "L")
    expectUnit("60 mph to km/h", 96.56064, symbol: "km/h")
    expectUnit("1 acre to sqft", 43560, symbol: "sq ft")
    expectUnit("1,000 m to km", 1, symbol: "km")
    expectUnit("2.5 FEET TO INCHES", 30, symbol: "in")

    let refused = [
        "5 km to kg", "20 c to mi", "1 gb to h", "km to mi", "100 km", "100 km mi",
        "100 km to", "100 km to parsecs", "100 zz to mi", "100 km to mi to ft",
        "", "to", "1e999 km to mi", "99999999999999999999 km to mi", "--5 km to mi",
        "nan km to mi", "1,5 km to mi", ",5 km to mi", "100 km \u{0000} mi", String(repeating: "9", count: 500) + " km to mi",
    ]
    for input in refused {
        expectFast("units \(input.prefix(30))") {
            let result = CommandBarUnits.convert(input, locale: posix)
            expect(result == nil, "\(input.prefix(40)) should not convert, got \(String(describing: result))")
        }
    }
}

// MARK: - Ranking

private struct Item {
    let title: String
    let keywords: [String]
    var key: String { "test:\(title)" }
}

private func ranked(_ items: [Item], _ query: String, recency: CommandBarRecency = CommandBarRecency(), limit: Int = 10) -> [String] {
    CommandBarRanking.rank(
        items,
        query: query,
        limit: limit,
        recency: recency,
        now: Date(timeIntervalSince1970: 1_000_000),
        title: \.title,
        keywords: \.keywords,
        key: \.key
    ).map(\.title)
}

private func testRanking() {
    let s: (String, String) -> Int? = { CommandBarRanking.matchScore(query: $0, text: $1) }
    expect(s("safari", "Safari")! > s("saf", "Safari")!, "exact beats prefix")
    expect(s("saf", "Safari")! > s("saf", "Open Safari Window")!, "prefix beats word prefix")
    expect(s("vsc", "Visual Studio Code") == 500, "initials match")
    expect(s("studio", "Visual Studio Code") == 600, "word prefix")
    expect(s("udio", "Visual Studio Code") == 400, "substring")
    expect(s("vscd", "Visual Studio Code") == 100, "subsequence")
    expect(s("xyz", "Safari") == nil, "no match")
    expect(s("", "Safari") == nil, "empty query matches nothing")
    expect(s("cafe", "Café") == 1000, "diacritics fold")
    expect(s("half left", "Left Half") == 550, "words in any order")
    expect(s(String(repeating: "a", count: 100_000), "aaa") == nil, "huge query is safe")

    let apps = ["Safari", "System Settings", "Slack", "Sublime Text", "Notes", "Numbers"]
        .map { Item(title: $0, keywords: []) }
    expect(ranked(apps, "s").first == "Slack", "the shortest prefix match comes first")
    expect(ranked(apps, "s").prefix(2) == ["Slack", "Safari"], "then the next shortest")
    expect(ranked(apps, "sl").first == "Slack", "prefix ranks first")
    expect(ranked(apps, "no") == ["Notes"], "only matches returned")
    expect(ranked(apps, "s", limit: 2).count == 2, "limit respected")
    expect(ranked(apps, "s", limit: 0).isEmpty, "zero limit")
    expect(ranked(apps, "").isEmpty, "empty query without history is empty")

    var recency = CommandBarRecency()
    let now = Date(timeIntervalSince1970: 1_000_000)
    for _ in 0..<5 { recency.record("test:Sublime Text", at: now) }
    expect(ranked(apps, "s", recency: recency).first == "Sublime Text", "recency lifts an equal prefix match")
    expect(ranked(apps, "", recency: recency) == ["Sublime Text"], "empty query shows recents")
    expect(ranked(apps, "slack", recency: recency).first == "Slack", "exact still beats recency")
    expect(recency.bonus(for: "test:Sublime Text", now: now) == 150, "bonus is frequency plus freshness")
    expect(recency.bonus(for: "test:Sublime Text", now: now.addingTimeInterval(86_400 * 365)) < 60, "bonus decays")

    var bounded = CommandBarRecency()
    for index in 0..<(CommandBarRecency.limit + 50) {
        bounded.record("k\(index)", at: now.addingTimeInterval(Double(index)))
    }
    expect(bounded.entries.count == CommandBarRecency.limit, "recency is bounded")
    expect(bounded.entries["k0"] == nil && bounded.entries["k249"] != nil, "oldest entries dropped")

    // Window snapping phrases resolve to the right action.
    let snapTitles = WindowSnapAction.allCases.map { Item(title: $0.title, keywords: ["snap", "window", $0.group.title]) }
    expect(ranked(snapTitles, "left half").first == "Left Half", "left half snaps left")
    expect(ranked(snapTitles, "max").first == "Maximize", "max finds maximize")
    expect(ranked(snapTitles, "top right").first == "Top Right", "top right corner")
    expect(ranked(snapTitles, "next disp").first == "Next Display", "next display")
}

// MARK: - Review fixes

private let german = Locale(identifier: "de_DE")

private func testNumberParsing() {
    // Grouping that cannot be a real group, or that follows the decimal point.
    for input in ["1.2,345 + 1", "1,2.345 + 1", "1234,567 + 1", "1,23 + 1", "12,3456 + 1", "1,234.5,6 + 1"] {
        expectNoCalc(input)
        expect(CommandBarCalculator.value(of: input, locale: german) == nil, "\(input) refused in de_DE")
    }
    expect(CommandBarUnits.convert("1.2,345 m to cm", locale: posix) == nil, "converter refuses grouping after the decimal point")
    expect(CommandBarUnits.convert("1,2.345 m to cm", locale: posix) == nil, "converter refuses a broken group")
    expectCalc("1,234.5 + 0", 1234.5)

    // Where the comma is the decimal mark, a comma can never silently scale a value.
    expect(CommandBarCalculator.value(of: "1,234 + 1", locale: german) == nil, "1,234 is ambiguous in de_DE")
    expect(CommandBarCalculator.evaluation(of: "1,234 + 1", locale: german) == .ambiguous, "and is reported as ambiguous")
    expect(CommandBarCalculator.evaluation(of: "1.234 + 1", locale: german) == .ambiguous, "a dot grouping is ambiguous in de_DE")
    expect(CommandBarCalculator.evaluation(of: "1,5 + 1", locale: german) == .ambiguous, "any comma is ambiguous in de_DE")
    expect(CommandBarCalculator.evaluation(of: "1,234 apples", locale: german) == nil, "not math stays a search, not an ambiguity")
    expect(CommandBarCalculator.value(of: "0.125 + 1", locale: german) == 1.125, "a leading zero cannot be a group")
    expect(CommandBarCalculator.value(of: "1.5 + 1", locale: german) == 2.5, "one or two fraction digits are not ambiguous")
    expect(CommandBarUnits.convert("1,234 m to cm", locale: german) == nil, "converter refuses 1,234 in de_DE")
    expect(CommandBarUnits.conversion(of: "1,234 m to cm", locale: german) == .ambiguous, "and reports it")
    expect(CommandBarUnits.conversion(of: "1,234 zz to cm", locale: german) == nil, "unknown unit is not a conversion at all")
    expectUnit("1,234 m to cm", 123_400, symbol: "cm")
}

private func testQueryLimits() {
    let combining = "a" + String(repeating: "\u{0301}", count: 2_000_000)
    expect(combining.count == 1, "one grapheme")
    var clamped = ""
    expectFast("clamp a huge grapheme", limit: 2) { clamped = CommandBarQueryLimit.clamp(combining) }
    expect(clamped.unicodeScalars.count <= CommandBarQueryLimit.maximumScalars, "scalar cap")
    expect(clamped.utf8.count <= CommandBarQueryLimit.maximumBytes, "byte cap")
    let emoji = String(repeating: "\u{1F600}", count: 1000)
    expect(CommandBarQueryLimit.clamp(emoji).utf8.count <= CommandBarQueryLimit.maximumBytes, "four byte scalars are capped by bytes")
    expect(CommandBarQueryLimit.clamp("safari") == "safari", "short queries pass unchanged")
    expectFast("rank with a huge grapheme", limit: 1) {
        let items = (0..<500).map { Item(title: "Item \($0)", keywords: ["keyword \($0)"]) }
        _ = ranked(items, combining)
    }
    expectFast("calculator with a huge grapheme", limit: 1) { expectNoCalc(combining) }
    expectFast("units with a huge grapheme", limit: 1) {
        expect(CommandBarUnits.convert(combining + " km to mi", locale: posix) == nil, "huge unit input refused")
    }
}

private func testDestructive() {
    for title in ["Quit Safari", "Force Quit\u{2026}", "Log Out Anthony...", "Delete", "Move to Trash", "Empty Trash\u{2026}",
                  "Erase", "Shut Down\u{2026}", "Restart\u{2026}", "Sign Out", "Close All", "Revert To Saved", "Clear History"] {
        expect(CommandBarSafety.isDestructive(title), "\(title) is destructive")
    }
    for title in ["New Window", "Copy", "Paste", "Show Sidebar", "Quietly Save", "Deleted Items Folder View", "Save", ""] {
        expect(!CommandBarSafety.isDestructive(title), "\(title) is not destructive")
    }
}

private func testSelection() {
    typealias Row = CommandBarSelection.Row
    let safe = Row(id: "window:notes", isDefaultable: true)
    let delete = Row(id: "menu:delete", isDefaultable: false)
    let other = Row(id: "app:x", isDefaultable: true)
    expect(CommandBarSelection.resolve(previousID: nil, rows: [delete, safe]) == safe.id, "a destructive top row is never the default")
    expect(CommandBarSelection.resolve(previousID: safe.id, rows: [delete, other, safe]) == safe.id,
           "a late result above the selection does not move it")
    expect(CommandBarSelection.resolve(previousID: "gone", rows: [delete, other]) == other.id, "a vanished selection falls to the first safe row")
    expect(CommandBarSelection.resolve(previousID: nil, rows: [delete]) == nil, "nothing is selected when every row is destructive")
    expect(CommandBarSelection.resolve(previousID: delete.id, rows: [safe, delete]) == delete.id, "an explicit choice is kept")
    expect(CommandBarSelection.resolve(previousID: nil, rows: []) == nil, "empty")
}

private func decodeRecency(_ json: String) -> CommandBarRecency? {
    try? JSONDecoder().decode(CommandBarRecency.self, from: Data(json.utf8))
}

private func testRecencyValidation() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    guard var hostile = decodeRecency("""
    {"entries":{"app:min":{"count":-9223372036854775808,"lastUsed":0},
                "app:max":{"count":9223372036854775807,"lastUsed":0},
                "menu:com.x:File > Open Recent > Secret.pdf":{"count":3,"lastUsed":0},
                "\(String(repeating: "k", count: 5000))":{"count":1,"lastUsed":0}}}
    """) else {
        expect(false, "hostile history should decode")
        return
    }
    expect(hostile.entries["app:min"]?.count == 0, "negative count clamped")
    expect(hostile.entries["app:max"]?.count == CommandBarRecency.maximumCount, "huge count clamped")
    expect(!hostile.entries.keys.contains { $0.hasPrefix("menu:") }, "stored menu paths are dropped on load")
    expect(hostile.entries.count == 2, "overlong key dropped")
    expect(hostile.bonus(for: "app:min", now: now) >= 0, "bonus on a clamped minimum")
    expect(hostile.bonus(for: "app:max", now: now) <= 200, "bonus on a clamped maximum")
    hostile.record("app:max", at: now)
    expect(hostile.entries["app:max"]?.count == CommandBarRecency.maximumCount, "saturating increment")
    hostile.record("menu:anything", at: now)
    expect(hostile.entries["menu:anything"] == nil, "menu keys are never recorded")
    hostile.record(String(repeating: "x", count: 300), at: now)
    expect(hostile.entries.count == 2, "overlong keys are never recorded")

    let many = (0..<500).map { "\"app:\($0)\":{\"count\":1,\"lastUsed\":\($0)}" }.joined(separator: ",")
    let capped = decodeRecency("{\"entries\":{\(many)}}")
    expect(capped?.entries.count == CommandBarRecency.limit, "decoded history is capped at the limit")
    expect(capped?.entries["app:499"] != nil && capped?.entries["app:0"] == nil, "the newest entries are the ones kept")

    var roundTrip = CommandBarRecency()
    roundTrip.record("app:com.apple.Safari", at: now)
    let data = try? JSONEncoder().encode(roundTrip)
    expect(data.flatMap { try? JSONDecoder().decode(CommandBarRecency.self, from: $0) } == roundTrip, "round trip keeps entries")
}

private func testFileFilter() {
    let roots = ["/Users/me", "/Applications"]
    let excluded = ["/Users/me/Library"]
    let allowed = { CommandBarFileFilter.isAllowed(path: $0, roots: roots, excluded: excluded) }
    expect(allowed("/Users/me/Documents/tax.pdf"), "a document at home")
    expect(allowed("/Applications/Utilities/readme.txt"), "under Applications")
    expect(!allowed("/Users/me/.ssh/id_rsa"), "hidden folder")
    expect(!allowed("/Users/me/Documents/.secret"), "hidden file")
    expect(!allowed("/Users/me/Library/Mail/x.emlx"), "excluded Library")
    expect(!allowed("/Users/meanwhile/file.txt"), "a sibling with the same prefix")
    expect(!allowed("/Users/other/file.txt"), "another account")
    expect(!allowed("/Volumes/Share/file.txt"), "a mounted volume")
    expect(!allowed("/Users/me/../other/file.txt"), "dot dot is refused")
    expect(!allowed("relative/file.txt"), "relative path")
}

// MARK: - Run

@main
enum CommandBarCoreTests {
    static func main() {
        let watchdog = Thread {
            Thread.sleep(forTimeInterval: 20)
            print("FAIL: tests did not finish within 20 seconds (hang)")
            exit(1)
        }
        watchdog.start()

        testArithmetic()
        testHostileCalculator()
        testUnits()
        testRanking()
        testNumberParsing()
        testQueryLimits()
        testDestructive()
        testSelection()
        testRecencyValidation()
        testFileFilter()

        if failures == 0 {
            print("PASS: \(checks) checks")
            exit(0)
        } else {
            print("FAILED: \(failures) of \(checks) checks")
            exit(1)
        }
    }
}
