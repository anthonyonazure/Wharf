//
//  RecentFilesService.swift
//  Docky
//
//  Live "Recents" list backed by Spotlight, mirroring Finder's sidebar
//  Recents canned search at:
//    /System/Library/CoreServices/Finder.app/Contents/Resources/
//      MyLibraries/myDocuments.cannedSearch/Resources/search.savedSearch
//
//  The predicate filters to files that have a kMDItemLastUsedDate set and
//  whose UTI tree is user-perceivable content (or Office docs, or archives).
//  Results stream in live; consumers observe `recentURLs`.
//

import AppKit
import Combine
import Foundation
import OSLog

@MainActor
final class RecentFilesService: ObservableObject {
    static let shared = RecentFilesService()
    private static let logger = Logger(subsystem: "gt.quintero.Wharf", category: "RecentFiles")

    @Published private(set) var recentURLs: [URL] = []

    private let query: NSMetadataQuery
    private var observers: [NSObjectProtocol] = []
    static let maxResults = 50

    static func recentsPredicate() -> NSPredicate {
        let oldDate = Date(timeIntervalSince1970: 0) as NSDate
        return NSPredicate(
            format: "kMDItemLastUsedDate > %@ AND (kMDItemContentTypeTree == %@ OR kMDItemContentTypeTree LIKE[cd] %@ OR kMDItemContentTypeTree == %@)",
            oldDate,
            "public.content",
            "com.microsoft.*",
            "public.archive"
        )
    }

    private init() {
        let query = NSMetadataQuery()
        query.operationQueue = .main
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        // `kMDItemLastUsedDate > epoch` is the NSPredicate-friendly way to
        // express MDQuery's `kMDItemLastUsedDate = "*"` (has any value).
        // `LIKE` is string-only in NSPredicate and silently matches nothing
        // against a date attribute.
        query.predicate = Self.recentsPredicate()
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false)]
        query.notificationBatchingInterval = 1.0
        self.query = query

        Self.logger.info("init predicate=\(query.predicate?.predicateFormat ?? "nil", privacy: .public)")

        let center = NotificationCenter.default
        for name in [
            NSNotification.Name.NSMetadataQueryDidStartGathering,
            .NSMetadataQueryGatheringProgress,
            .NSMetadataQueryDidFinishGathering,
            .NSMetadataQueryDidUpdate
        ] {
            let capturedName = name
            let token = center.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.handleNotification(named: capturedName)
                }
            }
            observers.append(token)
        }

        let started = query.start()
        Self.logger.info("query.start() returned=\(started, privacy: .public)")
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        query.stop()
    }

    private func handleNotification(named name: NSNotification.Name) {
        Self.logger.info("notification name=\(name.rawValue, privacy: .public) resultCount=\(self.query.resultCount, privacy: .public) isGathering=\(self.query.isGathering, privacy: .public)")
        refresh()
    }

    private func refresh() {
        query.disableUpdates()
        defer { query.enableUpdates() }

        let count = min(query.resultCount, Self.maxResults)
        var urls: [URL] = []
        urls.reserveCapacity(count)
        var loggedFirst = false
        for index in 0..<count {
            guard let item = query.result(at: index) as? NSMetadataItem else {
                if !loggedFirst {
                    Self.logger.error("result at index 0 was not NSMetadataItem")
                    loggedFirst = true
                }
                continue
            }
            let url = url(from: item)
            if !loggedFirst {
                let urlValueType = String(describing: type(of: item.value(forAttribute: NSMetadataItemURLKey) ?? "nil"))
                let pathValueType = String(describing: type(of: item.value(forAttribute: NSMetadataItemPathKey) ?? "nil"))
                Self.logger.info("first result urlKeyType=\(urlValueType, privacy: .public) pathKeyType=\(pathValueType, privacy: .public) extractedURL=\(url?.lastPathComponent ?? "nil", privacy: .public)")
                loggedFirst = true
            }
            if let url {
                urls.append(url)
            }
        }

        Self.logger.info("refresh built urls.count=\(urls.count, privacy: .public) fromResultCount=\(count, privacy: .public)")

        if urls != recentURLs {
            Self.logger.info("recentURLs updated count=\(urls.count, privacy: .public) first=\(urls.first?.lastPathComponent ?? "nil", privacy: .public)")
            recentURLs = urls
        }
    }

    private func url(from item: NSMetadataItem) -> URL? {
        Self.resolveURL(
            urlValue: item.value(forAttribute: NSMetadataItemURLKey),
            pathValue: item.value(forAttribute: NSMetadataItemPathKey)
        )
    }

    /// Prefers the item's URL attribute, falling back to its path attribute.
    static func resolveURL(urlValue: Any?, pathValue: Any?) -> URL? {
        if let value = urlValue {
            if let url = value as? URL { return url }
            if let nsURL = value as? NSURL { return nsURL as URL }
        }
        if let path = pathValue as? String {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}
