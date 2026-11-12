import XCTest
@testable import VagrantCore

final class AppVersionTests: XCTestCase {
    func testParsesAndStripsLeadingV() {
        XCTAssertEqual(AppVersion("v1.2.3"), AppVersion("1.2.3"))
        XCTAssertEqual(AppVersion("V2.0"), AppVersion("2.0.0"))
    }

    func testMissingComponentsTreatedAsZero() {
        XCTAssertEqual(AppVersion("1.2"), AppVersion("1.2.0"))
        XCTAssertLessThan(AppVersion("1"), AppVersion("1.0.1"))
    }

    func testOrdersNumericallyNotLexically() {
        XCTAssertGreaterThan(AppVersion("1.10.0"), AppVersion("1.9.0"))
        XCTAssertGreaterThan(AppVersion("2.0.0"), AppVersion("1.99.99"))
    }

    func testIsNewerMatchesGreaterThan() {
        XCTAssertTrue(AppVersion("1.1.0").isNewer(than: AppVersion("1.0.0")))
        XCTAssertFalse(AppVersion("1.0.0").isNewer(than: AppVersion("1.0.0")))
        XCTAssertFalse(AppVersion("1.0.0").isNewer(than: AppVersion("1.1.0")))
    }

    func testMalformedComponentsBecomeZero() {
        XCTAssertEqual(AppVersion("1.x.3"), AppVersion("1.0.3"))
    }

    func testDescriptionIsDottedComponents() {
        XCTAssertEqual(AppVersion("v0.0.1").description, "0.0.1")
    }
}
