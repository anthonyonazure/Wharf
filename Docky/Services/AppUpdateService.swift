//
//  AppUpdateService.swift
//  Docky
//

import Combine
import Foundation
import Sparkle

private final class AppUpdateFeedDelegate: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        AppUpdateService.configuredFeedURLString
    }
}

final class AppUpdateService: ObservableObject {
    static let shared = AppUpdateService()

    /// The appcast feed, read only from Info.plist. Wharf deliberately ships
    /// without `SUFeedURL` and `SUPublicEDKey` (see Config/Info.plist), so this
    /// stays nil until the fork has its own appcast and EdDSA key pair.
    ///
    /// There is deliberately no fallback. A previous fallback pointed at
    /// upstream Docky's getdocky.com appcast, a domain this fork does not
    /// control, which silently re-armed updates against a third party and
    /// defeated the Info.plist decision it was supposed to honor (audit run-1).
    static var configuredFeedURLString: String? {
        guard let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              !feedURL.isEmpty else {
            return nil
        }
        return feedURL
    }

    static var hasConfiguredFeed: Bool { configuredFeedURLString != nil }

    @Published private(set) var canCheckForUpdates: Bool
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            guard automaticallyChecksForUpdates != oldValue else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    @Published var automaticallyDownloadsUpdates: Bool {
        didSet {
            guard automaticallyDownloadsUpdates != oldValue else { return }
            updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
        }
    }

    @Published var updateCheckInterval: TimeInterval {
        didSet {
            guard updateCheckInterval != oldValue else { return }
            updater.updateCheckInterval = updateCheckInterval
        }
    }

    let updaterController: SPUStandardUpdaterController
    private let feedDelegate: AppUpdateFeedDelegate

    private var updater: SPUUpdater {
        updaterController.updater
    }

    private var cancellables = Set<AnyCancellable>()

    private init() {
        feedDelegate = AppUpdateFeedDelegate()

        // Starting the updater with no feed makes every check fail with
        // SUInvalidFeedURLError in a user-visible dialog. Leave it unarmed
        // instead, which also disables the Check for Updates menu item.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: Self.hasConfiguredFeed,
            updaterDelegate: feedDelegate,
            userDriverDelegate: nil
        )

        let updater = updaterController.updater
        canCheckForUpdates = Self.hasConfiguredFeed && updater.canCheckForUpdates
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        updateCheckInterval = updater.updateCheckInterval

        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] canCheckForUpdates in
                self?.canCheckForUpdates = AppUpdateService.hasConfiguredFeed && canCheckForUpdates
            }
            .store(in: &cancellables)

        updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] automaticallyChecksForUpdates in
                self?.automaticallyChecksForUpdates = automaticallyChecksForUpdates
            }
            .store(in: &cancellables)

        updater.publisher(for: \.automaticallyDownloadsUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] automaticallyDownloadsUpdates in
                self?.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
            }
            .store(in: &cancellables)

        updater.publisher(for: \.updateCheckInterval)
            .receive(on: RunLoop.main)
            .sink { [weak self] updateCheckInterval in
                self?.updateCheckInterval = updateCheckInterval
            }
            .store(in: &cancellables)
    }

    func checkForUpdates() {
        guard Self.hasConfiguredFeed else { return }
        updater.checkForUpdates()
    }

    func checkForUpdatesInBackground() {
        guard Self.hasConfiguredFeed, automaticallyChecksForUpdates, canCheckForUpdates else { return }
        updater.checkForUpdatesInBackground()
    }
}
