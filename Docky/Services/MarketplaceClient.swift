//
//  MarketplaceClient.swift
//  Docky
//
//  Talks to getdocky.com/api/widgets — the marketplace manifest that
//  lists community-submitted widget bundles available for install. The
//  manifest itself is sourced from github.com/josejuanqm/docky-widgets;
//  the website proxies it so Docky has a single, stable URL to call.
//

import CryptoKit
import Foundation

struct MarketplaceWidget: Decodable, Identifiable, Equatable {
    let identifier: String
    let title: String
    let author: String
    let version: String
    let downloadURL: URL
    let sha256: String?
    let previewURL: URL?
    let description: String?
    let systemImageName: String?

    var id: String { identifier }
}

@MainActor
final class MarketplaceClient {
    static let shared = MarketplaceClient()

    private static let manifestURL = URL(string: "https://getdocky.com/api/widgets")!

    private let session: URLSession
    private var cached: [MarketplaceWidget]?

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    /// Fetches the marketplace manifest. Results are cached in-memory
    /// for the lifetime of the process so flipping panes doesn't refetch.
    func fetch(forceRefresh: Bool = false) async throws -> [MarketplaceWidget] {
        if !forceRefresh, let cached { return cached }
        let (data, response) = try await session.data(from: Self.manifestURL)
        try Self.validateHTTP(response)
        let widgets = try JSONDecoder().decode([MarketplaceWidget].self, from: data)
        cached = widgets
        return widgets
    }

    /// Downloads a widget's `.dockywidget` archive into a temp directory
    /// and returns the URL of the bundle inside it, ready for
    /// `ExternalWidgetLoader.installBundle(from:)`. Supports either a
    /// `.zip` containing the bundle or a raw `.dockywidget` package.
    /// If the manifest provided a `sha256`, the downloaded payload is
    /// verified against it before being unpacked.
    func download(_ widget: MarketplaceWidget) async throws -> URL {
        try await downloadBundle(from: widget.downloadURL, expectedSHA256: widget.sha256)
    }

    /// Same staging behavior as `download(_:)` but takes a bare URL —
    /// used by the `docky://install-widget?url=...` URL scheme handler
    /// where there's no MarketplaceWidget struct on hand. Pass an
    /// `expectedSHA256` (hex) to refuse installs whose downloaded
    /// payload doesn't match.
    func downloadBundle(from url: URL, expectedSHA256: String? = nil) async throws -> URL {
        let (tempFile, response) = try await session.download(from: url)
        try Self.validateHTTP(response)

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Wharf-Marketplace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let lastPath = url.lastPathComponent
        let suffix = lastPath.hasSuffix(".zip") ? ".zip" : ".dockywidget"
        let destination = workDir.appendingPathComponent("payload\(suffix)")
        try FileManager.default.moveItem(at: tempFile, to: destination)

        if let expectedSHA256 {
            let actual = try Self.sha256(of: destination)
            guard actual.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
                throw MarketplaceError.sha256Mismatch(expected: expectedSHA256, actual: actual)
            }
        }

        let stagedBundle: URL
        if suffix == ".zip" {
            try unzip(destination, into: workDir)
            try? FileManager.default.removeItem(at: destination)
            guard let bundleURL = try Self.findBundle(in: workDir) else {
                throw MarketplaceError.bundleMissing
            }
            stagedBundle = bundleURL
        } else {
            stagedBundle = destination
        }

        // Strip quarantine + other xattrs. URLSession-downloaded files
        // inherit `com.apple.quarantine`; under hardened runtime that
        // causes Bundle.load() to fail with a misleading code-signing
        // error even though the signature itself is valid.
        Self.clearExtendedAttributes(at: stagedBundle)
        return stagedBundle
    }

    private static func sha256(of file: URL) throws -> String {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func clearExtendedAttributes(at url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-cr", url.path]
        try? process.run()
        process.waitUntilExit()
    }

    private func unzip(_ archive: URL, into directory: URL) throws {
        // Use ditto rather than /usr/bin/unzip: ditto handles macOS
        // resource forks / extended attributes correctly and doesn't
        // propagate the download's quarantine attribute onto every
        // extracted file the way unzip does.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw MarketplaceError.unzipFailed(Int(process.terminationStatus))
        }
    }

    private static func findBundle(in directory: URL) throws -> URL? {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        while let item = enumerator?.nextObject() as? URL {
            if item.pathExtension == "dockywidget" { return item }
        }
        return nil
    }

    private static func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw MarketplaceError.http(http.statusCode)
        }
    }
}

enum MarketplaceError: LocalizedError {
    case http(Int)
    case unzipFailed(Int)
    case bundleMissing
    case sha256Mismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .http(let code):
            "Marketplace responded with HTTP \(code)."
        case .unzipFailed(let code):
            "Couldn't unzip the widget archive (exit code \(code))."
        case .bundleMissing:
            "The downloaded archive doesn't contain a .dockywidget bundle."
        case .sha256Mismatch(let expected, let actual):
            "Download SHA-256 mismatch.\nExpected: \(expected)\nGot: \(actual)"
        }
    }
}
