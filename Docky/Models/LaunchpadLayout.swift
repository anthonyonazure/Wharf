//
//  LaunchpadLayout.swift
//  Docky
//
//  Persisted user-defined ordering and virtual folders for the
//  Launchpad overlay. Stored as JSON in UserDefaults; the layout is
//  resolved against the filesystem scan to produce the live entries,
//  so apps installed after the layout was saved append at the end and
//  uninstalled apps drop out automatically.
//

import CoreTransferable
import Foundation
import UniformTypeIdentifiers

struct LaunchpadLayout: Codable, Equatable {
    var items: [LaunchpadLayoutItem]

    static let empty = LaunchpadLayout(items: [])
}

enum LaunchpadLayoutItem: Codable, Equatable, Identifiable {
    case app(bundleID: String)
    case folder(LaunchpadFolder)

    var id: String {
        switch self {
        case .app(let bundleID): return "app:\(bundleID)"
        case .folder(let folder): return "folder:\(folder.id)"
        }
    }

    /// Bundle identifiers this item exposes at the top level. For an
    /// app it's the app itself; for a folder it's the apps inside.
    var bundleIDs: [String] {
        switch self {
        case .app(let bundleID): return [bundleID]
        case .folder(let folder): return folder.bundleIDs
        }
    }
}

struct LaunchpadFolder: Codable, Equatable, Identifiable {
    /// Stable UUID string. Survives renames and re-orderings.
    var id: String
    var name: String
    /// Ordered bundle identifiers of apps contained in this folder.
    /// An app must appear in at most one folder; the resolver dedupes
    /// across folders, preferring the earliest occurrence.
    var bundleIDs: [String]
}

/// Payload carried by Launchpad drag-and-drop operations. Identifies
/// which item is moving and whether it came from the top-level grid
/// or out of an open folder.
struct LaunchpadDragPayload: Codable, Equatable, Transferable {
    enum Source: Codable, Equatable {
        case topLevelApp(bundleID: String)
        case topLevelFolder(folderID: String)
        case folderApp(folderID: String, bundleID: String)
    }

    let source: Source

    /// Convenience for dropdown logic — folders aren't merged or
    /// added to other folders so this is nil only when a folder is
    /// being dragged.
    var bundleID: String? {
        switch source {
        case .topLevelApp(let bundleID), .folderApp(_, let bundleID): return bundleID
        case .topLevelFolder: return nil
        }
    }

    /// `true` when this payload came from inside an open folder.
    var originFolderID: String? {
        if case .folderApp(let folderID, _) = source { return folderID }
        return nil
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}

/// Splits `items` into pages of `pageSize`. A non-positive page size or an
/// empty list yields a single empty page, so callers always have a page to show.
func launchpadPaginate<Element>(_ items: [Element], pageSize: Int) -> [[Element]] {
    guard !items.isEmpty, pageSize > 0 else { return [[]] }
    return stride(from: 0, to: items.count, by: pageSize).map { offset in
        Array(items[offset..<min(offset + pageSize, items.count)])
    }
}
