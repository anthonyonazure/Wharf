import Combine
import XCTest
@testable import Wharf

/// The per-location weather cache and the widget settings keys that feed it.
/// The model's fetch and clock are injected, so no network and no waiting on
/// real time.
final class ConfiguredWeatherModelTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    // MARK: - Harness

    /// Counts fetches and answers from a queue of results.
    private final class FetchRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(Double, Double, String?)] = []
        private var results: [Result<WeatherSnapshot, Error>] = []
        private var gate: CheckedContinuation<Void, Never>?
        private var released = false
        var blocksNextFetch = false

        var count: Int { lock.lock(); defer { lock.unlock() }; return calls.count }
        var lastCall: (Double, Double, String?)? { lock.lock(); defer { lock.unlock() }; return calls.last }

        func enqueue(_ result: Result<WeatherSnapshot, Error>) {
            lock.lock(); defer { lock.unlock() }
            results.append(result)
        }

        func fetch(_ lat: Double, _ lon: Double, _ name: String?) async throws -> WeatherSnapshot {
            lock.lock()
            calls.append((lat, lon, name))
            let shouldBlock = blocksNextFetch
            blocksNextFetch = false
            lock.unlock()

            if shouldBlock {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    lock.lock()
                    if released {
                        lock.unlock()
                        continuation.resume()
                    } else {
                        gate = continuation
                        lock.unlock()
                    }
                }
            }

            lock.lock()
            let next = results.isEmpty ? nil : results.removeFirst()
            lock.unlock()
            switch next {
            case .success(let snapshot): return snapshot
            case .failure(let error): throw error
            case nil: return ConfiguredWeatherModelTests.snapshot(temperature: 0)
            }
        }

        /// Safe to call before or after the blocked fetch reaches its gate.
        func release() {
            lock.lock()
            released = true
            let continuation = gate
            gate = nil
            lock.unlock()
            continuation?.resume()
        }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.lock(); defer { lock.unlock() }; return current }
        func advance(_ seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }
    }

    static func snapshot(temperature: Double, name: String = "Testville") -> WeatherSnapshot {
        WeatherSnapshot(
            locationName: name, temperature: temperature, highTemperature: nil, lowTemperature: nil,
            symbolName: "sun.max.fill", conditionDescription: "Clear"
        )
    }

    private func makeModel(
        recorder: FetchRecorder,
        clock: Clock,
        name: String? = "Testville"
    ) -> ConfiguredWeatherModel {
        ConfiguredWeatherModel(
            latitude: 12.5,
            longitude: -45.25,
            locationName: name,
            fetch: { lat, lon, name in try await recorder.fetch(lat, lon, name) },
            now: { clock.now }
        )
    }

    /// Waits until the model is not loading, however the refresh was triggered.
    private func waitUntilIdle(_ model: ConfiguredWeatherModel, file: StaticString = #filePath, line: UInt = #line) {
        let idle = expectation(description: "model idle")
        idle.assertForOverFulfill = false
        model.$isLoading
            .filter { !$0 }
            .sink { _ in idle.fulfill() }
            .store(in: &cancellables)
        wait(for: [idle], timeout: 5)
    }

    // MARK: - Refresh policy

    func testFirstRefreshFetchesAndPublishesSnapshot() {
        let recorder = FetchRecorder(); let clock = Clock()
        recorder.enqueue(.success(Self.snapshot(temperature: 21)))
        let model = makeModel(recorder: recorder, clock: clock)
        model.ensureFreshWeather()
        waitUntilIdle(model)
        XCTAssertEqual(recorder.count, 1)
        XCTAssertEqual(model.snapshot?.temperature, 21)
        XCTAssertNil(model.lastErrorDescription)
        XCTAssertFalse(model.isLoading)
    }

    func testFetchReceivesConfiguredCoordinatesAndName() {
        let recorder = FetchRecorder(); let clock = Clock()
        let model = makeModel(recorder: recorder, clock: clock, name: "Quito")
        model.ensureFreshWeather()
        waitUntilIdle(model)
        XCTAssertEqual(recorder.lastCall?.0, 12.5)
        XCTAssertEqual(recorder.lastCall?.1, -45.25)
        XCTAssertEqual(recorder.lastCall?.2, "Quito")
    }

    func testFreshCacheSuppressesSecondFetch() {
        let recorder = FetchRecorder(); let clock = Clock()
        let model = makeModel(recorder: recorder, clock: clock)
        model.ensureFreshWeather()
        waitUntilIdle(model)
        clock.advance(60)
        model.ensureFreshWeather()
        waitUntilIdle(model)
        XCTAssertEqual(recorder.count, 1)
    }

    func testCacheJustInsideTheWindowIsStillFresh() {
        let recorder = FetchRecorder(); let clock = Clock()
        let model = makeModel(recorder: recorder, clock: clock)
        model.ensureFreshWeather()
        waitUntilIdle(model)
        clock.advance(899.9)
        model.ensureFreshWeather()
        waitUntilIdle(model)
        XCTAssertEqual(recorder.count, 1)
    }

    func testCacheExpiresAtFifteenMinutes() {
        let recorder = FetchRecorder(); let clock = Clock()
        let model = makeModel(recorder: recorder, clock: clock)
        model.ensureFreshWeather()
        waitUntilIdle(model)
        clock.advance(900)
        model.ensureFreshWeather()
        waitUntilIdle(model)
        XCTAssertEqual(recorder.count, 2)
    }

    func testForcedRefreshIgnoresFreshness() {
        let recorder = FetchRecorder(); let clock = Clock()
        let model = makeModel(recorder: recorder, clock: clock)
        model.ensureFreshWeather()
        waitUntilIdle(model)
        model.refresh(force: true)
        waitUntilIdle(model)
        XCTAssertEqual(recorder.count, 2)
    }

    func testRefreshWhileLoadingIsIgnored() {
        let recorder = FetchRecorder(); let clock = Clock()
        recorder.blocksNextFetch = true
        let model = makeModel(recorder: recorder, clock: clock)
        model.refresh(force: false)
        XCTAssertTrue(model.isLoading)
        model.refresh(force: true)
        model.refresh(force: true)
        recorder.release()
        waitUntilIdle(model)
        XCTAssertEqual(recorder.count, 1)
    }

    func testStaleSnapshotSurvivesATransientFailure() {
        let recorder = FetchRecorder(); let clock = Clock()
        recorder.enqueue(.success(Self.snapshot(temperature: 19)))
        recorder.enqueue(.failure(URLError(.notConnectedToInternet)))
        let model = makeModel(recorder: recorder, clock: clock)
        model.ensureFreshWeather()
        waitUntilIdle(model)

        clock.advance(2_000)
        model.ensureFreshWeather()
        waitUntilIdle(model)

        XCTAssertEqual(recorder.count, 2)
        XCTAssertEqual(model.snapshot?.temperature, 19, "old data stays visible")
        XCTAssertEqual(model.lastErrorDescription, "Couldn’t load weather.")
        XCTAssertFalse(model.isLoading)
    }

    func testFailureWithoutPriorSnapshotLeavesNilAndSetsError() {
        let recorder = FetchRecorder(); let clock = Clock()
        recorder.enqueue(.failure(URLError(.timedOut)))
        let model = makeModel(recorder: recorder, clock: clock)
        model.ensureFreshWeather()
        waitUntilIdle(model)
        XCTAssertNil(model.snapshot)
        XCTAssertNotNil(model.lastErrorDescription)
        XCTAssertFalse(model.isLoading)
    }

    func testFailedFetchDoesNotStartTheFreshnessWindow() {
        let recorder = FetchRecorder(); let clock = Clock()
        recorder.enqueue(.failure(URLError(.timedOut)))
        recorder.enqueue(.success(Self.snapshot(temperature: 5)))
        let model = makeModel(recorder: recorder, clock: clock)
        model.ensureFreshWeather()
        waitUntilIdle(model)
        // No snapshot and no refresh date, so the next call retries at once.
        model.ensureFreshWeather()
        waitUntilIdle(model)
        XCTAssertEqual(recorder.count, 2)
        XCTAssertEqual(model.snapshot?.temperature, 5)
        XCTAssertNil(model.lastErrorDescription, "a later success clears the error")
    }

    func testRepeatedFailuresDoNotWedgeTheModel() {
        let recorder = FetchRecorder(); let clock = Clock()
        for _ in 0..<5 { recorder.enqueue(.failure(URLError(.badServerResponse))) }
        recorder.enqueue(.success(Self.snapshot(temperature: 3)))
        let model = makeModel(recorder: recorder, clock: clock)
        for _ in 0..<6 {
            model.refresh(force: true)
            waitUntilIdle(model)
        }
        XCTAssertEqual(recorder.count, 6)
        XCTAssertEqual(model.snapshot?.temperature, 3)
    }

    func testSnapshotFromFetchIsClampedBySnapshotInitializer() {
        let recorder = FetchRecorder(); let clock = Clock()
        recorder.enqueue(.success(Self.snapshot(temperature: 1e308)))
        let model = makeModel(recorder: recorder, clock: clock)
        model.ensureFreshWeather()
        waitUntilIdle(model)
        XCTAssertEqual(model.snapshot?.roundedTemperatureText, "999°")
    }

    func testCancellationLeavesTheModelAbleToRefresh() {
        expectKnownBug("Latent: a CancellationError (or Task cancellation) returns before isLoading is reset, so the model would refuse every later refresh. Unreachable today because refresh() never cancels while loading.")
        let recorder = FetchRecorder(); let clock = Clock()
        recorder.enqueue(.failure(CancellationError()))
        let model = makeModel(recorder: recorder, clock: clock)
        model.ensureFreshWeather()
        // Give the task a moment to run; isLoading should then be false.
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertFalse(model.isLoading)
    }
}

final class LocationWeatherStoreTests: XCTestCase {

    func testSameCoordinatesShareOneModel() {
        let store = LocationWeatherStore()
        let a = store.model(for: ConfiguredWeatherLocation(latitude: 40.7128, longitude: -74.0060, name: "NYC"))
        let b = store.model(for: ConfiguredWeatherLocation(latitude: 40.7128, longitude: -74.0060, name: "New York"))
        XCTAssertTrue(a === b)
    }

    func testCoordinatesWithinRoundingShareOneModel() {
        let store = LocationWeatherStore()
        let a = store.model(for: ConfiguredWeatherLocation(latitude: 40.7128, longitude: -74.0060, name: nil))
        let b = store.model(for: ConfiguredWeatherLocation(latitude: 40.7149, longitude: -74.0054, name: nil))
        XCTAssertTrue(a === b, "both round to 40.71,-74.01")
    }

    func testDifferentCitiesGetDifferentModels() {
        let store = LocationWeatherStore()
        let a = store.model(for: ConfiguredWeatherLocation(latitude: 40.7128, longitude: -74.0060, name: nil))
        let b = store.model(for: ConfiguredWeatherLocation(latitude: 51.5074, longitude: -0.1278, name: nil))
        XCTAssertFalse(a === b)
    }

    func testIndependentStoresDoNotShareModels() {
        let location = ConfiguredWeatherLocation(latitude: 1, longitude: 2, name: nil)
        XCTAssertFalse(LocationWeatherStore().model(for: location) === LocationWeatherStore().model(for: location))
    }

    func testCacheKeyFormat() {
        XCTAssertEqual(LocationWeatherStore.cacheKey(latitude: 40.7128, longitude: -74.0060), "40.71,-74.01")
        XCTAssertEqual(LocationWeatherStore.cacheKey(latitude: 0, longitude: 0), "0.00,0.00")
    }

    func testNonFiniteCoordinatesProduceAModelWithoutTrapping() {
        let store = LocationWeatherStore()
        for value in [Double.nan, .infinity, -.infinity, 1e308, -1e308] {
            let model = store.model(for: ConfiguredWeatherLocation(latitude: value, longitude: value, name: nil))
            XCTAssertNotNil(model)
        }
    }

    func testNegativeZeroAndPositiveZeroCoalesce() {
        // -0.001 and 0.001 are the same place to within a kilometre, but
        // "%.2f" renders them as "-0.00" and "0.00".
        expectKnownBug("Low severity: sub-0.005 negative coordinates format as '-0.00' and miss the shared model of their positive twin.")
        let store = LocationWeatherStore()
        let a = store.model(for: ConfiguredWeatherLocation(latitude: -0.001, longitude: 10, name: nil))
        let b = store.model(for: ConfiguredWeatherLocation(latitude: 0.001, longitude: 10, name: nil))
        XCTAssertTrue(a === b)
    }

    func testFirstRegisteredNameWinsForSharedModel() {
        let store = LocationWeatherStore()
        let a = store.model(for: ConfiguredWeatherLocation(latitude: 10, longitude: 10, name: "First"))
        let b = store.model(for: ConfiguredWeatherLocation(latitude: 10, longitude: 10, name: "Second"))
        XCTAssertEqual(a.locationName, "First")
        XCTAssertEqual(b.locationName, "First")
    }
}

final class WeatherWidgetSettingsKeyTests: XCTestCase {

    func testConfiguredLocationNeedsBothCoordinates() {
        XCTAssertNil(WeatherWidgetSettingsKey.configuredLocation(from: [:]))
        XCTAssertNil(WeatherWidgetSettingsKey.configuredLocation(from: [WeatherWidgetSettingsKey.latitude: .number(1)]))
        XCTAssertNil(WeatherWidgetSettingsKey.configuredLocation(from: [WeatherWidgetSettingsKey.longitude: .number(1)]))
    }

    func testConfiguredLocationReadsAllThreeValues() {
        let settings: WidgetSettings = [
            WeatherWidgetSettingsKey.latitude: .number(48.8566),
            WeatherWidgetSettingsKey.longitude: .number(2.3522),
            WeatherWidgetSettingsKey.locationName: .string("Paris"),
        ]
        XCTAssertEqual(
            WeatherWidgetSettingsKey.configuredLocation(from: settings),
            ConfiguredWeatherLocation(latitude: 48.8566, longitude: 2.3522, name: "Paris")
        )
    }

    func testConfiguredLocationNameIsOptional() {
        let settings: WidgetSettings = [
            WeatherWidgetSettingsKey.latitude: .number(1),
            WeatherWidgetSettingsKey.longitude: .number(2),
        ]
        XCTAssertNil(WeatherWidgetSettingsKey.configuredLocation(from: settings)?.name)
    }

    func testConfiguredLocationRejectsWrongValueTypes() {
        let wrongTypes: [WidgetSettings] = [
            [WeatherWidgetSettingsKey.latitude: .string("48.8"), WeatherWidgetSettingsKey.longitude: .number(2)],
            [WeatherWidgetSettingsKey.latitude: .number(48.8), WeatherWidgetSettingsKey.longitude: .bool(true)],
            [WeatherWidgetSettingsKey.latitude: .stringList(["1"]), WeatherWidgetSettingsKey.longitude: .stringList(["2"])],
        ]
        for settings in wrongTypes {
            XCTAssertNil(WeatherWidgetSettingsKey.configuredLocation(from: settings))
        }
    }

    func testTemperatureUnitSelectionParsing() {
        let cases: [(WidgetSettingValue?, WeatherTemperatureUnitSelection)] = [
            (nil, .automatic),
            (.string("automatic"), .automatic),
            (.string("celsius"), .celsius),
            (.string("fahrenheit"), .fahrenheit),
            (.string("Celsius"), .automatic),
            (.string("kelvin"), .automatic),
            (.string(""), .automatic),
            (.number(1), .automatic),
            (.bool(true), .automatic),
        ]
        for (value, expected) in cases {
            var settings: WidgetSettings = [:]
            if let value { settings[WeatherWidgetSettingsKey.temperatureUnit] = value }
            XCTAssertEqual(WeatherWidgetSettingsKey.temperatureUnitSelection(from: settings), expected)
        }
    }

    func testSelectionResolvesAgainstBaseline() {
        XCTAssertEqual(WeatherTemperatureUnitSelection.automatic.resolved(baseline: .celsius), .celsius)
        XCTAssertEqual(WeatherTemperatureUnitSelection.automatic.resolved(baseline: .fahrenheit), .fahrenheit)
        XCTAssertEqual(WeatherTemperatureUnitSelection.celsius.resolved(baseline: .fahrenheit), .celsius)
        XCTAssertEqual(WeatherTemperatureUnitSelection.fahrenheit.resolved(baseline: .celsius), .fahrenheit)
    }

    func testBaselineUnitFollowsLocaleUnits() {
        let expected: WeatherTemperatureUnit = WeatherUnits.current == .us ? .fahrenheit : .celsius
        XCTAssertEqual(WeatherService.baselineTemperatureUnit, expected)
    }
}
