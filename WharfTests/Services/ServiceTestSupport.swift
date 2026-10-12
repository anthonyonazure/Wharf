import AppKit
import Compression
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Shared fixtures for the service-layer tests: scratch directories, throwaway
/// defaults suites, in-test image encoders, a URLProtocol stub and a ZIP writer.
/// Nothing here touches the network, the real defaults domain or the user's
/// Application Support folder.

// MARK: - Scratch space

extension XCTestCase {
    /// A fresh directory under the system temp folder, removed on teardown even
    /// if a test left read-only subdirectories behind.
    func makeScratchDirectory(_ label: String = "scratch") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WharfTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            Self.restorePermissions(under: url)
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    /// A defaults suite that is wiped on teardown. Never `.standard`.
    func makeIsolatedDefaults() -> UserDefaults {
        let name = "WharfTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
        }
        return defaults
    }

    /// Marks the rest of the test as a documented, unfixed defect. Only failed
    /// assertions are expected, so a thrown error from setup still fails the
    /// test, and the test fails loudly (strict) once the bug is fixed.
    func expectKnownBug(_ description: String) {
        let options = XCTExpectedFailure.Options()
        options.issueMatcher = { $0.type == .assertionFailure }
        XCTExpectFailure(description, options: options)
    }

    private static func restorePermissions(under root: URL) {
        let fm = FileManager.default
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        for case let item as URL in enumerator {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: item.path)
        }
    }
}

// MARK: - Image fixtures

enum ImageFixtures {
    /// A solid-color RGBA bitmap encoded as PNG, generated in memory.
    static func png(width: Int, height: Int) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        return encode(image, type: UTType.png)
    }

    static func jpeg(width: Int, height: Int) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return encode(context.makeImage()!, type: UTType.jpeg)
    }

    private static func encode(_ image: CGImage, type: UTType) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// A PNG that declares `width` x `height` 1-bit grayscale pixels. With
    /// `includePixelData` false only the header is written, so declaring
    /// 100000 x 100000 costs a few dozen bytes. With it true the all-zero
    /// pixel stream is deflated, so a 10000 x 10000 image is a real decodable
    /// pixel bomb that is only a few KB on disk.
    static func declaredSizePNG(width: Int, height: Int, includePixelData: Bool) -> Data {
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        var ihdr = Data()
        ihdr.append(bigEndian32(UInt32(width)))
        ihdr.append(bigEndian32(UInt32(height)))
        ihdr.append(contentsOf: [1, 0, 0, 0, 0]) // 1-bit, grayscale, deflate, no filter, no interlace
        png.append(chunk("IHDR", ihdr))

        if includePixelData {
            let rowBytes = (width + 7) / 8
            let raw = Data(count: height * (1 + rowBytes)) // filter byte 0 plus zero pixels
            png.append(chunk("IDAT", zlibWrap(raw)))
        }
        png.append(chunk("IEND", Data()))
        return png
    }

    private static func zlibWrap(_ raw: Data) -> Data {
        var scratch = [UInt8](repeating: 0, count: raw.count / 100 + 4096)
        let written = raw.withUnsafeBytes { source -> Int in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(&scratch, scratch.count, base, raw.count, nil, COMPRESSION_ZLIB)
        }
        precondition(written > 0, "scratch buffer too small for zero-filled stream")

        // Apple's COMPRESSION_ZLIB is raw DEFLATE, so add the zlib header and Adler-32 trailer.
        var out = Data([0x78, 0x01])
        out.append(contentsOf: scratch[0..<written])
        // The payload is all zero bytes, so Adler-32 collapses to a closed form.
        let a: UInt32 = 1
        let b = UInt32(raw.count % 65_521)
        out.append(bigEndian32((b << 16) | a))
        return out
    }

    private static func chunk(_ type: String, _ body: Data) -> Data {
        var out = Data()
        out.append(bigEndian32(UInt32(body.count)))
        var typed = Data(type.utf8)
        typed.append(body)
        out.append(typed)
        out.append(bigEndian32(CRC32.checksum(typed)))
        return out
    }

    private static func bigEndian32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var c = UInt32(index)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

// MARK: - ZIP writer

/// Minimal "stored" ZIP writer so tests can build archives with arbitrary
/// entry names (including `../` traversal) that `zip` or `ditto -c` would
/// refuse to produce.
enum ZIPFixture {
    struct Entry {
        let name: String
        let contents: Data
        /// Unix mode placed in the external attributes, e.g. 0o120777 for a symlink.
        var unixMode: UInt32 = 0o100644
    }

    static func archive(_ entries: [Entry]) -> Data {
        var body = Data()
        var central = Data()
        for entry in entries {
            let offset = UInt32(body.count)
            let name = Data(entry.name.utf8)
            let crc = CRC32.checksum(entry.contents)

            body.append(le32(0x0403_4B50))
            body.append(le16(20))
            body.append(le16(0))
            body.append(le16(0)) // stored
            body.append(le16(0))
            body.append(le16(0x21))
            body.append(le32(crc))
            body.append(le32(UInt32(entry.contents.count)))
            body.append(le32(UInt32(entry.contents.count)))
            body.append(le16(UInt16(name.count)))
            body.append(le16(0))
            body.append(name)
            body.append(entry.contents)

            central.append(le32(0x0201_4B50))
            central.append(le16(0x031E)) // made by Unix
            central.append(le16(20))
            central.append(le16(0))
            central.append(le16(0))
            central.append(le16(0))
            central.append(le16(0x21))
            central.append(le32(crc))
            central.append(le32(UInt32(entry.contents.count)))
            central.append(le32(UInt32(entry.contents.count)))
            central.append(le16(UInt16(name.count)))
            central.append(le16(0))
            central.append(le16(0))
            central.append(le16(0))
            central.append(le16(0))
            central.append(le32(entry.unixMode << 16))
            central.append(le32(offset))
            central.append(name)
        }

        var out = body
        let centralOffset = UInt32(out.count)
        out.append(central)
        out.append(le32(0x0605_4B50))
        out.append(le16(0))
        out.append(le16(0))
        out.append(le16(UInt16(entries.count)))
        out.append(le16(UInt16(entries.count)))
        out.append(le32(UInt32(central.count)))
        out.append(le32(centralOffset))
        out.append(le16(0))
        return out
    }

    private static func le16(_ value: UInt16) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func le32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}

// MARK: - URL stubbing

/// Answers every request from an in-memory closure. Install it through a
/// session configuration's `protocolClasses`; no packet leaves the process.
final class StubURLProtocol: URLProtocol {
    struct Stub {
        var status: Int = 200
        var body: Data = Data()
        var error: Error?
    }

    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> Stub)?
    private static var recorded: [URLRequest] = []

    static func install(_ handler: @escaping (URLRequest) -> Stub) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
        recorded = []
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        handler = nil
        recorded = []
    }

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append(request)
        let handler = Self.handler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }

        let stub = handler(request)
        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://invalid.example")!,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
