//
//  LocationWeatherStore.swift
//  Docky
//

import Combine
import Foundation

/// Presence of `latitude` + `longitude` means "use this fixed location"; absence means "use device location".
enum WeatherWidgetSettingsKey {
    static let locationName = "weather.locationName"
    static let latitude = "weather.latitude"
    static let longitude = "weather.longitude"
    /// Absent means follow the locale (see `WeatherTemperatureUnitSelection`).
    static let temperatureUnit = "weather.temperatureUnit"

    static func temperatureUnitSelection(from settings: WidgetSettings) -> WeatherTemperatureUnitSelection {
        WeatherTemperatureUnitSelection(rawValue: settings.string(temperatureUnit) ?? "") ?? .automatic
    }
}

enum WeatherTemperatureUnitSelection: String {
    case automatic
    case celsius
    case fahrenheit

    func resolved(baseline: WeatherTemperatureUnit) -> WeatherTemperatureUnit {
        switch self {
        case .automatic: baseline
        case .celsius: .celsius
        case .fahrenheit: .fahrenheit
        }
    }
}

struct ConfiguredWeatherLocation: Equatable {
    let latitude: Double
    let longitude: Double
    let name: String?
}

extension WeatherWidgetSettingsKey {
    static func configuredLocation(from settings: WidgetSettings) -> ConfiguredWeatherLocation? {
        guard let lat = settings.double(WeatherWidgetSettingsKey.latitude),
              let lon = settings.double(WeatherWidgetSettingsKey.longitude) else {
            return nil
        }
        return ConfiguredWeatherLocation(
            latitude: lat,
            longitude: lon,
            name: settings.string(WeatherWidgetSettingsKey.locationName)
        )
    }
}

/// Deliberately not `@MainActor` isolated to match `WeatherService`'s publish-from-Task pattern; only handed out and observed on the main thread.
final class ConfiguredWeatherModel: ObservableObject {
    let latitude: Double
    let longitude: Double
    let locationName: String?

    @Published private(set) var snapshot: WeatherSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var lastErrorDescription: String?

    private var lastRefreshDate: Date?
    private var pendingRefreshTask: Task<Void, Never>?

    /// Test seams: the network fetch and the clock. Production uses the defaults.
    typealias Fetch = @Sendable (_ latitude: Double, _ longitude: Double, _ locationName: String?) async throws -> WeatherSnapshot
    private let fetch: Fetch
    private let now: () -> Date

    init(
        latitude: Double,
        longitude: Double,
        locationName: String?,
        fetch: @escaping Fetch = { latitude, longitude, name in
            try await WeatherService.fetchSnapshot(forLatitude: latitude, longitude: longitude, locationName: name)
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.locationName = locationName
        self.fetch = fetch
        self.now = now
    }

    /// Fetches only if the cached snapshot is missing or stale (15 min).
    func ensureFreshWeather() {
        refresh(force: false)
    }

    func refresh(force: Bool) {
        guard !isLoading else {
            return
        }

        if !force,
           let lastRefreshDate,
           now().timeIntervalSince(lastRefreshDate) < 900,
           snapshot != nil {
            return
        }

        isLoading = true
        lastErrorDescription = nil

        pendingRefreshTask?.cancel()
        pendingRefreshTask = Task { [weak self] in
            guard let self else { return }

            do {
                let snapshot = try await self.fetch(self.latitude, self.longitude, self.locationName)
                if !Task.isCancelled {
                    self.snapshot = snapshot
                    self.lastRefreshDate = self.now()
                    self.lastErrorDescription = nil
                }
            } catch is CancellationError {
                // Fall through so isLoading is reset below; returning here
                // would leave the model refusing every later refresh.
            } catch {
                // Keep any previously loaded snapshot visible on a transient failure.
                self.lastErrorDescription = "Couldn’t load weather."
            }

            self.isLoading = false
        }
    }
}

/// Keyed by rounded coordinate so two widgets pinned to the same city share a single fetch.
final class LocationWeatherStore {
    static let shared = LocationWeatherStore()

    private var models: [String: ConfiguredWeatherModel] = [:]

    init() {}

    func model(for location: ConfiguredWeatherLocation) -> ConfiguredWeatherModel {
        let key = Self.cacheKey(latitude: location.latitude, longitude: location.longitude)
        if let existing = models[key] {
            return existing
        }
        let model = ConfiguredWeatherModel(
            latitude: location.latitude,
            longitude: location.longitude,
            locationName: location.name
        )
        models[key] = model
        return model
    }

    /// Rounded to two decimals (~1 km) so effectively-identical city picks coalesce onto one model.
    static func cacheKey(latitude: Double, longitude: Double) -> String {
        // "%.2f" renders -0.001 as "-0.00"; fold it onto "0.00" so the two
        // sides of zero share one model.
        func component(_ value: Double) -> String {
            let text = String(format: "%.2f", value)
            return text == "-0.00" ? "0.00" : text
        }
        return "\(component(latitude)),\(component(longitude))"
    }
}
