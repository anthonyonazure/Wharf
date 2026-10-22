//
//  CommandBarCore.swift
//  Wharf
//
//  Pure logic for the Command Bar: the calculator, unit conversion, and the
//  ranking of results by match quality and recency.
//
//  Adapted from Vorssaint (https://github.com/vorssaint/vorssaint-utils,
//  GPL-3.0-or-later, Copyright (C) 2026 Vorssaint): the strict "only answer
//  input that is entirely math" rule of CommandBarMath and the unit lexicon
//  and same-family rule of CommandBarUnits. The parser itself is new and
//  bounded on purpose. Wharf is GPL-3.0 as well.
//
//  Foundation only, so scripts/test-command-bar.sh compiles it on its own.
//  Nothing here may crash or hang on any input: every loop consumes input or
//  stops, recursion is capped, and every value is checked for being finite.
//

import Foundation

// MARK: - Number formatting

nonisolated enum CommandBarNumberFormat {
    /// Writes a value for display, rounding away floating point noise so
    /// 0.1 + 0.2 reads as 0.3. Very large or very small values use
    /// scientific notation instead of a wall of digits.
    static func string(_ value: Double, locale: Locale = .current) -> String? {
        guard value.isFinite else { return nil }
        let rounded = significantRounded(value)
        guard rounded.isFinite else { return nil }
        let normalized = rounded == 0 ? 0 : rounded
        let magnitude = abs(normalized)

        let formatter = NumberFormatter()
        formatter.locale = locale
        if normalized != 0, magnitude >= 1e15 || magnitude < 1e-9 {
            formatter.numberStyle = .scientific
            formatter.maximumSignificantDigits = 10
            formatter.usesSignificantDigits = true
        } else {
            formatter.numberStyle = .decimal
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 10
            formatter.usesGroupingSeparator = true
        }
        return formatter.string(from: NSNumber(value: normalized))
    }

    /// The value as plain ASCII, for copying back into a field.
    static func plain(_ value: Double) -> String {
        let rounded = significantRounded(value)
        var text = String(rounded == 0 ? 0 : rounded)
        if text.hasSuffix(".0") { text.removeLast(2) }
        return text
    }

    static func significantRounded(_ value: Double) -> Double {
        guard value.isFinite, value != 0 else { return value }
        let exponent = Int(floor(log10(abs(value))))
        let decimals = 12 - exponent
        guard decimals > 0, decimals < 300 else { return value }
        let scale = pow(10.0, Double(decimals))
        guard scale.isFinite else { return value }
        let scaled = (value * scale).rounded() / scale
        return scaled.isFinite ? scaled : value
    }
}

// MARK: - Calculator

/// Evaluates arithmetic typed into the bar. Supports + - * / ^ (also ** and
/// the Unicode minus, times and divide signs), postfix percent, brackets,
/// the constants pi and e, and a few functions. Input must be entirely
/// mathematical and contain an operation, so "42" or "word 2" is never a sum.
nonisolated enum CommandBarCalculator {
    static let maximumInputLength = 200
    static let maximumTokens = 200
    static let maximumDepth = 32
    static let maximumNumberLength = 40

    struct Result: Equatable {
        let value: Double
        let formatted: String
    }

    enum Function: String, CaseIterable {
        case sqrt, abs, sin, cos, tan, asin, acos, atan, ln, log, exp, floor, ceil, round

        func apply(_ x: Double) -> Double? {
            let result: Double
            switch self {
            case .sqrt:
                guard x >= 0 else { return nil }
                result = Foundation.sqrt(x)
            case .abs: result = Swift.abs(x)
            case .sin: result = Foundation.sin(x)
            case .cos: result = Foundation.cos(x)
            case .tan: result = Foundation.tan(x)
            case .asin:
                guard (-1...1).contains(x) else { return nil }
                result = Foundation.asin(x)
            case .acos:
                guard (-1...1).contains(x) else { return nil }
                result = Foundation.acos(x)
            case .atan: result = Foundation.atan(x)
            case .ln:
                guard x > 0 else { return nil }
                result = Foundation.log(x)
            case .log:
                guard x > 0 else { return nil }
                result = Foundation.log10(x)
            case .exp: result = Foundation.exp(x)
            case .floor: result = Foundation.floor(x)
            case .ceil: result = Foundation.ceil(x)
            case .round: result = x.rounded()
            }
            return result.isFinite ? result : nil
        }
    }

    enum Token: Equatable {
        case number(Double)
        case function(Function)
        case plus, minus, times, divide, power, percent, open, close
    }

    /// What the bar shows for a calculation: an answer, or a note that a
    /// number in it could be read two ways in this locale.
    enum Evaluation: Equatable {
        case result(Result)
        case ambiguous
    }

    static func evaluate(_ input: String, locale: Locale = .current) -> Result? {
        guard case .result(let result) = evaluation(of: input, locale: locale) else { return nil }
        return result
    }

    static func evaluation(of input: String, locale: Locale = .current) -> Evaluation? {
        guard let checked = checkedValue(of: input, locale: locale) else { return nil }
        if checked.ambiguous { return .ambiguous }
        guard let formatted = CommandBarNumberFormat.string(checked.value, locale: locale) else { return nil }
        return .result(Result(value: checked.value, formatted: formatted))
    }

    /// The numeric value, or nil when the input is not a complete, finite
    /// calculation or one of its numbers is ambiguous in `locale`.
    static func value(of input: String, locale: Locale = .current) -> Double? {
        guard let checked = checkedValue(of: input, locale: locale), !checked.ambiguous else { return nil }
        return checked.value
    }

    private static func checkedValue(of input: String, locale: Locale) -> (value: Double, ambiguous: Bool)? {
        // Bounded before trimming, so a huge paste costs nothing.
        guard input.utf8.count <= CommandBarQueryLimit.maximumBytes else { return nil }
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.unicodeScalars.count <= maximumInputLength else { return nil }
        if text.hasSuffix("=") { text.removeLast() }
        guard let scanned = scan(text, locale: locale), !scanned.tokens.isEmpty else { return nil }
        var parser = Parser(tokens: scanned.tokens)
        guard let value = parser.parse(), parser.sawOperation, value.isFinite else { return nil }
        return (value == 0 ? 0 : value, scanned.ambiguous)
    }

    static func tokenize(_ text: String, locale: Locale = Locale(identifier: "en_US_POSIX")) -> [Token]? {
        scan(text, locale: locale)?.tokens
    }

    /// Tokens, plus whether any number could be read two ways. An ambiguous
    /// number still tokenizes (as the dot-decimal reading) so the caller can
    /// tell "ambiguous math" from "not math at all".
    private static func scan(_ text: String, locale: Locale) -> (tokens: [Token], ambiguous: Bool)? {
        let characters = Array(text)
        var tokens: [Token] = []
        var ambiguous = false
        var index = 0

        while index < characters.count {
            guard tokens.count <= maximumTokens else { return nil }
            let character = characters[index]

            if character.isWhitespace {
                index += 1
                continue
            }

            if character.isASCII, character.isNumber || character == "." {
                let start = index
                while index < characters.count, CommandBarNumberLiteral.isLiteralCharacter(characters[index]) {
                    index += 1
                }
                guard index - start <= maximumNumberLength else { return nil }
                let plain: String
                switch CommandBarNumberLiteral.parse(String(characters[start..<index]), locale: locale) {
                case .plain(let text):
                    plain = text
                case .ambiguous(let text):
                    plain = text
                    ambiguous = true
                case .invalid:
                    return nil
                }
                // Optional exponent: 1e5, 2.5E-3.
                var exponent = ""
                if index < characters.count, characters[index] == "e" || characters[index] == "E" {
                    var lookahead = index + 1
                    if lookahead < characters.count, characters[lookahead] == "+" || characters[lookahead] == "-" {
                        lookahead += 1
                    }
                    if lookahead < characters.count, characters[lookahead].isASCII, characters[lookahead].isNumber {
                        let exponentStart = index
                        index = lookahead
                        while index < characters.count, characters[index].isASCII, characters[index].isNumber {
                            index += 1
                        }
                        exponent = String(characters[exponentStart..<index])
                    }
                }
                guard index - start <= maximumNumberLength,
                      let number = Double(plain + exponent), number.isFinite else { return nil }
                tokens.append(.number(number))
                continue
            }

            if character.isLetter {
                let start = index
                while index < characters.count, characters[index].isLetter, index - start < 8 {
                    index += 1
                }
                let word = String(characters[start..<index]).lowercased()
                switch word {
                case "pi", "π": tokens.append(.number(Double.pi))
                case "e": tokens.append(.number(M_E))
                default:
                    guard let function = Function(rawValue: word) else { return nil }
                    tokens.append(.function(function))
                }
                continue
            }

            switch character {
            case "π": tokens.append(.number(Double.pi))
            case "+": tokens.append(.plus)
            case "-", "\u{2212}": tokens.append(.minus)
            case "*":
                if index + 1 < characters.count, characters[index + 1] == "*" {
                    tokens.append(.power)
                    index += 1
                } else {
                    tokens.append(.times)
                }
            case "\u{00D7}", "\u{22C5}": tokens.append(.times)
            case "/", "\u{00F7}": tokens.append(.divide)
            case "^": tokens.append(.power)
            case "%": tokens.append(.percent)
            case "(", "[": tokens.append(.open)
            case ")", "]": tokens.append(.close)
            default: return nil
            }
            index += 1
        }
        guard tokens.count <= maximumTokens else { return nil }
        return (tokens, ambiguous)
    }

    /// Recursive descent. Every function either consumes a token or fails,
    /// and `depth` bounds the recursion so nested brackets or long runs of
    /// signs cannot exhaust the stack.
    struct Parser {
        let tokens: [Token]
        var position = 0
        var depth = 0
        var failed = false
        private(set) var sawOperation = false

        init(tokens: [Token]) {
            self.tokens = tokens
        }

        mutating func parse() -> Double? {
            guard let value = parseExpression(), !failed else { return nil }
            // Any token left over (a stray close bracket, "2 3") is not math.
            guard position == tokens.count else { return nil }
            return value
        }

        private var current: Token? { position < tokens.count ? tokens[position] : nil }

        private mutating func enter() -> Bool {
            depth += 1
            if depth > CommandBarCalculator.maximumDepth { failed = true }
            return !failed
        }

        private mutating func leave() { depth -= 1 }

        private mutating func check(_ value: Double?) -> Double? {
            guard let value, value.isFinite else {
                failed = true
                return nil
            }
            return value
        }

        mutating func parseExpression() -> Double? {
            guard enter() else { return nil }
            defer { leave() }
            guard var value = parseTerm() else { return nil }
            while let token = current, token == .plus || token == .minus {
                position += 1
                guard let rhs = parseTerm() else { return nil }
                sawOperation = true
                guard let next = check(token == .plus ? value + rhs : value - rhs) else { return nil }
                value = next
            }
            return value
        }

        mutating func parseTerm() -> Double? {
            guard var value = parseUnary() else { return nil }
            while let token = current, token == .times || token == .divide {
                position += 1
                guard let rhs = parseUnary() else { return nil }
                sawOperation = true
                if token == .divide {
                    guard rhs != 0 else {
                        failed = true
                        return nil
                    }
                    guard let next = check(value / rhs) else { return nil }
                    value = next
                } else {
                    guard let next = check(value * rhs) else { return nil }
                    value = next
                }
            }
            return value
        }

        mutating func parseUnary() -> Double? {
            guard let token = current else { return nil }
            if token == .minus || token == .plus {
                guard enter() else { return nil }
                defer { leave() }
                position += 1
                guard let operand = parseUnary() else { return nil }
                return token == .minus ? -operand : operand
            }
            return parsePower()
        }

        /// Right associative: 2^3^2 is 2^9. The exponent may carry a sign.
        mutating func parsePower() -> Double? {
            guard let base = parsePostfix() else { return nil }
            guard current == .power else { return base }
            guard enter() else { return nil }
            defer { leave() }
            position += 1
            guard let exponent = parseUnary() else { return nil }
            sawOperation = true
            return check(pow(base, exponent))
        }

        mutating func parsePostfix() -> Double? {
            guard var value = parsePrimary() else { return nil }
            while current == .percent {
                position += 1
                sawOperation = true
                value /= 100
            }
            return value
        }

        mutating func parsePrimary() -> Double? {
            guard let token = current else { return nil }
            switch token {
            case .number(let number):
                position += 1
                return number
            case .open:
                position += 1
                guard let inner = parseExpression() else { return nil }
                // A missing close at the very end is forgiven ("2*(3+4").
                if current == .close {
                    position += 1
                } else if current != nil {
                    return nil
                }
                return inner
            case .function(let function):
                position += 1
                guard current == .open else { return nil }
                guard let argument = parsePrimary() else { return nil }
                sawOperation = true
                return check(function.apply(argument))
            default:
                return nil
            }
        }
    }
}

// MARK: - Unit conversion

/// Converts "100 km to mi", "20c in f", "5 gb to mb". Strict: a number, a
/// known unit, a word meaning "to", and another unit of the same family.
/// Converting across families is refused here, because Foundation traps
/// when two unrelated Dimension types meet.
nonisolated enum CommandBarUnits {
    static let maximumInputLength = 80
    static let maximumMagnitude = 1e15

    struct Result: Equatable {
        let value: Double
        let formatted: String
        let unitSymbol: String
    }

    enum Family: String {
        case temperature, length, mass, data, duration, volume, speed, area
    }

    struct KnownUnit {
        let family: Family
        let unit: Dimension
        let symbol: String
    }

    static let conversionWords: Set<String> = ["to", "in", "into", "as", "->", "=", "→"]

    static let lexicon: [String: KnownUnit] = {
        var map: [String: KnownUnit] = [:]
        func add(_ names: [String], _ family: Family, _ unit: Dimension, _ symbol: String) {
            for name in names { map[name] = KnownUnit(family: family, unit: unit, symbol: symbol) }
        }
        add(["c", "°c", "celsius", "centigrade"], .temperature, UnitTemperature.celsius, "°C")
        add(["f", "°f", "fahrenheit"], .temperature, UnitTemperature.fahrenheit, "°F")
        add(["k", "kelvin"], .temperature, UnitTemperature.kelvin, "K")

        add(["mm", "millimeter", "millimeters", "millimetre", "millimetres"], .length, UnitLength.millimeters, "mm")
        add(["cm", "centimeter", "centimeters", "centimetre", "centimetres"], .length, UnitLength.centimeters, "cm")
        add(["m", "meter", "meters", "metre", "metres"], .length, UnitLength.meters, "m")
        add(["km", "kilometer", "kilometers", "kilometre", "kilometres"], .length, UnitLength.kilometers, "km")
        add(["in", "inch", "inches", "\""], .length, UnitLength.inches, "in")
        add(["ft", "foot", "feet", "'"], .length, UnitLength.feet, "ft")
        add(["yd", "yard", "yards"], .length, UnitLength.yards, "yd")
        add(["mi", "mile", "miles"], .length, UnitLength.miles, "mi")
        add(["nmi", "nauticalmile", "nauticalmiles"], .length, UnitLength.nauticalMiles, "nmi")

        add(["mg", "milligram", "milligrams"], .mass, UnitMass.milligrams, "mg")
        add(["g", "gram", "grams"], .mass, UnitMass.grams, "g")
        add(["kg", "kilogram", "kilograms", "kilo", "kilos"], .mass, UnitMass.kilograms, "kg")
        add(["t", "tonne", "tonnes"], .mass, UnitMass.metricTons, "t")
        add(["oz", "ounce", "ounces"], .mass, UnitMass.ounces, "oz")
        add(["lb", "lbs", "pound", "pounds"], .mass, UnitMass.pounds, "lb")
        add(["st", "stone", "stones"], .mass, UnitMass.stones, "st")

        add(["b", "byte", "bytes"], .data, UnitInformationStorage.bytes, "B")
        add(["kb", "kilobyte", "kilobytes"], .data, UnitInformationStorage.kilobytes, "KB")
        add(["mb", "megabyte", "megabytes"], .data, UnitInformationStorage.megabytes, "MB")
        add(["gb", "gigabyte", "gigabytes"], .data, UnitInformationStorage.gigabytes, "GB")
        add(["tb", "terabyte", "terabytes"], .data, UnitInformationStorage.terabytes, "TB")
        add(["kib", "kibibyte", "kibibytes"], .data, UnitInformationStorage.kibibytes, "KiB")
        add(["mib", "mebibyte", "mebibytes"], .data, UnitInformationStorage.mebibytes, "MiB")
        add(["gib", "gibibyte", "gibibytes"], .data, UnitInformationStorage.gibibytes, "GiB")
        add(["tib", "tebibyte", "tebibytes"], .data, UnitInformationStorage.tebibytes, "TiB")

        add(["ms", "millisecond", "milliseconds"], .duration, UnitDuration.milliseconds, "ms")
        add(["s", "sec", "secs", "second", "seconds"], .duration, UnitDuration.seconds, "s")
        add(["min", "mins", "minute", "minutes"], .duration, UnitDuration.minutes, "min")
        add(["h", "hr", "hrs", "hour", "hours"], .duration, UnitDuration.hours, "h")

        add(["ml", "milliliter", "milliliters", "millilitre", "millilitres"], .volume, UnitVolume.milliliters, "mL")
        add(["l", "liter", "liters", "litre", "litres"], .volume, UnitVolume.liters, "L")
        add(["gal", "gallon", "gallons"], .volume, UnitVolume.gallons, "gal")
        add(["qt", "quart", "quarts"], .volume, UnitVolume.quarts, "qt")
        add(["pt", "pint", "pints"], .volume, UnitVolume.pints, "pt")
        add(["cup", "cups"], .volume, UnitVolume.cups, "cup")
        add(["floz", "fluidounce", "fluidounces"], .volume, UnitVolume.fluidOunces, "fl oz")
        add(["tbsp", "tablespoon", "tablespoons"], .volume, UnitVolume.tablespoons, "tbsp")
        add(["tsp", "teaspoon", "teaspoons"], .volume, UnitVolume.teaspoons, "tsp")

        add(["mph"], .speed, UnitSpeed.milesPerHour, "mph")
        add(["kph", "kmh", "km/h"], .speed, UnitSpeed.kilometersPerHour, "km/h")
        add(["m/s", "mps"], .speed, UnitSpeed.metersPerSecond, "m/s")
        add(["knot", "knots", "kn"], .speed, UnitSpeed.knots, "kn")

        add(["sqft", "ft2", "ft²"], .area, UnitArea.squareFeet, "sq ft")
        add(["sqm", "m2", "m²"], .area, UnitArea.squareMeters, "m²")
        add(["acre", "acres"], .area, UnitArea.acres, "ac")
        add(["ha", "hectare", "hectares"], .area, UnitArea.hectares, "ha")
        add(["sqmi", "mi2", "mi²"], .area, UnitArea.squareMiles, "sq mi")
        add(["sqkm", "km2", "km²"], .area, UnitArea.squareKilometers, "km²")
        return map
    }()

    enum Conversion: Equatable {
        case result(Result)
        case ambiguous
    }

    static func convert(_ input: String, locale: Locale = .current) -> Result? {
        guard case .result(let result) = conversion(of: input, locale: locale) else { return nil }
        return result
    }

    static func conversion(of input: String, locale: Locale = .current) -> Conversion? {
        // Length is checked before any trimming or case folding.
        guard input.utf8.count <= CommandBarQueryLimit.maximumBytes else { return nil }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.count <= maximumInputLength else { return nil }
        let characters = Array(trimmed.lowercased())

        // Leading number, optionally signed: "-40", "2.5", "1,000".
        var index = 0
        if index < characters.count, characters[index] == "-" || characters[index] == "\u{2212}" {
            index += 1
        }
        let numberStart = index
        while index < characters.count, CommandBarNumberLiteral.isLiteralCharacter(characters[index]) {
            index += 1
        }
        guard index > numberStart, index - numberStart <= 24 else { return nil }
        var literal: String
        var ambiguous = false
        switch CommandBarNumberLiteral.parse(String(characters[numberStart..<index]), locale: locale) {
        case .plain(let text):
            literal = text
        case .ambiguous(let text):
            literal = text
            ambiguous = true
        case .invalid:
            return nil
        }
        if numberStart > 0 { literal = "-" + literal }
        guard let value = Double(literal), value.isFinite, abs(value) <= maximumMagnitude else { return nil }

        // The rest: "<unit> <to-word> <unit>", where the first unit may be
        // glued to the number ("100km to mi").
        let words = String(characters[index...]).split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count == 3,
              conversionWords.contains(words[1]),
              let source = lexicon[words[0]],
              let destination = lexicon[words[2]],
              source.family == destination.family,
              type(of: source.unit) == type(of: destination.unit)
        else { return nil }
        if ambiguous { return .ambiguous }

        let converted = Measurement(value: value, unit: source.unit).converted(to: destination.unit).value
        guard converted.isFinite, let formatted = CommandBarNumberFormat.string(converted, locale: locale) else { return nil }
        return .result(Result(value: converted, formatted: "\(formatted) \(destination.symbol)", unitSymbol: destination.symbol))
    }
}

// MARK: - Number literals

/// One strict reader for the numbers typed into the calculator and the
/// converter. Grouping commas must form real groups (1,234,567) and never
/// follow the decimal point. Where the comma is the decimal mark, "1,234"
/// means one point two three four, so any comma is refused as ambiguous
/// there, and so is a dot followed by exactly three digits (1.234), since the
/// dot is those locales' grouping mark.
nonisolated enum CommandBarNumberLiteral {
    enum Outcome: Equatable {
        /// ASCII digits with at most one dot, ready for Double().
        case plain(String)
        /// Readable two ways; carries the reading with a dot as the decimal mark.
        case ambiguous(String)
        case invalid
    }

    static func isLiteralCharacter(_ character: Character) -> Bool {
        (character.isASCII && character.isNumber) || character == "." || character == ","
    }

    static func usesDecimalComma(_ locale: Locale) -> Bool {
        locale.decimalSeparator == ","
    }

    static func parse(_ literal: String, locale: Locale) -> Outcome {
        let characters = Array(literal)
        guard !characters.isEmpty,
              characters.allSatisfy(isLiteralCharacter),
              characters.contains(where: { $0.isNumber }),
              characters.filter({ $0 == "." }).count <= 1 else { return .invalid }

        let dot = characters.firstIndex(of: ".")
        let integer = dot.map { Array(characters[..<$0]) } ?? characters
        let fraction = dot.map { Array(characters[($0 + 1)...]) } ?? []
        // A grouping separator after the decimal point (1.2,345) is malformed.
        guard !fraction.contains(",") else { return .invalid }

        var ambiguous = false
        if integer.contains(",") {
            let groups = integer.split(separator: ",", omittingEmptySubsequences: false)
            let isGrouping = groups.first.map { (1...3).contains($0.count) } == true
                && groups.dropFirst().allSatisfy({ $0.count == 3 })
            if usesDecimalComma(locale) {
                // "1,5" is a decimal there, but the bar parses dots only, so
                // it is flagged rather than guessed at.
                if !isGrouping {
                    guard groups.count == 2, dot == nil, groups.allSatisfy({ !$0.isEmpty }) else { return .invalid }
                    return .ambiguous(String(groups[0]) + "." + String(groups[1]))
                }
                ambiguous = true
            } else if !isGrouping {
                return .invalid
            }
        } else if dot != nil, usesDecimalComma(locale),
                  fraction.count == 3, (1...3).contains(integer.count), integer.first != "0" {
            ambiguous = true
        }

        let digits = String(integer.filter { $0 != "," })
        let plain = dot == nil ? digits : digits + "." + String(fraction)
        return ambiguous ? .ambiguous(plain) : .plain(plain)
    }
}

// MARK: - Query limits

/// Caps what the bar will process, in Unicode scalars and UTF-8 bytes, before
/// any trimming or folding. A single grapheme can hold millions of combining
/// marks, so a character count alone bounds nothing.
nonisolated enum CommandBarQueryLimit {
    static let maximumScalars = 256
    static let maximumBytes = 1024

    static func clamp(_ text: String) -> String {
        if text.utf8.count <= maximumBytes, text.unicodeScalars.count <= maximumScalars { return text }
        var kept = String.UnicodeScalarView()
        var bytes = 0
        var count = 0
        for scalar in text.unicodeScalars {
            let size = scalar.value < 0x80 ? 1 : scalar.value < 0x800 ? 2 : scalar.value < 0x10000 ? 3 : 4
            guard count < maximumScalars, bytes + size <= maximumBytes else { break }
            kept.append(scalar)
            bytes += size
            count += 1
        }
        return String(kept)
    }
}

// MARK: - Safety and selection

/// Menu commands and actions that lose work or end a session. They are never
/// selected by default and need a second Return. Matches English titles only.
nonisolated enum CommandBarSafety {
    static let destructivePhrases: [[String]] = [
        ["quit"], ["force", "quit"], ["log", "out"], ["logout"], ["sign", "out"],
        ["delete"], ["erase"], ["empty", "trash"], ["move", "to", "trash"], ["shut", "down"],
        ["shutdown"], ["restart"], ["reboot"], ["remove"], ["discard"], ["uninstall"],
        ["reset"], ["revert"], ["format"], ["wipe"], ["destroy"], ["purge"], ["terminate"],
        ["kill"], ["close", "all"], ["clear"], ["overwrite"], ["replace", "all"],
    ]

    static func isDestructive(_ title: String) -> Bool {
        let cleaned = title
            .replacingOccurrences(of: "\u{2026}", with: " ")
            .replacingOccurrences(of: "...", with: " ")
        let words = CommandBarRanking.words(CommandBarRanking.normalized(String(cleaned.prefix(200)))).map(String.init)
        guard !words.isEmpty else { return false }
        return destructivePhrases.contains { phrase in
            guard phrase.count <= words.count else { return false }
            return (0...(words.count - phrase.count)).contains { start in
                Array(words[start..<(start + phrase.count)]) == phrase
            }
        }
    }
}

/// Selection follows a result's identity, not its row number, so results that
/// arrive late can never slide a different action under the user's finger.
nonisolated enum CommandBarSelection {
    struct Row: Equatable {
        let id: String
        /// False for destructive rows and rows with nothing to run.
        let isDefaultable: Bool
    }

    /// Keeps `previousID` while it is still listed; otherwise the first row
    /// that is safe to select by default, or nil when there is none.
    static func resolve(previousID: String?, rows: [Row]) -> String? {
        if let previousID, rows.contains(where: { $0.id == previousID }) { return previousID }
        return rows.first(where: \.isDefaultable)?.id
    }
}

// MARK: - File results

/// Which Spotlight hits the bar may show: under one of `roots`, outside every
/// `excluded` folder, and with no hidden (dot) component anywhere in the path.
nonisolated enum CommandBarFileFilter {
    static func isAllowed(path: String, roots: [String], excluded: [String] = []) -> Bool {
        func isInside(_ folder: String) -> Bool {
            let prefix = folder.hasSuffix("/") ? folder : folder + "/"
            return path == folder || path.hasPrefix(prefix)
        }
        guard path.hasPrefix("/"), roots.contains(where: isInside), !excluded.contains(where: isInside) else { return false }
        return !path.split(separator: "/").contains { $0.hasPrefix(".") }
    }
}

// MARK: - Ranking

/// Scores how well a title matches what was typed. Higher is better; nil
/// means no match. Exact beats prefix beats a word prefix beats initials
/// beats a substring beats letters in order.
nonisolated enum CommandBarRanking {
    static let maximumQueryLength = 200

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func words(_ text: String) -> [Substring] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    }

    /// The query clamped, folded and split once per keystroke, not once per
    /// candidate and keyword.
    struct PreparedQuery {
        let text: String
        let words: [Substring]

        init(_ raw: String) {
            let bounded = String(CommandBarQueryLimit.clamp(raw).prefix(CommandBarRanking.maximumQueryLength))
            text = CommandBarRanking.normalized(bounded)
            words = CommandBarRanking.words(text)
        }
    }

    static func matchScore(query rawQuery: String, text rawText: String) -> Int? {
        matchScore(prepared: PreparedQuery(rawQuery), text: rawText)
    }

    static func matchScore(prepared: PreparedQuery, text rawText: String) -> Int? {
        let query = prepared.text
        let text = normalized(rawText)
        guard !query.isEmpty, !text.isEmpty else { return nil }

        if text == query { return 1000 }
        if text.hasPrefix(query) {
            return 800 + max(0, 50 - (text.count - query.count))
        }
        let textWords = words(text)
        let queryWords = prepared.words
        if textWords.contains(where: { $0.hasPrefix(query) }) { return 600 }
        if queryWords.count > 1,
           queryWords.allSatisfy({ queryWord in textWords.contains { $0.hasPrefix(queryWord) } }) {
            return 550
        }
        if query.count >= 2, !query.contains(" ") {
            let initials = String(textWords.compactMap(\.first))
            if initials.hasPrefix(query) { return 500 }
        }
        if text.contains(query) { return 400 }
        if query.count >= 2, isSubsequence(query, of: text) { return 100 }
        return nil
    }

    /// The best of the title and its keywords; keywords count a little less
    /// so a real title match wins a tie.
    static func score(query: String, title: String, keywords: [String] = []) -> Int? {
        score(prepared: PreparedQuery(query), title: title, keywords: keywords)
    }

    static func score(prepared: PreparedQuery, title: String, keywords: [String] = []) -> Int? {
        var best = matchScore(prepared: prepared, text: title)
        for keyword in keywords {
            if let score = matchScore(prepared: prepared, text: keyword) {
                best = max(best ?? Int.min, score - 100)
            }
        }
        return best
    }

    static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var iterator = haystack.makeIterator()
        for character in needle where character != " " {
            var found = false
            while let next = iterator.next() {
                if next == character {
                    found = true
                    break
                }
            }
            if !found { return false }
        }
        return true
    }

    /// Sorts `items` by match score plus recency plus a per-item weight,
    /// and keeps the best `limit`. With an empty query only items with
    /// recency are returned, most recent first.
    static func rank<T>(
        _ items: [T],
        query: String,
        limit: Int,
        recency: CommandBarRecency,
        now: Date,
        title: (T) -> String,
        keywords: (T) -> [String] = { _ in [] },
        key: (T) -> String,
        weight: (T) -> Int = { _ in 0 }
    ) -> [T] {
        guard limit > 0 else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let prepared = PreparedQuery(trimmed)
        var scored: [(item: T, score: Int, title: String)] = []
        scored.reserveCapacity(items.count)
        for item in items {
            let bonus = recency.bonus(for: key(item), now: now)
            let itemTitle = title(item)
            if trimmed.isEmpty {
                guard bonus > 0 else { continue }
                scored.append((item, bonus, itemTitle))
            } else if let match = score(prepared: prepared, title: itemTitle, keywords: keywords(item)) {
                scored.append((item, match + bonus + weight(item), itemTitle))
            }
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        return scored.prefix(limit).map(\.item)
    }
}

/// How often and how recently each result was chosen. Keys are opaque
/// strings like "app:com.apple.Safari". Bounded so it never grows forever,
/// and checked on load so a damaged or hand-edited store cannot trap.
nonisolated struct CommandBarRecency: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var count: Int
        var lastUsed: Date
    }

    static let limit = 200
    static let maximumCount = 1000
    static let maximumKeyLength = 256
    /// Earlier builds stored menu paths, which can hold document names.
    static let droppedKeyPrefixes = ["menu:"]

    private(set) var entries: [String: Entry] = [:]

    private enum CodingKeys: String, CodingKey {
        case entries
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decodeIfPresent([String: Entry].self, forKey: .entries) ?? [:]
        entries = Self.sanitized(raw)
    }

    static func isAcceptableKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= maximumKeyLength && !droppedKeyPrefixes.contains(where: { key.hasPrefix($0) })
    }

    /// Valid keys only, counts clamped, dates finite, newest `limit` kept.
    static func sanitized(_ raw: [String: Entry]) -> [String: Entry] {
        var kept: [(key: String, entry: Entry)] = []
        for (key, entry) in raw where isAcceptableKey(key) && entry.lastUsed.timeIntervalSinceReferenceDate.isFinite {
            kept.append((key, Entry(count: min(max(entry.count, 0), maximumCount), lastUsed: entry.lastUsed)))
        }
        if kept.count > limit {
            kept.sort { $0.entry.lastUsed > $1.entry.lastUsed }
            kept = Array(kept.prefix(limit))
        }
        return Dictionary(kept.map { ($0.key, $0.entry) }, uniquingKeysWith: { first, _ in first })
    }

    mutating func record(_ key: String, at date: Date) {
        guard Self.isAcceptableKey(key) else { return }
        var entry = entries[key] ?? Entry(count: 0, lastUsed: date)
        // Clamped before adding, so even a stored Int.max cannot overflow.
        entry.count = min(max(entry.count, 0), Self.maximumCount - 1) + 1
        entry.lastUsed = date
        entries[key] = entry
        if entries.count > Self.limit {
            let oldest = entries.sorted { $0.value.lastUsed < $1.value.lastUsed }
                .prefix(entries.count - Self.limit)
            for (key, _) in oldest { entries.removeValue(forKey: key) }
        }
    }

    /// Up to 100 for frequency and up to 100 for how recent, so a strong
    /// text match still beats a weak one that was used yesterday.
    func bonus(for key: String, now: Date) -> Int {
        guard let entry = entries[key] else { return 0 }
        let frequency = min(max(entry.count, 0), 10) * 10
        let hours = max(0, now.timeIntervalSince(entry.lastUsed) / 3600)
        let freshness = 100 / (1 + hours / 24)
        guard freshness.isFinite else { return frequency }
        return frequency + Int(max(0, min(100, freshness)))
    }
}
