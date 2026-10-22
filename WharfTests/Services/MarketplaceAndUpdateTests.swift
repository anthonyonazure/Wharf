import CryptoKit
import XCTest
@testable import Wharf

// MARK: - Marketplace client

/// The widget marketplace is deliberately unconfigured (audit run-1: the
/// upstream endpoint is not this fork's to trust). These tests keep it inert
/// and exercise the download and verification path against a stubbed session.
@MainActor
final class MarketplaceClientTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient() -> MarketplaceClient {
        MarketplaceClient(session: StubURLProtocol.makeSession())
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Inert manifest

    func testFetchIsNotConfigured() async {
        let client = makeClient()
        do {
            _ = try await client.fetch()
            XCTFail("fetch must not succeed without a manifest URL")
        } catch let error as MarketplaceError {
            guard case .notConfigured = error else { return XCTFail("wrong error \(error)") }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testForcedRefreshIsAlsoNotConfigured() async {
        let client = makeClient()
        do {
            _ = try await client.fetch(forceRefresh: true)
            XCTFail("forceRefresh must not bypass the missing manifest")
        } catch let error as MarketplaceError {
            guard case .notConfigured = error else { return XCTFail("wrong error \(error)") }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testFetchSendsNoNetworkRequest() async {
        StubURLProtocol.install { _ in .init(status: 200, body: Data("[]".utf8)) }
        let client = makeClient()
        _ = try? await client.fetch()
        _ = try? await client.fetch(forceRefresh: true)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "an unconfigured marketplace must stay silent")
    }

    func testSharedClientIsAlsoInert() async {
        do {
            _ = try await MarketplaceClient.shared.fetch(forceRefresh: true)
            XCTFail("shared client must not fetch")
        } catch let error as MarketplaceError {
            guard case .notConfigured = error else { return XCTFail("wrong error \(error)") }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testNotConfiguredMessageDoesNotPointAtUpstream() {
        let text = MarketplaceError.notConfigured.errorDescription ?? ""
        XCTAssertFalse(text.isEmpty)
        XCTAssertFalse(text.lowercased().contains("getdocky.com"))
        XCTAssertFalse(text.contains("http"))
    }

    // MARK: Error descriptions

    func testErrorDescriptions() {
        XCTAssertEqual(MarketplaceError.http(404).errorDescription, "Marketplace responded with HTTP 404.")
        XCTAssertTrue(MarketplaceError.unzipFailed(9).errorDescription?.contains("9") == true)
        XCTAssertTrue(MarketplaceError.bundleMissing.errorDescription?.contains(".dockywidget") == true)
        let mismatch = MarketplaceError.sha256Mismatch(expected: "aa", actual: "bb").errorDescription ?? ""
        XCTAssertTrue(mismatch.contains("aa") && mismatch.contains("bb"))
    }

    // MARK: Listing model

    func testWidgetListingDecodes() throws {
        let json = """
        [{"identifier": "com.example.clock", "title": "Clock", "author": "Ada", "version": "1.2",
          "downloadURL": "https://example.com/clock.zip", "sha256": "abc",
          "previewURL": "https://example.com/p.png", "description": "Tells time", "systemImageName": "clock"},
         {"identifier": "min", "title": "Min", "author": "A", "version": "1", "downloadURL": "https://e.com/m.zip"}]
        """
        let widgets = try JSONDecoder().decode([MarketplaceWidget].self, from: Data(json.utf8))
        XCTAssertEqual(widgets.count, 2)
        XCTAssertEqual(widgets[0].id, "com.example.clock")
        XCTAssertEqual(widgets[0].sha256, "abc")
        XCTAssertNil(widgets[1].sha256)
        XCTAssertNil(widgets[1].previewURL)
    }

    func testWidgetListingRejectsMissingRequiredFields() {
        for json in [
            #"[{"title": "t", "author": "a", "version": "1", "downloadURL": "https://e.com/x"}]"#,
            #"[{"identifier": "i", "author": "a", "version": "1", "downloadURL": "https://e.com/x"}]"#,
            #"[{"identifier": "i", "title": "t", "author": "a", "version": "1"}]"#,
            #"[{"identifier": 5, "title": "t", "author": "a", "version": "1", "downloadURL": "https://e.com/x"}]"#,
            #"{"identifier": "i"}"#,
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode([MarketplaceWidget].self, from: Data(json.utf8)), json)
        }
    }

    func testWidgetListingURLsAreNotAutomaticallyHTTPS() throws {
        // Documents what the model accepts: any URL scheme decodes, so the
        // download path must not treat a decoded URL as trusted.
        let json = #"[{"identifier": "i", "title": "t", "author": "a", "version": "1", "downloadURL": "file:///etc/passwd"}]"#
        let widgets = try JSONDecoder().decode([MarketplaceWidget].self, from: Data(json.utf8))
        XCTAssertEqual(widgets.first?.downloadURL.scheme, "file")
    }

    // MARK: Download

    private func stageDownload(_ body: Data, status: Int = 200) {
        StubURLProtocol.install { _ in .init(status: status, body: body) }
    }

    func testHTTPErrorStatusIsReported() async {
        stageDownload(Data("nope".utf8), status: 404)
        do {
            _ = try await makeClient().downloadBundle(from: URL(string: "https://example.test/w.dockywidget")!)
            XCTFail("expected an HTTP error")
        } catch let error as MarketplaceError {
            guard case .http(404) = error else { return XCTFail("wrong error \(error)") }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testServerErrorsAreReported() async {
        for status in [301, 400, 403, 429, 500, 503, 199, 300] {
            stageDownload(Data("x".utf8), status: status)
            do {
                _ = try await makeClient().downloadBundle(from: URL(string: "https://example.test/w.dockywidget")!)
                XCTFail("status \(status) should be rejected")
            } catch let error as MarketplaceError {
                guard case .http(let code) = error else { return XCTFail("wrong error \(error)") }
                XCTAssertEqual(code, status)
            } catch {
                XCTFail("unexpected error \(error) for \(status)")
            }
        }
    }

    func testRawBundleDownloadIsStagedWithMatchingHash() async throws {
        let payload = Data("pretend bundle".utf8)
        stageDownload(payload)
        let staged = try await makeClient().downloadBundle(
            from: URL(string: "https://example.test/w.dockywidget")!,
            expectedSHA256: sha256Hex(payload)
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: staged), payload)
        XCTAssertEqual(staged.lastPathComponent, "payload.dockywidget")
        XCTAssertTrue(staged.deletingLastPathComponent().lastPathComponent.hasPrefix("Wharf-Marketplace-"))
    }

    func testHashComparisonIgnoresCase() async throws {
        let payload = Data("case".utf8)
        stageDownload(payload)
        let staged = try await makeClient().downloadBundle(
            from: URL(string: "https://example.test/w.dockywidget")!,
            expectedSHA256: sha256Hex(payload).uppercased()
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
    }

    func testHashMismatchIsRejected() async {
        stageDownload(Data("tampered".utf8))
        do {
            _ = try await makeClient().downloadBundle(
                from: URL(string: "https://example.test/w.dockywidget")!,
                expectedSHA256: sha256Hex(Data("original".utf8))
            )
            XCTFail("a mismatched hash must be refused")
        } catch let error as MarketplaceError {
            guard case .sha256Mismatch(let expected, let actual) = error else { return XCTFail("wrong error \(error)") }
            XCTAssertEqual(actual, sha256Hex(Data("tampered".utf8)))
            XCTAssertEqual(expected, sha256Hex(Data("original".utf8)))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testMalformedHashStringsNeverMatch() async {
        let payload = Data("payload".utf8)
        let good = sha256Hex(payload)
        let malformed = ["", " ", "sha256:\(good)", " \(good)", "\(good) ", String(good.dropLast()), "\(good)00", "zz", "0"]
        for expected in malformed {
            stageDownload(payload)
            do {
                _ = try await makeClient().downloadBundle(
                    from: URL(string: "https://example.test/w.dockywidget")!,
                    expectedSHA256: expected
                )
                XCTFail("hash \(expected.debugDescription) should not verify")
            } catch let error as MarketplaceError {
                guard case .sha256Mismatch = error else { return XCTFail("wrong error \(error)") }
            } catch {
                XCTFail("unexpected error \(error)")
            }
        }
    }

    func testMismatchedDownloadCanStillBeFoundOnDiskButIsNotReturned() async {
        // The failure path returns an error instead of a URL, so a caller can
        // never install an unverified payload by accident.
        stageDownload(Data("tampered".utf8))
        let result = try? await makeClient().downloadBundle(
            from: URL(string: "https://example.test/w.dockywidget")!,
            expectedSHA256: String(repeating: "0", count: 64)
        )
        XCTAssertNil(result)
    }

    func testDownloadWithoutExpectedHashStillStages() async throws {
        // Documents the current policy: a missing hash is not an error.
        stageDownload(Data("unverified".utf8))
        let staged = try await makeClient().downloadBundle(from: URL(string: "https://example.test/w.dockywidget")!)
        addTeardownBlock { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
    }

    func testZipDownloadIsUnpackedAndBundleFound() async throws {
        let archive = ZIPFixture.archive([
            .init(name: "Clock.dockywidget/Contents/Info.plist", contents: Data("<plist/>".utf8)),
        ])
        stageDownload(archive)
        let staged = try await makeClient().downloadBundle(
            from: URL(string: "https://example.test/clock.zip")!,
            expectedSHA256: sha256Hex(archive)
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent().deletingLastPathComponent()) }
        XCTAssertEqual(staged.pathExtension, "dockywidget")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.appendingPathComponent("Contents/Info.plist").path))
    }

    func testZipWithoutBundleIsRejected() async {
        let archive = ZIPFixture.archive([.init(name: "readme.txt", contents: Data("hi".utf8))])
        stageDownload(archive)
        do {
            _ = try await makeClient().downloadBundle(from: URL(string: "https://example.test/x.zip")!)
            XCTFail("an archive without a bundle must be refused")
        } catch let error as MarketplaceError {
            guard case .bundleMissing = error else { return XCTFail("wrong error \(error)") }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testCorruptZipIsRejected() async {
        stageDownload(Data("PK\u{3}\u{4} this is not a real archive".utf8))
        do {
            _ = try await makeClient().downloadBundle(from: URL(string: "https://example.test/x.zip")!)
            XCTFail("a corrupt archive must be refused")
        } catch let error as MarketplaceError {
            switch error {
            case .unzipFailed, .bundleMissing: break
            default: XCTFail("wrong error \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testEmptyZipDownloadIsRejected() async {
        stageDownload(Data())
        do {
            _ = try await makeClient().downloadBundle(from: URL(string: "https://example.test/x.zip")!)
            XCTFail("an empty archive must be refused")
        } catch {
            XCTAssertTrue(error is MarketplaceError)
        }
    }

    func testZipEntryWithParentTraversalDoesNotEscapeStaging() async throws {
        let marker = "wharf-zip-slip-\(UUID().uuidString).txt"
        let archive = ZIPFixture.archive([
            .init(name: "../\(marker)", contents: Data("escaped".utf8)),
            .init(name: "../../\(marker)", contents: Data("escaped".utf8)),
            .init(name: "Ok.dockywidget/Contents/Info.plist", contents: Data("<plist/>".utf8)),
        ])
        stageDownload(archive)
        let staged = try? await makeClient().downloadBundle(from: URL(string: "https://example.test/x.zip")!)
        if let staged {
            addTeardownBlock { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent().deletingLastPathComponent()) }
        }

        let tmp = FileManager.default.temporaryDirectory
        let escapes = [
            tmp.appendingPathComponent(marker),
            tmp.deletingLastPathComponent().appendingPathComponent(marker),
        ]
        for escape in escapes {
            let exists = FileManager.default.fileExists(atPath: escape.path)
            if exists { try? FileManager.default.removeItem(at: escape) }
            XCTAssertFalse(exists, "archive entry escaped to \(escape.path)")
        }
    }

    func testZipSymlinkEntryIsStagedAsCurrentBehavior() async throws {
        // A symlink entry that targets /etc/passwd is created by the
        // extractor, so the staged bundle can contain a link to an arbitrary
        // file. Recorded as current behavior; nothing here reads through it.
        let archive = ZIPFixture.archive([
            .init(name: "Link.dockywidget/Contents/Info.plist", contents: Data("<plist/>".utf8)),
            .init(name: "Link.dockywidget/Contents/passwd", contents: Data("/etc/passwd".utf8), unixMode: 0o120755),
        ])
        stageDownload(archive)
        let staged = try await makeClient().downloadBundle(from: URL(string: "https://example.test/link.zip")!)
        addTeardownBlock { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent().deletingLastPathComponent()) }
        XCTAssertEqual(staged.pathExtension, "dockywidget")
    }

    func testZipSuffixDecidesExtractionNotContentType() async throws {
        // ".ZIP" in upper case is not recognized, so the payload is treated as
        // a raw bundle file and never extracted.
        let archive = ZIPFixture.archive([.init(name: "A.dockywidget/x", contents: Data("x".utf8))])
        stageDownload(archive)
        let staged = try await makeClient().downloadBundle(from: URL(string: "https://example.test/UPPER.ZIP")!)
        addTeardownBlock { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        XCTAssertEqual(staged.lastPathComponent, "payload.dockywidget")
    }

    func testTransportFailurePropagates() async {
        StubURLProtocol.install { _ in .init(error: URLError(.cannotConnectToHost)) }
        do {
            _ = try await makeClient().downloadBundle(from: URL(string: "https://example.test/w.dockywidget")!)
            XCTFail("expected a transport error")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
        }
    }

    func testEachDownloadStagesIntoItsOwnDirectory() async throws {
        stageDownload(Data("one".utf8))
        let first = try await makeClient().downloadBundle(from: URL(string: "https://example.test/a.dockywidget")!)
        let second = try await makeClient().downloadBundle(from: URL(string: "https://example.test/a.dockywidget")!)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }
        XCTAssertNotEqual(first.deletingLastPathComponent(), second.deletingLastPathComponent())
    }

    func testStagedFileNameIgnoresHostileRemoteNames() async throws {
        stageDownload(Data("x".utf8))
        let url = URL(string: "https://example.test/..%2F..%2Fetc%2Fpasswd.dockywidget")!
        let staged = try await makeClient().downloadBundle(from: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        XCTAssertEqual(staged.lastPathComponent, "payload.dockywidget")
    }
}

// MARK: - Update feed

/// Wharf ships without `SUFeedURL` and `SUPublicEDKey`. If either appears, an
/// update channel this fork does not control is live again.
final class AppUpdateServiceTests: XCTestCase {

    private var repoRoot: URL {
        // WharfTests/Services/<this file> -> repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    // MARK: Pure feed rules

    func testMissingValueMeansNoFeed() {
        XCTAssertNil(AppUpdateService.feedURLString(fromInfoValue: nil))
    }

    func testEmptyStringMeansNoFeed() {
        XCTAssertNil(AppUpdateService.feedURLString(fromInfoValue: ""))
    }

    func testNonStringValuesMeanNoFeed() {
        let values: [Any] = [42, true, ["https://example.com"], ["url": "https://example.com"], NSNull(), URL(string: "https://example.com")!, Data()]
        for value in values {
            XCTAssertNil(AppUpdateService.feedURLString(fromInfoValue: value), "\(value)")
        }
    }

    func testStringValueIsReturnedVerbatim() {
        XCTAssertEqual(
            AppUpdateService.feedURLString(fromInfoValue: "https://updates.example.test/appcast.xml"),
            "https://updates.example.test/appcast.xml"
        )
    }

    func testFeedKeyNameIsTheSparkleKey() {
        XCTAssertEqual(AppUpdateService.infoDictionaryFeedKey, "SUFeedURL")
    }

    // MARK: The shipped bundle

    func testShippedBundleDeclaresNoFeedURL() {
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL"))
        XCTAssertNil(AppUpdateService.configuredFeedURLString)
        XCTAssertFalse(AppUpdateService.hasConfiguredFeed)
    }

    func testShippedBundleDeclaresNoPublicKey() {
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey"))
    }

    func testShippedBundleHasNoLegacyDSAKeyOrFeedAliases() {
        for key in ["SUPublicDSAKeyFile", "SUPublicDSAKey", "SUFeedURLString", "SUAppcastURL", "SUFeedUrl"] {
            XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: key), key)
        }
    }

    func testBundleDoesNotEnableAutomaticChecksByDefault() {
        // With no feed there is nothing to check; an enabled flag would only
        // produce a user-visible failure dialog at startup.
        let automatic = Bundle.main.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool
        XCTAssertNotEqual(automatic, true)
    }

    // MARK: Source tree guards

    private func infoPlist() throws -> [String: Any] {
        let url = repoRoot.appendingPathComponent("Config/Info.plist")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }

    func testSourceInfoPlistDoesNotDefineUpdateKeys() throws {
        let plist = try infoPlist()
        XCTAssertNil(plist["SUFeedURL"])
        XCTAssertNil(plist["SUPublicEDKey"])
    }

    func testNoSwiftSourceBuildsAFeedURLFromAForeignDomain() throws {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: repoRoot.appendingPathComponent("Docky"),
            includingPropertiesForKeys: nil
        ))
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                if trimmed.contains("getdocky.com") {
                    offenders.append("\(url.lastPathComponent):\(number + 1)")
                }
            }
        }
        XCTAssertEqual(offenders, [], "the upstream domain must only appear in comments")
    }

    func testMarketplaceSourceHasNoManifestURLLiteral() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Docky/Services/MarketplaceClient.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("manifestURL: URL? = nil"), "the manifest URL must stay nil until Wharf owns a catalog")
    }

    func testUpdaterIsNotStartedWithoutAFeedInSource() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Docky/Services/AppUpdateService.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("startingUpdater: Self.hasConfiguredFeed"))
    }
}
