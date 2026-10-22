import AppKit
import XCTest
@testable import Wharf

/// Image decoding limits and cache behavior. Every instance here is a private
/// `IconCacheService`, so the app's shared cache is never touched.
final class IconCacheServiceTests: XCTestCase {

    private func makeCache(
        countLimit: Int = IconCacheService.cacheCountLimit,
        totalCostLimit: Int = IconCacheService.cacheTotalCostLimit
    ) -> IconCacheService {
        IconCacheService(countLimit: countLimit, totalCostLimit: totalCostLimit)
    }

    private func write(_ data: Data, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func pixelSize(of image: NSImage) -> (Int, Int)? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return (cg.width, cg.height)
    }

    // MARK: - Configuration

    func testProductionLimitsAreTheAuditedValues() {
        XCTAssertEqual(IconCacheService.maxPreviewPixelSize, 512)
        XCTAssertEqual(IconCacheService.cacheTotalCostLimit, 64 * 1024 * 1024)
        XCTAssertEqual(IconCacheService.cacheCountLimit, 256)
    }

    // MARK: - Valid images

    func testSmallPNGDecodes() throws {
        let dir = try makeScratchDirectory("icons")
        let url = try write(ImageFixtures.png(width: 32, height: 24), named: "small.png", in: dir)
        let image = try XCTUnwrap(makeCache().image(forImageFileURL: url))
        let size = try XCTUnwrap(pixelSize(of: image))
        XCTAssertGreaterThan(size.0, 0)
        XCTAssertLessThanOrEqual(max(size.0, size.1), IconCacheService.maxPreviewPixelSize)
    }

    func testJPEGDecodes() throws {
        let dir = try makeScratchDirectory("icons")
        let url = try write(ImageFixtures.jpeg(width: 64, height: 64), named: "photo.jpg", in: dir)
        XCTAssertNotNil(makeCache().image(forImageFileURL: url))
    }

    func testLargeImageIsDownsampledToTheThumbnailCap() throws {
        let dir = try makeScratchDirectory("icons")
        let url = try write(ImageFixtures.png(width: 2_048, height: 1_024), named: "large.png", in: dir)
        let image = try XCTUnwrap(makeCache().image(forImageFileURL: url))
        let size = try XCTUnwrap(pixelSize(of: image))
        XCTAssertLessThanOrEqual(size.0, 512)
        XCTAssertLessThanOrEqual(size.1, 512)
        XCTAssertEqual(size.0, 512, "the long edge is scaled to exactly the cap")
        XCTAssertEqual(size.1, 256, "aspect ratio is preserved")
    }

    func testThumbnailCapAppliesToPortraitImagesToo() throws {
        let dir = try makeScratchDirectory("icons")
        let url = try write(ImageFixtures.png(width: 600, height: 3_000), named: "tall.png", in: dir)
        let image = try XCTUnwrap(makeCache().image(forImageFileURL: url))
        let size = try XCTUnwrap(pixelSize(of: image))
        XCTAssertEqual(size.1, 512)
        XCTAssertLessThanOrEqual(size.0, 512)
    }

    func testImageAtExactlyTheCapIsKeptAtCap() throws {
        let dir = try makeScratchDirectory("icons")
        let url = try write(ImageFixtures.png(width: 512, height: 512), named: "exact.png", in: dir)
        let image = try XCTUnwrap(makeCache().image(forImageFileURL: url))
        let size = try XCTUnwrap(pixelSize(of: image))
        XCTAssertEqual(size.0, 512)
        XCTAssertEqual(size.1, 512)
    }

    func testNSImageSizeMatchesDecodedPixels() throws {
        let dir = try makeScratchDirectory("icons")
        let url = try write(ImageFixtures.png(width: 1_500, height: 1_500), named: "square.png", in: dir)
        let image = try XCTUnwrap(makeCache().image(forImageFileURL: url))
        XCTAssertLessThanOrEqual(image.size.width, 512)
        XCTAssertLessThanOrEqual(image.size.height, 512)
    }

    // MARK: - Pixel bombs

    func testHeaderOnlyHundredThousandSquarePNGIsRejectedCheaply() throws {
        let dir = try makeScratchDirectory("bomb")
        let data = ImageFixtures.declaredSizePNG(width: 100_000, height: 100_000, includePixelData: false)
        XCTAssertLessThan(data.count, 200, "the fixture itself must be tiny")
        let url = try write(data, named: "bomb.png", in: dir)
        let start = Date()
        let image = makeCache().image(forImageFileURL: url)
        XCTAssertNil(image)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testDecodableTenThousandSquareBombStaysWithinTheCap() throws {
        let dir = try makeScratchDirectory("bomb")
        let data = ImageFixtures.declaredSizePNG(width: 10_000, height: 10_000, includePixelData: true)
        XCTAssertLessThan(data.count, 200_000, "a 100 megapixel image in a few KB on disk")
        let url = try write(data, named: "bomb.png", in: dir)
        let start = Date()
        let image = makeCache().image(forImageFileURL: url)
        let elapsed = Date().timeIntervalSince(start)
        let decoded = try XCTUnwrap(image, "a valid bomb should still yield a bounded thumbnail")
        let size = try XCTUnwrap(pixelSize(of: decoded))
        XCTAssertLessThanOrEqual(max(size.0, size.1), 512)
        XCTAssertLessThan(elapsed, 5)
    }

    func testPreviewIconRoutesBombsThroughTheBoundedPath() throws {
        let dir = try makeScratchDirectory("bomb")
        let url = try write(
            ImageFixtures.declaredSizePNG(width: 10_000, height: 10_000, includePixelData: true),
            named: "bomb.png", in: dir
        )
        let image = makeCache().previewIcon(forFileURL: url)
        let size = try XCTUnwrap(pixelSize(of: image))
        XCTAssertLessThanOrEqual(max(size.0, size.1), 512)
    }

    // MARK: - Corrupt and degenerate inputs

    func testZeroByteFileIsRejected() throws {
        let dir = try makeScratchDirectory("bad")
        let url = try write(Data(), named: "empty.png", in: dir)
        XCTAssertNil(makeCache().image(forImageFileURL: url))
    }

    func testGarbageBytesAreRejected() throws {
        let dir = try makeScratchDirectory("bad")
        let url = try write(Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }), named: "noise.png", in: dir)
        XCTAssertNil(makeCache().image(forImageFileURL: url))
    }

    func testTruncatedPNGDoesNotCrash() throws {
        let dir = try makeScratchDirectory("bad")
        let full = ImageFixtures.png(width: 64, height: 64)
        for fraction in [0.1, 0.5, 0.9] {
            let cut = full.prefix(Int(Double(full.count) * fraction))
            let url = try write(Data(cut), named: "cut-\(fraction).png", in: dir)
            // A cut file may decode partially or not at all; either way no trap.
            _ = makeCache().image(forImageFileURL: url)
        }
    }

    func testTextFileWithImageExtensionIsRejected() throws {
        let dir = try makeScratchDirectory("bad")
        let url = try write(Data("not an image".utf8), named: "note.png", in: dir)
        XCTAssertNil(makeCache().image(forImageFileURL: url))
    }

    func testDirectoryInsteadOfFileIsRejected() throws {
        let dir = try makeScratchDirectory("bad")
        let folder = dir.appendingPathComponent("looks-like-an-image.png", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertNil(makeCache().image(forImageFileURL: folder))
    }

    func testMissingFileIsRejected() throws {
        let dir = try makeScratchDirectory("bad")
        XCTAssertNil(makeCache().image(forImageFileURL: dir.appendingPathComponent("absent.png")))
    }

    func testHugeNonImageFileIsRejectedWithoutReadingItAll() throws {
        let dir = try makeScratchDirectory("bad")
        let url = dir.appendingPathComponent("huge.png")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 200 * 1_024 * 1_024) // sparse 200 MB of zeros
        try handle.close()
        let start = Date()
        XCTAssertNil(makeCache().image(forImageFileURL: url))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testFileURLWithUnicodeAndSpacesDecodes() throws {
        let dir = try makeScratchDirectory("unicode")
        let url = try write(ImageFixtures.png(width: 16, height: 16), named: "照片 café 🌅 #1.png", in: dir)
        XCTAssertNotNil(makeCache().image(forImageFileURL: url))
    }

    func testImagesAreReadFromAnyPathOnDiskByDesign() throws {
        // Documented feature decision, not a defect: custom icon paths are
        // trusted wherever the user points them. This pins the current
        // behavior so a future change to confine reads is a deliberate one.
        let elsewhere = try makeScratchDirectory("elsewhere")
        let nested = elsewhere.appendingPathComponent("a/b/../c", isDirectory: true)
        for sub in ["a/b", "a/c"] {
            try FileManager.default.createDirectory(
                at: elsewhere.appendingPathComponent(sub, isDirectory: true), withIntermediateDirectories: true
            )
        }
        try ImageFixtures.png(width: 16, height: 16)
            .write(to: elsewhere.appendingPathComponent("a/c/icon.png"))
        let url = nested.appendingPathComponent("icon.png")
        // The textual path contains "..", and the cache keys on that string.
        XCTAssertTrue(url.path.contains(".."))
        XCTAssertNotNil(makeCache().image(forImageFileURL: url))
    }

    func testSymlinkedImageDecodes() throws {
        let dir = try makeScratchDirectory("links")
        let target = try write(ImageFixtures.png(width: 16, height: 16), named: "real.png", in: dir)
        let link = dir.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertNotNil(makeCache().image(forImageFileURL: link))
    }

    func testDanglingSymlinkIsRejected() throws {
        let dir = try makeScratchDirectory("links")
        let link = dir.appendingPathComponent("dangling.png")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: dir.appendingPathComponent("nowhere.png")
        )
        XCTAssertNil(makeCache().image(forImageFileURL: link))
    }

    func testSymlinkLoopIsRejected() throws {
        let dir = try makeScratchDirectory("links")
        let a = dir.appendingPathComponent("a.png")
        let b = dir.appendingPathComponent("b.png")
        try FileManager.default.createSymbolicLink(at: a, withDestinationURL: b)
        try FileManager.default.createSymbolicLink(at: b, withDestinationURL: a)
        XCTAssertNil(makeCache().image(forImageFileURL: a))
    }

    func testUnreadableImageIsRejected() throws {
        let dir = try makeScratchDirectory("perm")
        let url = try write(ImageFixtures.png(width: 16, height: 16), named: "locked.png", in: dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        // Root ignores mode bits, so only assert when the file is really unreadable.
        if !FileManager.default.isReadableFile(atPath: url.path) {
            XCTAssertNil(makeCache().image(forImageFileURL: url))
        }
    }

    // MARK: - Caching

    func testSecondRequestIsServedFromCache() throws {
        let dir = try makeScratchDirectory("cache")
        let url = try write(ImageFixtures.png(width: 100, height: 100), named: "a.png", in: dir)
        let cache = makeCache()
        let first = try XCTUnwrap(cache.image(forImageFileURL: url))
        let second = try XCTUnwrap(cache.image(forImageFileURL: url))
        XCTAssertTrue(first === second)
    }

    func testInvalidateDropsCachedImages() throws {
        let dir = try makeScratchDirectory("cache")
        let url = try write(ImageFixtures.png(width: 100, height: 100), named: "a.png", in: dir)
        let cache = makeCache()
        let first = try XCTUnwrap(cache.image(forImageFileURL: url))
        cache.invalidate()
        let second = try XCTUnwrap(cache.image(forImageFileURL: url))
        XCTAssertFalse(first === second)
    }

    func testCachedImageSurvivesFileDeletion() throws {
        let dir = try makeScratchDirectory("cache")
        let url = try write(ImageFixtures.png(width: 100, height: 100), named: "a.png", in: dir)
        let cache = makeCache()
        XCTAssertNotNil(cache.image(forImageFileURL: url))
        try FileManager.default.removeItem(at: url)
        XCTAssertNotNil(cache.image(forImageFileURL: url), "served from memory")
        cache.invalidate()
        XCTAssertNil(cache.image(forImageFileURL: url), "gone once the cache is flushed")
    }

    func testFailedDecodesAreNotCached() throws {
        let dir = try makeScratchDirectory("cache")
        let url = dir.appendingPathComponent("late.png")
        let cache = makeCache()
        XCTAssertNil(cache.image(forImageFileURL: url))
        try ImageFixtures.png(width: 20, height: 20).write(to: url)
        XCTAssertNotNil(cache.image(forImageFileURL: url), "a miss must not poison the cache")
    }

    func testDistinctPathsGetDistinctEntries() throws {
        let dir = try makeScratchDirectory("cache")
        let a = try write(ImageFixtures.png(width: 20, height: 20), named: "a.png", in: dir)
        let b = try write(ImageFixtures.png(width: 40, height: 40), named: "b.png", in: dir)
        let cache = makeCache()
        let imageA = try XCTUnwrap(cache.image(forImageFileURL: a))
        let imageB = try XCTUnwrap(cache.image(forImageFileURL: b))
        XCTAssertFalse(imageA === imageB)
    }

    func testTinyCostLimitStillReturnsImages() throws {
        // A cost limit far below one image must evict, never fail or crash.
        let dir = try makeScratchDirectory("cache")
        let url = try write(ImageFixtures.png(width: 200, height: 200), named: "a.png", in: dir)
        let cache = makeCache(totalCostLimit: 16)
        for _ in 0..<5 {
            XCTAssertNotNil(cache.image(forImageFileURL: url))
        }
    }

    func testManyImagesWithSmallCountLimitDoNotCrash() throws {
        let dir = try makeScratchDirectory("cache")
        let cache = makeCache(countLimit: 2)
        for index in 0..<12 {
            let url = try write(ImageFixtures.png(width: 8 + index, height: 8), named: "i\(index).png", in: dir)
            XCTAssertNotNil(cache.image(forImageFileURL: url))
        }
    }

    // MARK: - Bundle and file icons

    func testUnknownBundleIdentifierFallsBackToPlaceholder() {
        let icon = makeCache().icon(forBundleIdentifier: "invalid.bundle.does.not.exist.\(UUID().uuidString)")
        XCTAssertNotNil(icon)
    }

    func testEmptyBundleIdentifierDoesNotTrap() {
        _ = makeCache().icon(forBundleIdentifier: "")
    }

    func testBundleIconIsCachedAfterFirstLoad() {
        let cache = makeCache()
        let identifier = "com.apple.finder"
        XCTAssertNil(cache.cachedIcon(forBundleIdentifier: identifier))
        let loaded = cache.icon(forBundleIdentifier: identifier)
        XCTAssertTrue(cache.cachedIcon(forBundleIdentifier: identifier) === loaded)
    }

    func testBundleIconsAreNormalizedToTheNominalExtent() {
        let icon = makeCache().icon(forBundleIdentifier: "com.apple.finder")
        XCTAssertEqual(icon.size.width, 256)
        XCTAssertEqual(icon.size.height, 256)
    }

    func testPreloadSeedsTheBundleCache() throws {
        let dir = try makeScratchDirectory("preload")
        let cache = makeCache()
        cache.preloadIcon(forBundleIdentifier: "test.preload", fileURL: dir)
        XCTAssertNotNil(cache.cachedIcon(forBundleIdentifier: "test.preload"))
    }

    func testFileIconForMissingPathDoesNotTrap() {
        let icon = makeCache().icon(forFileURL: URL(fileURLWithPath: "/definitely/not/here/\(UUID().uuidString)"))
        XCTAssertNotNil(icon)
    }

    func testFileIconKeyIsThePath() throws {
        let dir = try makeScratchDirectory("fileicon")
        let cache = makeCache()
        XCTAssertTrue(cache.icon(forFileURL: dir) === cache.icon(forFileURL: dir))
    }

    func testAsyncLoadPopulatesCache() async {
        let cache = makeCache()
        let identifier = "com.apple.finder"
        let image = await cache.loadIconAsync(forBundleIdentifier: identifier)
        XCTAssertNotNil(image)
        XCTAssertNotNil(cache.cachedIcon(forBundleIdentifier: identifier))
    }

    // MARK: - Image type detection

    func testImageFileDetection() throws {
        let dir = try makeScratchDirectory("detect")
        let cache = makeCache()
        let png = try write(ImageFixtures.png(width: 4, height: 4), named: "a.png", in: dir)
        let text = try write(Data("x".utf8), named: "a.txt", in: dir)
        let folder = dir.appendingPathComponent("folder.png", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        XCTAssertTrue(cache.isImageFileURL(png))
        XCTAssertFalse(cache.isImageFileURL(text))
        XCTAssertFalse(cache.isImageFileURL(folder), "directories are never images")
        XCTAssertFalse(cache.isImageFileURL(URL(string: "https://example.com/a.png")!), "remote URLs are never read")
    }

    func testPreviewIconFallsBackToWorkspaceIconForNonImages() throws {
        let dir = try makeScratchDirectory("detect")
        let text = try write(Data("x".utf8), named: "a.txt", in: dir)
        let cache = makeCache()
        XCTAssertNotNil(cache.previewIcon(forFileURL: text))
    }

    func testPreviewIconFallsBackWhenImageIsCorrupt() throws {
        let dir = try makeScratchDirectory("detect")
        let url = try write(Data("not really a png".utf8), named: "fake.png", in: dir)
        XCTAssertNotNil(makeCache().previewIcon(forFileURL: url))
    }
}
