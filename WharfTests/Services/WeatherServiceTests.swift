import CoreLocation
import XCTest
@testable import Wharf

/// Weather decoding, request construction and display text. The network is
/// replaced by `StubURLProtocol`; a non-empty location name is always passed
/// so reverse geocoding (which would hit the network) is never reached.
final class WeatherServiceTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Fixtures

    private static let isoFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        return formatter
    }()

    /// ISO date strings for `today + offset`, matching how the service parses them.
    private func dateString(daysFromToday offset: Int) -> String {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: Date())
        let date = calendar.date(byAdding: .day, value: offset, to: today)!
        return Self.isoFormatter.string(from: date)
    }

    /// Builds an Open-Meteo shaped body from raw JSON literals so hostile
    /// values (`1e308`, `null`, quoted strings) can be spelled exactly.
    private func body(
        temperature: String = "18.4",
        weatherCode: String = "0",
        isDay: String = "1",
        time: [String]? = nil,
        highs: [String] = ["21.2", "22.0", "19.5", "18.0", "20.1", "23.3"],
        lows: [String] = ["11.0", "12.5", "10.1", "9.4", "10.8", "13.0"],
        codes: [String] = ["0", "1", "3", "61", "71", "95"]
    ) -> Data {
        let times = time ?? (0..<6).map { "\"\(dateString(daysFromToday: $0))\"" }
        let json = """
        {
          "latitude": 37.77, "longitude": -122.42, "timezone": "America/Los_Angeles",
          "current": {"time": "2026-10-12T10:00", "interval": 900,
                      "temperature_2m": \(temperature), "weather_code": \(weatherCode), "is_day": \(isDay)},
          "daily": {"time": [\(times.joined(separator: ","))],
                    "temperature_2m_max": [\(highs.joined(separator: ","))],
                    "temperature_2m_min": [\(lows.joined(separator: ","))],
                    "weather_code": [\(codes.joined(separator: ","))]}
        }
        """
        return Data(json.utf8)
    }

    private func fetch(
        _ data: Data,
        status: Int = 200,
        name: String? = "Testville",
        units: WeatherUnits = .metric
    ) async throws -> WeatherSnapshot {
        StubURLProtocol.install { _ in .init(status: status, body: data) }
        return try await WeatherService.fetchSnapshot(
            latitude: 37.77,
            longitude: -122.42,
            locationName: name,
            units: units,
            session: StubURLProtocol.makeSession()
        )
    }

    // MARK: - Decoding a well-formed payload

    func testDecodesRealShapedPayload() async throws {
        let snapshot = try await fetch(body())
        XCTAssertEqual(snapshot.locationName, "Testville")
        XCTAssertEqual(snapshot.temperature, 18.4, accuracy: 0.0001)
        XCTAssertEqual(snapshot.highTemperature, 21.2)
        XCTAssertEqual(snapshot.lowTemperature, 11.0)
        XCTAssertEqual(snapshot.symbolName, "sun.max.fill")
        XCTAssertEqual(snapshot.conditionDescription, "Clear")
    }

    func testForecastKeepsOnlyFutureDays() async throws {
        let snapshot = try await fetch(body())
        // Six daily entries starting today; today itself is dropped.
        XCTAssertEqual(snapshot.forecast.count, 5)
        let today = Calendar.autoupdatingCurrent.startOfDay(for: Date())
        XCTAssertTrue(snapshot.forecast.allSatisfy { $0.date > today })
    }

    func testForecastIsInSourceOrderWithMatchingTemperatures() async throws {
        let snapshot = try await fetch(body())
        XCTAssertEqual(snapshot.forecast.first?.highTemperature, 22.0)
        XCTAssertEqual(snapshot.forecast.first?.lowTemperature, 12.5)
        XCTAssertEqual(snapshot.forecast.last?.highTemperature, 23.3)
        XCTAssertEqual(snapshot.forecast.last?.lowTemperature, 13.0)
    }

    func testForecastSymbolsUseDaytimeVariant() async throws {
        let snapshot = try await fetch(body(isDay: "0"))
        // Night current conditions must not leak into the daily rows.
        XCTAssertEqual(snapshot.symbolName, "moon.stars.fill")
        XCTAssertEqual(snapshot.forecast.first?.symbolName, "cloud.sun.fill")
    }

    func testNonEmptyLocationNameIsUsedVerbatim() async throws {
        for name in ["Zurich", "München", "東京", "O'Brien \"Quoted\" <b>&amp;</b>", String(repeating: "x", count: 5_000)] {
            let snapshot = try await fetch(body(), name: name)
            XCTAssertEqual(snapshot.locationName, name)
        }
    }

    // MARK: - Condition mapping

    func testIsDayFlagSelectsNightSymbols() async throws {
        let cases: [(code: String, day: String, night: String)] = [
            ("0", "sun.max.fill", "moon.stars.fill"),
            ("1", "cloud.sun.fill", "cloud.moon.fill"),
            ("2", "cloud.sun.fill", "cloud.moon.fill"),
            ("3", "cloud.fill", "cloud.fill"),
        ]
        for item in cases {
            let day = try await fetch(body(weatherCode: item.code, isDay: "1"))
            let night = try await fetch(body(weatherCode: item.code, isDay: "0"))
            XCTAssertEqual(day.symbolName, item.day, "code \(item.code) day")
            XCTAssertEqual(night.symbolName, item.night, "code \(item.code) night")
        }
    }

    func testIsDayValuesOtherThanOneAreTreatedAsNight() async throws {
        for value in ["0", "2", "-1", "9223372036854775807"] {
            let snapshot = try await fetch(body(weatherCode: "0", isDay: value))
            XCTAssertEqual(snapshot.symbolName, "moon.stars.fill", "is_day \(value)")
        }
    }

    func testConditionDescriptionTable() {
        let expected: [Int: String] = [
            0: "Clear", 1: "Mostly Clear", 2: "Partly Cloudy", 3: "Overcast",
            45: "Fog", 48: "Fog",
            51: "Drizzle", 53: "Drizzle", 55: "Drizzle", 56: "Drizzle", 57: "Drizzle",
            61: "Rain", 63: "Rain", 65: "Rain", 66: "Rain", 67: "Rain", 80: "Rain", 81: "Rain", 82: "Rain",
            71: "Snow", 73: "Snow", 75: "Snow", 77: "Snow", 85: "Snow", 86: "Snow",
            95: "Thunderstorm", 96: "Thunderstorm", 99: "Thunderstorm",
        ]
        for (code, text) in expected {
            XCTAssertEqual(WeatherCondition.description(for: code), text, "code \(code)")
        }
    }

    func testConditionSymbolTable() {
        let expected: [Int: String] = [
            45: "cloud.fog.fill", 51: "cloud.drizzle.fill", 61: "cloud.rain.fill",
            80: "cloud.rain.fill", 71: "cloud.snow.fill", 86: "cloud.snow.fill",
            95: "cloud.bolt.rain.fill", 99: "cloud.bolt.rain.fill", 3: "cloud.fill",
        ]
        for (code, symbol) in expected {
            XCTAssertEqual(WeatherCondition.symbolName(for: code, isDaylight: true), symbol, "code \(code)")
            XCTAssertEqual(WeatherCondition.symbolName(for: code, isDaylight: false), symbol, "code \(code) night")
        }
    }

    func testUnknownConditionCodesFallBackSafely() {
        for code in [-1, 4, 44, 100, 999, Int.max, Int.min] {
            XCTAssertEqual(WeatherCondition.description(for: code), "Weather")
            XCTAssertEqual(WeatherCondition.symbolName(for: code, isDaylight: true), "cloud.fill")
            XCTAssertEqual(WeatherCondition.symbolName(for: code, isDaylight: false), "cloud.fill")
        }
    }

    // MARK: - Hostile numeric payloads (the Int(Double) overflow class)

    func testHugeCurrentTemperatureIsClamped() async throws {
        let hot = try await fetch(body(temperature: "1e308"))
        XCTAssertEqual(hot.temperature, 999)
        XCTAssertEqual(hot.roundedTemperatureText, "999°")

        let cold = try await fetch(body(temperature: "-1e308"))
        XCTAssertEqual(cold.temperature, -999)
        XCTAssertEqual(cold.roundedTemperatureText, "-999°")
    }

    func testHugeDailyHighAndLowAreClamped() async throws {
        let snapshot = try await fetch(body(
            highs: ["1e308", "1e308", "1e308", "1e308", "1e308", "1e308"],
            lows: ["-1e308", "-1e308", "-1e308", "-1e308", "-1e308", "-1e308"]
        ))
        XCTAssertEqual(snapshot.highTemperature, 999)
        XCTAssertEqual(snapshot.lowTemperature, -999)
        XCTAssertEqual(snapshot.highLowText, "H:999° L:-999°")
    }

    func testHugeForecastTemperaturesAreClamped() async throws {
        // Forecast rows reach Int(_:) in the widget view, so they need the same
        // clamp as the headline temperature.
        let snapshot = try await fetch(body(
            highs: ["1e308", "1e308", "1e308", "1e308", "1e308", "1e308"],
            lows: ["-1e308", "-1e308", "-1e308", "-1e308", "-1e308", "-1e308"]
        ))
        XCTAssertFalse(snapshot.forecast.isEmpty)
        for day in snapshot.forecast {
            XCTAssertEqual(day.highTemperature, 999)
            XCTAssertEqual(day.lowTemperature, -999)
            // Mirrors the view's conversion; must not trap.
            XCTAssertEqual(Int(day.highTemperature!.rounded()), 999)
            XCTAssertEqual(Int(day.lowTemperature!.rounded()), -999)
        }
    }

    func testOverflowingJSONNumberNeverProducesNonFiniteOutput() async {
        // 1e999 is not representable. Decoding either fails or yields a value
        // that the clamp reduces to a finite number; it must never reach Int().
        do {
            let snapshot = try await fetch(body(temperature: "1e999"))
            XCTAssertTrue(snapshot.temperature.isFinite)
            XCTAssertLessThanOrEqual(abs(snapshot.temperature), 999)
            _ = snapshot.roundedTemperatureText
        } catch {
            // Rejecting the payload is also acceptable.
        }
    }

    func testNaNLiteralIsRejectedByTheDecoder() async {
        // NaN is not valid JSON; the decoder must refuse it rather than pass it on.
        do {
            _ = try await fetch(body(temperature: "NaN"))
            XCTFail("NaN should not decode")
        } catch {
            XCTAssertTrue(error is DecodingError || error is NSError)
        }
    }

    func testNullTemperatureIsRejected() async {
        do {
            _ = try await fetch(body(temperature: "null"))
            XCTFail("null temperature should not decode")
        } catch {
            XCTAssertTrue(error is DecodingError)
        }
    }

    func testStringTemperatureIsRejected() async {
        for literal in ["\"hot\"", "\"18.4\"", "true", "[]", "{}"] {
            do {
                _ = try await fetch(body(temperature: literal))
                XCTFail("temperature \(literal) should not decode")
            } catch {
                XCTAssertTrue(error is DecodingError, "\(literal)")
            }
        }
    }

    func testNullEntriesInDailyArraysAreRejected() async {
        do {
            _ = try await fetch(body(highs: ["21", "null", "19", "18", "20", "23"]))
            XCTFail("null in a [Double] should not decode")
        } catch {
            XCTAssertTrue(error is DecodingError)
        }
    }

    func testFractionalWeatherCodeIsRejected() async {
        for literal in ["1.5", "\"1\"", "1e20", "null"] {
            do {
                _ = try await fetch(body(weatherCode: literal))
                XCTFail("weather_code \(literal) should not decode")
            } catch {
                XCTAssertTrue(error is DecodingError, "\(literal)")
            }
        }
    }

    // MARK: - Structurally hostile payloads

    func testMissingCurrentBlockIsRejected() async {
        let data = Data(#"{"daily": {"time": [], "temperature_2m_max": [], "temperature_2m_min": [], "weather_code": []}}"#.utf8)
        do {
            _ = try await fetch(data)
            XCTFail("missing current should not decode")
        } catch {
            XCTAssertTrue(error is DecodingError)
        }
    }

    func testMissingDailyBlockIsRejected() async {
        let data = Data(#"{"current": {"temperature_2m": 10, "weather_code": 0, "is_day": 1}}"#.utf8)
        do {
            _ = try await fetch(data)
            XCTFail("missing daily should not decode")
        } catch {
            XCTAssertTrue(error is DecodingError)
        }
    }

    func testMissingFieldsInsideCurrentAreRejected() async {
        for current in [
            #"{"weather_code": 0, "is_day": 1}"#,
            #"{"temperature_2m": 10, "is_day": 1}"#,
            #"{"temperature_2m": 10, "weather_code": 0}"#,
            #"{}"#,
        ] {
            let data = Data(#"{"current": \#(current), "daily": {"time": [], "temperature_2m_max": [], "temperature_2m_min": [], "weather_code": []}}"#.utf8)
            do {
                _ = try await fetch(data)
                XCTFail("incomplete current \(current) should not decode")
            } catch {
                XCTAssertTrue(error is DecodingError, current)
            }
        }
    }

    func testNonJSONBodiesAreRejected() async {
        let bodies: [Data] = [
            Data(),
            Data("<html>502 Bad Gateway</html>".utf8),
            Data("null".utf8),
            Data("[]".utf8),
            Data("\"string\"".utf8),
            Data([0xFF, 0xFE, 0x00, 0x01]),
            Data(repeating: 0x7B, count: 10_000), // ten thousand open braces
        ]
        for data in bodies {
            do {
                _ = try await fetch(data)
                XCTFail("body of \(data.count) bytes should not decode")
            } catch {
                // Any thrown error is the correct outcome.
            }
        }
    }

    func testDeeplyNestedJSONDoesNotCrashTheDecoder() async {
        let depth = 2_000
        let nested = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        do {
            _ = try await fetch(Data(nested.utf8))
            XCTFail("nested arrays are not a weather payload")
        } catch {
            // Rejected without trapping.
        }
    }

    func testEmptyDailyArraysProduceSnapshotWithoutHighLow() async throws {
        let snapshot = try await fetch(body(time: [], highs: [], lows: [], codes: []))
        XCTAssertNil(snapshot.highTemperature)
        XCTAssertNil(snapshot.lowTemperature)
        XCTAssertTrue(snapshot.forecast.isEmpty)
        XCTAssertEqual(snapshot.highLowText, "")
    }

    func testMismatchedArrayLengthsUseTheShortest() async throws {
        let snapshot = try await fetch(body(
            time: (0..<6).map { "\"\(dateString(daysFromToday: $0))\"" },
            highs: ["20", "21", "22"],
            lows: ["10", "11", "12", "13", "14", "15"],
            codes: ["0", "1", "2", "3", "61"]
        ))
        // Three usable rows (indexes 0...2), index 0 is today and dropped.
        XCTAssertEqual(snapshot.forecast.count, 2)
    }

    func testUnparseableDatesAreSkippedNotFatal() async throws {
        let snapshot = try await fetch(body(
            time: [
                "\"not-a-date\"", "\"\"", "\"2026-13-45\"", "\"0000-00-00\"",
                "\"\(dateString(daysFromToday: 2))\"", "\"\(dateString(daysFromToday: 3))\"",
            ]
        ))
        XCTAssertEqual(snapshot.forecast.count, 2)
    }

    func testPastDatesAreDropped() async throws {
        let snapshot = try await fetch(body(
            time: (0..<6).map { "\"\(dateString(daysFromToday: -$0))\"" }
        ))
        XCTAssertTrue(snapshot.forecast.isEmpty)
    }

    func testHugeDailyArraysAreHandledQuickly() async throws {
        let days = 20_000
        let times = (1...days).map { "\"\(dateString(daysFromToday: $0 % 300 + 1))\"" }
        let numbers = Array(repeating: "12.5", count: days)
        let codes = Array(repeating: "2", count: days)
        let start = Date()
        let snapshot = try await fetch(body(time: times, highs: numbers, lows: numbers, codes: codes))
        XCTAssertEqual(snapshot.forecast.count, days)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testUnknownExtraFieldsAreIgnored() async throws {
        let data = Data("""
        {"extra": {"deep": [1,2,3]}, "current": {"temperature_2m": 5, "weather_code": 3, "is_day": 1, "wind": 9},
         "daily": {"time": [], "temperature_2m_max": [], "temperature_2m_min": [], "weather_code": [], "sunrise": []}}
        """.utf8)
        let snapshot = try await fetch(data)
        XCTAssertEqual(snapshot.temperature, 5)
        XCTAssertEqual(snapshot.symbolName, "cloud.fill")
    }

    func testTransportErrorsPropagate() async {
        StubURLProtocol.install { _ in .init(error: URLError(.timedOut)) }
        do {
            _ = try await WeatherService.fetchSnapshot(
                latitude: 1, longitude: 2, locationName: "X", units: .metric,
                session: StubURLProtocol.makeSession()
            )
            XCTFail("expected a transport error")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
    }

    // MARK: - Request construction

    private func components(_ url: URL?) throws -> URLComponents {
        let url = try XCTUnwrap(url)
        return try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    }

    private func query(_ components: URLComponents) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    func testForecastURLTargetsOpenMeteoOverHTTPS() throws {
        let parts = try components(WeatherService.forecastURL(latitude: 37.77, longitude: -122.42, units: .metric))
        XCTAssertEqual(parts.scheme, "https")
        XCTAssertEqual(parts.host, "api.open-meteo.com")
        XCTAssertEqual(parts.path, "/v1/forecast")
        XCTAssertNil(parts.user)
        XCTAssertNil(parts.password)
        XCTAssertNil(parts.port)
        XCTAssertNil(parts.fragment)
    }

    func testForecastURLQueryIsExactlyTheKnownSet() throws {
        let parts = try components(WeatherService.forecastURL(latitude: 1, longitude: 2, units: .us))
        let names = Set((parts.queryItems ?? []).map(\.name))
        XCTAssertEqual(names, [
            "latitude", "longitude", "current", "daily", "temperature_unit",
            "wind_speed_unit", "precipitation_unit", "timezone", "forecast_days",
        ])
        XCTAssertEqual(parts.queryItems?.count, names.count, "no duplicate query names")
    }

    func testForecastURLUnitsPerMeasurementSystem() throws {
        let expected: [(WeatherUnits, String, String, String)] = [
            (.us, "fahrenheit", "mph", "inch"),
            (.uk, "celsius", "mph", "mm"),
            (.metric, "celsius", "kmh", "mm"),
        ]
        for (units, temperature, wind, precipitation) in expected {
            let q = query(try components(WeatherService.forecastURL(latitude: 0, longitude: 0, units: units)))
            XCTAssertEqual(q["temperature_unit"], temperature)
            XCTAssertEqual(q["wind_speed_unit"], wind)
            XCTAssertEqual(q["precipitation_unit"], precipitation)
        }
    }

    func testUnitQueryValuesMatchTheEnum() {
        XCTAssertEqual(WeatherUnits.us.temperatureQueryValue, "fahrenheit")
        XCTAssertEqual(WeatherUnits.uk.temperatureQueryValue, "celsius")
        XCTAssertEqual(WeatherUnits.metric.temperatureQueryValue, "celsius")
        XCTAssertEqual(WeatherUnits.us.windSpeedQueryValue, "mph")
        XCTAssertEqual(WeatherUnits.metric.windSpeedQueryValue, "kmh")
        XCTAssertEqual(WeatherUnits.us.precipitationQueryValue, "inch")
    }

    func testForecastURLCoordinatesRoundTrip() throws {
        let samples: [(Double, Double)] = [
            (0, 0), (37.7749, -122.4194), (-33.8688, 151.2093), (90, 180), (-90, -180),
            (0.000001, -0.000001), (89.999999, 179.999999),
        ]
        for (lat, lon) in samples {
            let q = query(try components(WeatherService.forecastURL(latitude: lat, longitude: lon, units: .metric)))
            XCTAssertEqual(Double(q["latitude"] ?? ""), lat)
            XCTAssertEqual(Double(q["longitude"] ?? ""), lon)
        }
    }

    func testForecastURLCoordinatesCannotInjectQueryParameters() throws {
        // Coordinates are Doubles, so whatever value arrives, the rendered text
        // is a number and can never carry '&', '#', '/' or whitespace.
        let extremes: [Double] = [1e308, -1e308, 5e-324, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, .leastNormalMagnitude]
        for value in extremes {
            let url = try XCTUnwrap(WeatherService.forecastURL(latitude: value, longitude: value, units: .metric))
            let parts = try components(url)
            XCTAssertEqual(parts.queryItems?.count, 9, "value \(value)")
            XCTAssertEqual(parts.host, "api.open-meteo.com")
            for item in parts.queryItems ?? [] where item.name == "latitude" || item.name == "longitude" {
                let text = try XCTUnwrap(item.value)
                XCTAssertNotNil(Double(text), "\(text) should still parse as a number")
                XCTAssertFalse(text.contains("&"))
                XCTAssertFalse(text.contains("#"))
                XCTAssertFalse(text.contains(" "))
            }
        }
    }

    func testLocationNameNeverAppearsInTheRequest() async throws {
        StubURLProtocol.install { _ in .init(status: 200, body: self.body()) }
        let hostile = "x&latitude=0&evil=1#frag\n"
        _ = try await WeatherService.fetchSnapshot(
            latitude: 10, longitude: 20, locationName: hostile, units: .metric,
            session: StubURLProtocol.makeSession()
        )
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        let url = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertFalse(url.contains("evil"))
        XCTAssertFalse(url.contains("frag"))
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func testFetchSendsExactlyOneGETToTheForecastEndpoint() async throws {
        StubURLProtocol.install { _ in .init(status: 200, body: self.body()) }
        _ = try await WeatherService.fetchSnapshot(
            latitude: 10, longitude: 20, locationName: "A", units: .us,
            session: StubURLProtocol.makeSession()
        )
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.host, "api.open-meteo.com")
        XCTAssertNil(request.httpBody)
    }

    func testNonFiniteCoordinatesAreNotSentToTheAPI() throws {
        expectKnownBug("Low severity: NaN/inf coordinates are rendered as 'nan'/'inf' and sent to the remote API instead of being refused locally.")
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(
                WeatherService.forecastURL(latitude: value, longitude: 0, units: .metric),
                "latitude \(value) should not produce a request"
            )
        }
    }

    // MARK: - WeatherSnapshot

    func testSnapshotClampsTemperatures() {
        let cases: [(Double, Double)] = [
            (1e308, 999), (-1e308, -999), (1000, 999), (-1000, -999),
            (999, 999), (-999, -999), (0, 0), (18.4, 18.4),
            (.nan, 0), (.infinity, 0), (-.infinity, 0),
            (.greatestFiniteMagnitude, 999), (-.greatestFiniteMagnitude, -999),
        ]
        for (input, expected) in cases {
            let snapshot = WeatherSnapshot(
                locationName: "X", temperature: input, highTemperature: input, lowTemperature: input,
                symbolName: "cloud.fill", conditionDescription: "x"
            )
            XCTAssertEqual(snapshot.temperature, expected, "temperature \(input)")
            // Non-finite optionals drop to nil rather than 0.
            if input.isFinite {
                XCTAssertEqual(snapshot.highTemperature, expected)
                XCTAssertEqual(snapshot.lowTemperature, expected)
            } else {
                XCTAssertNil(snapshot.highTemperature)
                XCTAssertNil(snapshot.lowTemperature)
            }
        }
    }

    func testRoundedTemperatureText() {
        let cases: [(Double, String)] = [
            (0, "0°"), (0.4, "0°"), (0.5, "1°"), (-0.4, "0°"), (-0.5, "-1°"),
            (21.5, "22°"), (21.49, "21°"), (-12.5, "-13°"), (999, "999°"), (-999, "-999°"),
        ]
        for (value, text) in cases {
            let snapshot = WeatherSnapshot(
                locationName: "X", temperature: value, highTemperature: nil, lowTemperature: nil,
                symbolName: "x", conditionDescription: "x"
            )
            XCTAssertEqual(snapshot.roundedTemperatureText, text, "\(value)")
        }
    }

    func testHighLowTextShapes() {
        func text(_ high: Double?, _ low: Double?) -> String {
            WeatherSnapshot(
                locationName: "X", temperature: 0, highTemperature: high, lowTemperature: low,
                symbolName: "x", conditionDescription: "x"
            ).highLowText
        }
        XCTAssertEqual(text(21.6, 11.4), "H:22° L:11°")
        XCTAssertEqual(text(21.6, nil), "High 22°")
        XCTAssertEqual(text(nil, 11.4), "Low 11°")
        XCTAssertEqual(text(nil, nil), "")
        XCTAssertEqual(text(-5.5, -10.5), "H:-6° L:-11°")
    }

    func testSnapshotsWithSameValuesAreEqual() {
        let a = WeatherSnapshot(locationName: "A", temperature: 1, highTemperature: 2, lowTemperature: 0, symbolName: "s", conditionDescription: "c")
        let b = WeatherSnapshot(locationName: "A", temperature: 1, highTemperature: 2, lowTemperature: 0, symbolName: "s", conditionDescription: "c")
        XCTAssertEqual(a, b)
    }

    // MARK: - Unit conversion

    private func sample(_ temperature: Double, high: Double? = nil, low: Double? = nil) -> WeatherSnapshot {
        WeatherSnapshot(
            locationName: "X", temperature: temperature, highTemperature: high, lowTemperature: low,
            symbolName: "x", conditionDescription: "x",
            forecast: [WeatherForecastDay(date: Date(timeIntervalSince1970: 86_400), symbolName: "s", highTemperature: high, lowTemperature: low)]
        )
    }

    func testCelsiusToFahrenheitConversion() {
        let cases: [(Double, Double)] = [(0, 32), (100, 212), (-40, -40), (37, 98.6), (-273.15, -459.67)]
        for (celsius, fahrenheit) in cases {
            let converted = sample(celsius).converted(from: .celsius, to: .fahrenheit)
            XCTAssertEqual(converted.temperature, fahrenheit, accuracy: 0.001, "\(celsius)C")
        }
    }

    func testFahrenheitToCelsiusConversion() {
        let cases: [(Double, Double)] = [(32, 0), (212, 100), (-40, -40), (98.6, 37)]
        for (fahrenheit, celsius) in cases {
            let converted = sample(fahrenheit).converted(from: .fahrenheit, to: .celsius)
            XCTAssertEqual(converted.temperature, celsius, accuracy: 0.001, "\(fahrenheit)F")
        }
    }

    func testConversionIsIdentityWhenUnitsMatch() {
        let original = sample(21.5, high: 25, low: 15)
        XCTAssertEqual(original.converted(from: .celsius, to: .celsius), original)
        XCTAssertEqual(original.converted(from: .fahrenheit, to: .fahrenheit), original)
    }

    func testConversionRoundTripReturnsOriginal() {
        let original = sample(21.5, high: 25, low: 15)
        let there = original.converted(from: .celsius, to: .fahrenheit)
        let back = there.converted(from: .fahrenheit, to: .celsius)
        XCTAssertEqual(back.temperature, original.temperature, accuracy: 0.0001)
        XCTAssertEqual(back.highTemperature!, 25, accuracy: 0.0001)
        XCTAssertEqual(back.lowTemperature!, 15, accuracy: 0.0001)
    }

    func testConversionConvertsHighLowAndForecast() {
        let converted = sample(0, high: 10, low: -10).converted(from: .celsius, to: .fahrenheit)
        XCTAssertEqual(converted.highTemperature!, 50, accuracy: 0.0001)
        XCTAssertEqual(converted.lowTemperature!, 14, accuracy: 0.0001)
        XCTAssertEqual(converted.forecast.first?.highTemperature ?? 0, 50, accuracy: 0.0001)
        XCTAssertEqual(converted.forecast.first?.lowTemperature ?? 0, 14, accuracy: 0.0001)
    }

    func testConversionKeepsClampedRange() {
        // 999 C is 1830.2 F; the snapshot initializer must clamp it again.
        let converted = sample(999, high: 999, low: -999).converted(from: .celsius, to: .fahrenheit)
        XCTAssertEqual(converted.temperature, 999)
        XCTAssertEqual(converted.highTemperature, 999)
        XCTAssertEqual(converted.lowTemperature, -999)
        XCTAssertEqual(converted.roundedTemperatureText, "999°")
    }

    func testConversionPreservesNonTemperatureFields() {
        let original = sample(10)
        let converted = original.converted(from: .celsius, to: .fahrenheit)
        XCTAssertEqual(converted.locationName, original.locationName)
        XCTAssertEqual(converted.symbolName, original.symbolName)
        XCTAssertEqual(converted.conditionDescription, original.conditionDescription)
        XCTAssertEqual(converted.forecast.count, original.forecast.count)
    }

    // MARK: - Forecast day

    func testForecastDayClampsOutOfRangeTemperatures() {
        let day = WeatherForecastDay(date: Date(), symbolName: "s", highTemperature: 1e308, lowTemperature: -1e308)
        XCTAssertEqual(day.highTemperature, 999)
        XCTAssertEqual(day.lowTemperature, -999)
    }

    func testForecastDayDropsNonFiniteTemperatures() {
        let day = WeatherForecastDay(date: Date(), symbolName: "s", highTemperature: .nan, lowTemperature: .infinity)
        XCTAssertNil(day.highTemperature)
        XCTAssertNil(day.lowTemperature)
    }

    func testForecastDayPreservesOrdinaryValuesAndNil() {
        let day = WeatherForecastDay(date: Date(), symbolName: "s", highTemperature: 12.3, lowTemperature: nil)
        XCTAssertEqual(day.highTemperature, 12.3)
        XCTAssertNil(day.lowTemperature)
    }

    func testForecastDayIdentityFollowsDate() {
        let date = Date(timeIntervalSinceReferenceDate: 12_345)
        let day = WeatherForecastDay(date: date, symbolName: "s", highTemperature: 1, lowTemperature: 0)
        XCTAssertEqual(day.id, 12_345)
    }

    func testMakeForecastDaysAlignsOnShortestArray() {
        let daily = OpenMeteoResponse.DailyWeather(
            time: [dateString(daysFromToday: 1), dateString(daysFromToday: 2), dateString(daysFromToday: 3)],
            temperature2mMax: [1, 2],
            temperature2mMin: [0, 1, 2],
            weatherCode: [0, 0, 0]
        )
        let days = WeatherService.makeForecastDays(from: daily)
        XCTAssertEqual(days.count, 2)
    }

    // MARK: - Authorization mapping

    func testAuthorizationStatusMapping() {
        XCTAssertTrue(WeatherService.isAuthorizedStatus(.authorizedAlways))
        XCTAssertFalse(WeatherService.isAuthorizedStatus(.notDetermined))
        XCTAssertFalse(WeatherService.isAuthorizedStatus(.denied))
        XCTAssertFalse(WeatherService.isAuthorizedStatus(.restricted))
    }
}
