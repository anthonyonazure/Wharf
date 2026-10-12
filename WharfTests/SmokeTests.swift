import XCTest
@testable import Wharf

/// Proves the hosted test bundle loads inside Wharf.app without starting the dock.
final class SmokeTests: XCTestCase {
    func testHostedBundleLoads() {
        XCTAssertNotNil(Bundle.main.bundleIdentifier)
    }
}
