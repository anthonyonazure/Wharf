//
//  LaunchpadLayoutService.swift
//  Docky
//
//  Owns the user's Launchpad layout — order of top-level items and
//  the virtual folders they belong to. Persisted to UserDefaults
//  under `docky.launchpadLayout`.
//
//  The service exposes mutation methods that maintain invariants
//  (each app appears at most once across top level and folders;
//  empty folders dissolve themselves; reorder operates on a single
//  flat top-level index space).
//

import Foundation
import Observation

@MainActor
@Observable final class LaunchpadLayoutService {
    static let shared = LaunchpadLayoutService()

    private(set) var layout: LaunchpadLayout

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    enum Keys {
        static let layout = "docky.launchpadLayout"
    }

    private convenience init() {
        self.init(defaults: .standard)
    }

    /// Test seam: an isolated service over a throwaway defaults suite.
    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Keys.layout),
           let decoded = try? JSONDecoder().decode(LaunchpadLayout.self, from: data) {
            self.layout = decoded
        } else {
            self.layout = .empty
        }
    }

    // MARK: - Migration / seeding

    /// Seeds the layout from a snapshot if the layout is currently
    /// empty. Used on first launch to import the alpha-sorted FS scan
    /// (apps + FS-folder-derived virtual folders) so the user starts
    /// with a sensible layout instead of a blank grid.
    func seedIfEmpty(_ items: [LaunchpadLayoutItem]) {
        guard layout.items.isEmpty, !items.isEmpty else { return }
        layout.items = items
        persist()
    }

    // MARK: - Lookups

    func folder(withID id: String) -> LaunchpadFolder? {
        for item in layout.items {
            if case .folder(let folder) = item, folder.id == id {
                return folder
            }
        }
        return nil
    }

    /// Bundle identifiers referenced anywhere in the layout.
    var allReferencedBundleIDs: Set<String> {
        var ids: Set<String> = []
        for item in layout.items {
            switch item {
            case .app(let bundleID): ids.insert(bundleID)
            case .folder(let folder): ids.formUnion(folder.bundleIDs)
            }
        }
        return ids
    }

    // MARK: - Reorder

    /// Moves the item with `itemID` to the given top-level position.
    /// `position` is the desired final index in `layout.items` (0 …
    /// items.count). No-op when already at the target.
    func moveItem(id itemID: String, toIndex position: Int) {
        guard let currentIndex = layout.items.firstIndex(where: { $0.id == itemID }) else { return }
        let target = max(0, min(position, layout.items.count - 1))
        guard target != currentIndex else { return }
        let item = layout.items.remove(at: currentIndex)
        let clamped = max(0, min(target, layout.items.count))
        layout.items.insert(item, at: clamped)
        persist()
    }

    /// Inserts `itemID` immediately before or after `anchorItemID`.
    /// Handles the case where the dragged item came from an open
    /// folder by first popping it out, then placing it next to the
    /// anchor.
    func moveItem(id itemID: String, relativeTo anchorItemID: String, position: RelativePosition) {
        // Pop the dragged app out of its folder if needed; this can
        // shift indices so we re-locate the anchor afterwards.
        if itemID.hasPrefix("app:") {
            let bundleID = String(itemID.dropFirst("app:".count))
            if enclosingFolder(of: bundleID) != nil {
                removeFromFolder(bundleID: bundleID)
            }
        }
        guard let anchorIndex = layout.items.firstIndex(where: { $0.id == anchorItemID }) else { return }
        guard let currentIndex = layout.items.firstIndex(where: { $0.id == itemID }) else { return }
        let desiredIndex = position == .before ? anchorIndex : anchorIndex + 1
        let adjusted = currentIndex < desiredIndex ? desiredIndex - 1 : desiredIndex
        guard adjusted != currentIndex else { return }
        let item = layout.items.remove(at: currentIndex)
        let clamped = max(0, min(adjusted, layout.items.count))
        layout.items.insert(item, at: clamped)
        persist()
    }

    enum RelativePosition {
        case before, after
    }

    // MARK: - Folder creation & membership

    /// Creates a virtual folder containing two apps and replaces the
    /// `targetBundleID` slot in the top-level grid with it. The
    /// `draggedBundleID` is also removed wherever it was. Returns the
    /// new folder's id, or nil when either app can't be located in the
    /// layout (shouldn't happen in practice — call after `seedIfEmpty`).
    @discardableResult
    func createFolder(
        merging draggedBundleID: String,
        intoSlotOf targetBundleID: String,
        name: String
    ) -> String? {
        guard draggedBundleID != targetBundleID else { return nil }
        // Validate before mutating: the target must be a top-level .app (if
        // it is already a folder, callers should use addApp). A failed
        // merge must leave the layout untouched.
        func topLevelIndex(of bundleID: String) -> Int? {
            layout.items.firstIndex(where: {
                if case .app(let id) = $0 { return id == bundleID }
                return false
            })
        }
        guard topLevelIndex(of: targetBundleID) != nil else { return nil }
        // Remove the dragged app from wherever it currently lives. This can
        // shift indices (a collapsed folder, a removed slot), so re-locate.
        removeApp(bundleID: draggedBundleID)
        guard let targetIndex = topLevelIndex(of: targetBundleID) else { return nil }

        let folder = LaunchpadFolder(
            id: UUID().uuidString,
            name: name,
            bundleIDs: [targetBundleID, draggedBundleID]
        )
        layout.items[targetIndex] = .folder(folder)
        persist()
        return folder.id
    }

    /// Adds an app to an existing folder. Removes the app from
    /// wherever it currently lives in the layout.
    func addApp(bundleID: String, toFolderWithID folderID: String) {
        func folderIndex() -> Int? {
            layout.items.firstIndex(where: {
                if case .folder(let folder) = $0 { return folder.id == folderID }
                return false
            })
        }
        // Validate the destination before removing anything.
        guard let existingIndex = folderIndex(),
              case .folder(var existing) = layout.items[existingIndex] else { return }
        if existing.bundleIDs.contains(bundleID) {
            // Already a member: move to the end in place. Going through
            // removeApp would collapse a two-app folder and lose it.
            existing.bundleIDs.removeAll { $0 == bundleID }
            existing.bundleIDs.append(bundleID)
            layout.items[existingIndex] = .folder(existing)
            persist()
            return
        }
        removeApp(bundleID: bundleID)
        // removeApp can shift indices; re-locate the destination.
        guard let located = folderIndex(),
              case .folder(var folder) = layout.items[located] else { return }
        folder.bundleIDs.append(bundleID)
        layout.items[located] = .folder(folder)
        persist()
    }

    /// Pops an app out of its enclosing folder back to the top level,
    /// inserted just after the folder. If the folder becomes empty or
    /// holds only one app, it dissolves and the remaining app takes
    /// the folder's slot.
    func removeFromFolder(bundleID: String) {
        guard let (folderIndex, folder) = enclosingFolder(of: bundleID) else { return }
        var updated = folder
        updated.bundleIDs.removeAll { $0 == bundleID }

        switch updated.bundleIDs.count {
        case 0:
            // Folder dissolves; the popped app takes its slot.
            layout.items[folderIndex] = .app(bundleID: bundleID)
        case 1:
            // Replace the folder with the surviving app and append the
            // popped app just after it.
            let survivor = updated.bundleIDs[0]
            layout.items[folderIndex] = .app(bundleID: survivor)
            let insertAt = min(folderIndex + 1, layout.items.count)
            layout.items.insert(.app(bundleID: bundleID), at: insertAt)
        default:
            layout.items[folderIndex] = .folder(updated)
            let insertAt = min(folderIndex + 1, layout.items.count)
            layout.items.insert(.app(bundleID: bundleID), at: insertAt)
        }
        persist()
    }

    /// Moves `bundleID` to absolute position `targetIndex` within its
    /// enclosing folder (`folderID`). `targetIndex` is in the
    /// post-removal coordinate space, matching the launchpad reorder
    /// gesture's convention. No-op when the app isn't in the folder or
    /// the order is unchanged.
    func moveAppInFolder(folderID: String, bundleID: String, toIndex targetIndex: Int) {
        guard let folderIndex = layout.items.firstIndex(where: {
            if case .folder(let folder) = $0 { return folder.id == folderID }
            return false
        }) else { return }
        guard case .folder(var folder) = layout.items[folderIndex] else { return }
        guard let currentIndex = folder.bundleIDs.firstIndex(of: bundleID) else { return }

        var ids = folder.bundleIDs
        ids.remove(at: currentIndex)
        let clamped = max(0, min(targetIndex, ids.count))
        ids.insert(bundleID, at: clamped)
        guard ids != folder.bundleIDs else { return }

        folder.bundleIDs = ids
        layout.items[folderIndex] = .folder(folder)
        persist()
    }

    /// Renames a folder. Empty/whitespace-only names are rejected.
    func renameFolder(id folderID: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = layout.items.firstIndex(where: {
            if case .folder(let folder) = $0 { return folder.id == folderID }
            return false
        }) else { return }
        guard case .folder(var folder) = layout.items[index] else { return }
        guard folder.name != trimmed else { return }
        folder.name = trimmed
        layout.items[index] = .folder(folder)
        persist()
    }

    /// Dissolves a folder, splicing its apps back into the top-level
    /// grid at the folder's position.
    func ungroupFolder(id folderID: String) {
        guard let index = layout.items.firstIndex(where: {
            if case .folder(let folder) = $0 { return folder.id == folderID }
            return false
        }) else { return }
        guard case .folder(let folder) = layout.items[index] else { return }
        let appItems = folder.bundleIDs.map { LaunchpadLayoutItem.app(bundleID: $0) }
        layout.items.replaceSubrange(index ... index, with: appItems)
        persist()
    }

    // MARK: - Newly-installed / removed apps

    /// Appends previously-unseen bundle IDs to the top level. Called
    /// after a scan when new apps appear on disk.
    func appendNewApps(_ bundleIDs: [String]) {
        let known = allReferencedBundleIDs
        var seen = known
        let additions = bundleIDs
            .filter { seen.insert($0).inserted }
            .map { LaunchpadLayoutItem.app(bundleID: $0) }
        guard !additions.isEmpty else { return }
        layout.items.append(contentsOf: additions)
        persist()
    }

    /// Removes bundle IDs that are no longer installed. Empties
    /// folders that lose their last member.
    func pruneMissingApps(installedBundleIDs: Set<String>) {
        var changed = false
        var newItems: [LaunchpadLayoutItem] = []
        newItems.reserveCapacity(layout.items.count)

        for item in layout.items {
            switch item {
            case .app(let bundleID):
                if installedBundleIDs.contains(bundleID) {
                    newItems.append(item)
                } else {
                    changed = true
                }
            case .folder(var folder):
                let original = folder.bundleIDs
                folder.bundleIDs = original.filter { installedBundleIDs.contains($0) }
                if folder.bundleIDs.isEmpty {
                    changed = true
                    continue
                }
                if folder.bundleIDs != original { changed = true }
                if folder.bundleIDs.count == 1 {
                    newItems.append(.app(bundleID: folder.bundleIDs[0]))
                    changed = true
                } else {
                    newItems.append(.folder(folder))
                }
            }
        }

        if changed {
            layout.items = newItems
            persist()
        }
    }

    // MARK: - Internals

    private func enclosingFolder(of bundleID: String) -> (index: Int, folder: LaunchpadFolder)? {
        for (index, item) in layout.items.enumerated() {
            if case .folder(let folder) = item, folder.bundleIDs.contains(bundleID) {
                return (index, folder)
            }
        }
        return nil
    }

    private func removeApp(bundleID: String) {
        for (index, item) in layout.items.enumerated() {
            switch item {
            case .app(let id) where id == bundleID:
                layout.items.remove(at: index)
                return
            case .folder(var folder):
                if folder.bundleIDs.contains(bundleID) {
                    folder.bundleIDs.removeAll { $0 == bundleID }
                    if folder.bundleIDs.isEmpty {
                        layout.items.remove(at: index)
                    } else if folder.bundleIDs.count == 1 {
                        // Collapse single-item folder to a plain app.
                        layout.items[index] = .app(bundleID: folder.bundleIDs[0])
                    } else {
                        layout.items[index] = .folder(folder)
                    }
                    return
                }
            default:
                break
            }
        }
    }

    private func persist() {
        guard let data = try? encoder.encode(layout) else { return }
        defaults.set(data, forKey: Keys.layout)
    }
}
