//
//  PinnedDockSmartOrganizerService.swift
//  Docky
//

import AppKit
import Foundation

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, *)
@Generable
private struct SmartPinnedLayoutSuggestion {
    @Guide(description: "The organized pinned dock items in final left-to-right order.")
    var items: [SmartPinnedLayoutSuggestionItem]
}

@available(macOS 26.0, *)
@Generable
private struct SmartPinnedLayoutSuggestionItem {
    @Guide(description: "One of: app, folder, divider, spacer, widget, smartStack, launchpad.")
    var kind: String

    @Guide(description: "For app items, the bundle identifier to place.")
    var bundleIdentifier: String

    @Guide(description: "For folder items, a short natural title. Leave empty for non-folder items.")
    var title: String

    @Guide(description: "For folder items, the bundle identifiers to group. Leave empty for non-folder items.")
    var bundleIdentifiers: [String]

    @Guide(description: "For widget items, the widget kind raw value. Leave empty for non-widget items.")
    var widgetKind: String

    @Guide(description: "For widget items, the owner bundle identifier exactly as provided in the available widget list.")
    var widgetOwnerBundleIdentifier: String

    @Guide(description: "For widget items, the requested span 1 through 3.")
    var widgetSpan: Int
}
#endif

@available(macOS 26.0, *)
final class PinnedDockSmartOrganizerService {
    static let shared = PinnedDockSmartOrganizerService()

    private init() {}

    func organize(items: [PinnedTileItem]) async -> [PinnedTileItem] {
        let apps = flattenedApps(from: items)
        guard !apps.isEmpty else {
            return items
        }

        let availableWidgets = availableWidgets()
        let suggestion = await suggestedItems(apps: apps, availableWidgets: availableWidgets, existingItems: items)
        let organizedItems = sanitizedPinnedItems(
            from: suggestion,
            apps: apps,
            availableWidgets: availableWidgets,
            existingItems: items
        )

        return organizedItems.isEmpty ? items : organizedItems
    }

    private struct AvailableApp: Equatable {
        let bundleIdentifier: String
        let displayName: String
    }

    private struct AvailableWidget: Equatable {
        let kind: WidgetKind
        let ownerBundleIdentifier: String
        let defaultSpan: TileSpan
        let title: String
    }

    private enum SuggestedItem: Equatable {
        case app(String)
        case folder(title: String, bundleIdentifiers: [String])
        case divider
        case spacer
        case widget(kind: WidgetKind, ownerBundleIdentifier: String, span: TileSpan)
        case smartStack
        case launchpad
    }

    private func flattenedApps(from items: [PinnedTileItem]) -> [AvailableApp] {
        var seen: Set<String> = []
        var result: [AvailableApp] = []

        for item in items {
            switch item.kind {
            case .app:
                guard let bundleIdentifier = item.bundleIdentifier,
                      seen.insert(bundleIdentifier).inserted else {
                    continue
                }
                result.append(AvailableApp(
                    bundleIdentifier: bundleIdentifier,
                    displayName: appDisplayName(for: bundleIdentifier)
                ))
            case .appFolder:
                for bundleIdentifier in item.folderBundleIdentifiers where seen.insert(bundleIdentifier).inserted {
                    result.append(AvailableApp(
                        bundleIdentifier: bundleIdentifier,
                        displayName: appDisplayName(for: bundleIdentifier)
                    ))
                }
            case .launchpad, .startMenu, .widget, .smartStack, .spacer, .flexibleSpacer, .divider:
                continue
            }
        }

        return result.sorted {
            let comparison = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            if comparison == .orderedSame {
                return $0.bundleIdentifier.localizedCaseInsensitiveCompare($1.bundleIdentifier) == .orderedAscending
            }
            return comparison == .orderedAscending
        }
    }

    private func appDisplayName(for bundleIdentifier: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return FileManager.default.displayName(atPath: url.path)
        }

        return bundleIdentifier
    }

    private func availableWidgets() -> [AvailableWidget] {
        WidgetCatalog.paletteRegistrations
            .map { registration in
                AvailableWidget(
                kind: registration.kind,
                ownerBundleIdentifier: registration.ownerBundleIdentifier,
                defaultSpan: registration.defaultSpan,
                title: registration.kind.title
                )
            }
    }

    private func suggestedItems(
        apps: [AvailableApp],
        availableWidgets: [AvailableWidget],
        existingItems: [PinnedTileItem]
    ) async -> [SuggestedItem] {
        #if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        if case .available = model.availability {
            let progressToken = SmartOrganizeProgressService.shared.begin()
            defer {
                SmartOrganizeProgressService.shared.end(progressToken)
            }

            let session = LanguageModelSession(
                model: model,
                instructions: "You organize a macOS dock. Produce a compact, practical pinned layout. Group related apps into small folders when it improves scanning. Use at most two dividers and one spacer. Include up to two widgets only when they add clear value but no more than 2 in the whole layout. Keep common daily apps directly accessible. Do not invent bundle identifiers or widget owners."
            )

            let appList = apps.map {
                "- \($0.displayName) [\($0.bundleIdentifier)]"
            }.joined(separator: "\n")
            let widgetList = availableWidgets.map {
                "- \($0.title) [kind=\($0.kind.rawValue), owner=\($0.ownerBundleIdentifier), defaultSpan=\($0.defaultSpan.rawValue)]"
            }.joined(separator: "\n")
            let prompt = """
            Organize these pinned macOS apps into a new Wharf pinned layout.

            Available apps:
            \(appList)

            Available standalone widgets:
            \(widgetList.isEmpty ? "- None" : widgetList)

            Constraints:
            - Folders allowed: yes
            - Launchpad allowed: yes
            - Smart Stack allowed: yes
            - Every app must appear exactly once, either directly or inside one folder.
            - Folder titles should be short and natural.
            - Do not create empty or one-app folders.
            - Avoid leading or trailing dividers and spacers.
            - Return only the structured layout.
            - Avoid single app folders.

            Example:
            <pinned items>
            Finder, Dia, Notes, Calendar, Music, Messages, Slack, Mail, Xcode, Figma, Ghostty, Linear
            </pinned items>
            <trailing section>
            Downloads Folder, Trash
            </trailing section>

            Proposed example:
            <pinned items>
            Finder, <folder name="Messaging">Messages, Slack, Mail</folder>, <folder name="Developer">Xcode, Ghostty</folder>, Dia, Notes, Calendar, Music, Figma, Linear
            </pinned items>
            <trailing section>
            Since Music is in there - a now playing widget, Downloads Folder
            </trailing section>

            Use that example as a style reference for compact grouping, keeping high-frequency apps directly accessible, and adding a relevant media/widget surface when it clearly fits.
            """

            do {
                let response = try await session.respond(to: prompt, generating: SmartPinnedLayoutSuggestion.self)
                let suggestedItems = response.content.items.compactMap(mapSuggestedItem)
                if !suggestedItems.isEmpty {
                    return suggestedItems
                }
            } catch {
                // Fall back to a deterministic layout when generation fails.
            }
        }
        #endif

        return heuristicSuggestedItems(apps: apps, availableWidgets: availableWidgets, existingItems: existingItems)
    }

    #if canImport(FoundationModels)
    private func mapSuggestedItem(_ item: SmartPinnedLayoutSuggestionItem) -> SuggestedItem? {
        switch item.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "app":
            guard !item.bundleIdentifier.isEmpty else {
                return nil
            }
            return .app(item.bundleIdentifier)
        case "folder":
            return .folder(title: item.title, bundleIdentifiers: item.bundleIdentifiers)
        case "divider":
            return .divider
        case "spacer":
            return .spacer
        case "widget":
            guard let kind = WidgetKind(rawValue: item.widgetKind) else {
                return nil
            }
            return .widget(
                kind: kind,
                ownerBundleIdentifier: item.widgetOwnerBundleIdentifier,
                span: TileSpan(rawValue: item.widgetSpan) ?? .three
            )
        case "smartstack", "smart_stack", "smart stack":
            return .smartStack
        case "launchpad":
            return .launchpad
        default:
            return nil
        }
    }
    #endif

    private func heuristicSuggestedItems(
        apps: [AvailableApp],
        availableWidgets: [AvailableWidget],
        existingItems: [PinnedTileItem]
    ) -> [SuggestedItem] {
        let groupedApps = groupedAppsByHeuristic(apps)
        var result: [SuggestedItem] = []

        if existingItems.contains(where: { $0.kind == .launchpad }) {
            result.append(.launchpad)
            result.append(.divider)
        }

        for group in groupedApps {
            if result.last == .divider, group.bundleIdentifiers.isEmpty {
                continue
            }

            if group.bundleIdentifiers.count >= 3 {
                result.append(.folder(title: group.title, bundleIdentifiers: group.bundleIdentifiers))
            } else {
                result.append(contentsOf: group.bundleIdentifiers.map(SuggestedItem.app))
            }

            if group.insertDividerAfter {
                result.append(.divider)
            }
        }

        if let widget = preferredWidget(from: availableWidgets) {
            if result.last != .divider, !result.isEmpty {
                result.append(.divider)
            }
            result.append(.widget(kind: widget.kind, ownerBundleIdentifier: widget.ownerBundleIdentifier, span: widget.defaultSpan))
        }

        return result
    }

    private struct HeuristicGroup {
        let title: String
        let bundleIdentifiers: [String]
        let insertDividerAfter: Bool
    }

    private func groupedAppsByHeuristic(_ apps: [AvailableApp]) -> [HeuristicGroup] {
        let buckets: [(title: String, matcher: (AvailableApp) -> Bool)] = [
            ("Browse", { self.matches($0, keywords: ["safari", "chrome", "firefox", "arc", "edge", "browser"]) }),
            ("Build", { self.matches($0, keywords: ["xcode", "code", "cursor", "terminal", "ghostty", "iterm", "docker", "postman", "figma"]) }),
            ("Chat", { self.matches($0, keywords: ["messages", "slack", "discord", "teams", "mail", "spark", "notion calendar"]) }),
        ]

        var remaining = apps
        var result: [HeuristicGroup] = []

        for (index, bucket) in buckets.enumerated() {
            let matching = remaining.filter(bucket.matcher)
            guard !matching.isEmpty else {
                continue
            }
            remaining.removeAll(where: bucket.matcher)
            result.append(HeuristicGroup(
                title: bucket.title,
                bundleIdentifiers: matching.map(\.bundleIdentifier),
                insertDividerAfter: index < buckets.count - 1
            ))
        }

        if !remaining.isEmpty {
            result.append(HeuristicGroup(
                title: "Apps",
                bundleIdentifiers: remaining.map(\.bundleIdentifier),
                insertDividerAfter: false
            ))
        }

        return result
    }

    private func preferredWidget(from widgets: [AvailableWidget]) -> AvailableWidget? {
        let preferredKinds: [WidgetKind] = [.weather, .calendar, .reminders, .systemStatus, .batteries, .nowPlaying]
        for kind in preferredKinds {
            if let widget = widgets.first(where: { $0.kind == kind }) {
                return widget
            }
        }

        return widgets.first
    }

    private func sanitizedPinnedItems(
        from suggestedItems: [SuggestedItem],
        apps: [AvailableApp],
        availableWidgets: [AvailableWidget],
        existingItems: [PinnedTileItem]
    ) -> [PinnedTileItem] {
        let appNamesByBundleIdentifier = DataIntegrityReporter.makeDictionary(
            apps.map { ($0.bundleIdentifier, $0.displayName) },
            site: "PinnedDockSmartOrganizerService.appNamesByBundleIdentifier"
        )
        let availableBundleIdentifiers = Set(apps.map(\.bundleIdentifier))
        let availableWidgetsByKey = Dictionary(uniqueKeysWithValues: availableWidgets.map {
            (widgetKey(kind: $0.kind, ownerBundleIdentifier: $0.ownerBundleIdentifier), $0)
        })
        let hasLaunchpad = existingItems.contains { $0.kind == .launchpad }

        var remainingBundleIdentifiers = Set(availableBundleIdentifiers)
        var hasLaunchpadItem = false
        var hasSmartStackItem = false
        var widgetKeys: Set<String> = []
        var result: [PinnedTileItem] = []

        for item in suggestedItems {
            switch item {
            case .app(let bundleIdentifier):
                guard remainingBundleIdentifiers.remove(bundleIdentifier) != nil else {
                    continue
                }
                result.append(.app(bundleIdentifier: bundleIdentifier))
            case .folder(let title, let bundleIdentifiers):
                let uniqueBundleIdentifiers = bundleIdentifiers.filter { remainingBundleIdentifiers.contains($0) }
                guard uniqueBundleIdentifiers.count >= 2 else {
                    for bundleIdentifier in uniqueBundleIdentifiers where remainingBundleIdentifiers.remove(bundleIdentifier) != nil {
                        result.append(.app(bundleIdentifier: bundleIdentifier))
                    }
                    continue
                }

                uniqueBundleIdentifiers.forEach { remainingBundleIdentifiers.remove($0) }
                let folderApps = uniqueBundleIdentifiers.compactMap { bundleIdentifier in
                    appNamesByBundleIdentifier[bundleIdentifier].map {
                        AppTile(bundleIdentifier: bundleIdentifier, displayName: $0)
                    }
                }
                let fallbackTitle = AppFolderNamingService.shared.seedName(for: folderApps)
                let resolvedTitle = sanitizeFolderTitle(title, fallback: fallbackTitle)
                result.append(.appFolder(
                    displayName: resolvedTitle,
                    bundleIdentifiers: uniqueBundleIdentifiers,
                    contentViewMode: .grid
                ))
            case .divider:
                result.append(.divider())
            case .spacer:
                result.append(.spacer())
            case .widget(let kind, let ownerBundleIdentifier, let span):
                let key = widgetKey(kind: kind, ownerBundleIdentifier: ownerBundleIdentifier)
                guard let widget = availableWidgetsByKey[key], widgetKeys.insert(key).inserted else {
                    continue
                }
                let resolvedSpan = kind.supportedSpans.contains(span) ? span : widget.defaultSpan
                result.append(.widget(kind: kind, ownerBundleIdentifier: ownerBundleIdentifier, span: resolvedSpan))
            case .smartStack:
                guard !hasSmartStackItem else {
                    continue
                }
                hasSmartStackItem = true
                result.append(.smartStack())
            case .launchpad:
                guard !hasLaunchpadItem else {
                    continue
                }
                hasLaunchpadItem = true
                result.append(.launchpad())
            }
        }

        for bundleIdentifier in apps.map(\.bundleIdentifier) where remainingBundleIdentifiers.remove(bundleIdentifier) != nil {
            result.append(.app(bundleIdentifier: bundleIdentifier))
        }

        if hasLaunchpad, !hasLaunchpadItem {
            result.insert(.launchpad(), at: 0)
        }

        return normalizedPinnedItems(result)
    }

    private func normalizedPinnedItems(_ items: [PinnedTileItem]) -> [PinnedTileItem] {
        var result: [PinnedTileItem] = []

        for item in items {
            switch item.kind {
            case .divider, .spacer, .flexibleSpacer:
                guard !result.isEmpty else {
                    continue
                }
                guard let lastItem = result.last,
                      lastItem.kind != .divider,
                      lastItem.kind != .spacer,
                      lastItem.kind != .flexibleSpacer else {
                    continue
                }
                result.append(item)
            case .app, .appFolder, .launchpad, .startMenu, .widget, .smartStack:
                result.append(item)
            }
        }

        while let lastItem = result.last,
              lastItem.kind == .divider || lastItem.kind == .spacer || lastItem.kind == .flexibleSpacer {
            result.removeLast()
        }

        return result
    }

    private func sanitizeFolderTitle(_ value: String, fallback: String) -> String {
        let collapsed = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r\"'`“”‘’.:,;!?-"))
        let normalized = collapsed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let limited = String(normalized.prefix(28)).trimmingCharacters(in: .whitespacesAndNewlines)
        return limited.isEmpty ? fallback : limited
    }

    private func widgetKey(kind: WidgetKind, ownerBundleIdentifier: String) -> String {
        "\(kind.rawValue):\(ownerBundleIdentifier)"
    }

    private func matches(_ app: AvailableApp, keywords: [String]) -> Bool {
        let haystacks = [app.displayName, app.bundleIdentifier].map {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }
        return keywords.contains { keyword in
            haystacks.contains { $0.contains(keyword) }
        }
    }
}
