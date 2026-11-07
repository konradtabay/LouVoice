import XCTest
@testable import LouVoiceCore

/// Wraps the shared self-tests for `swift test` (needs Xcode's XCTest).
final class SelfTestsTests: XCTestCase {
    func testAllChecks() {
        for test in SelfTests.all {
            XCTAssertNoThrow(try test.run(), test.name)
        }
    }
}
