import XCTest
@testable import OpenOatsKit

/// Exercises `CalendarManager.routeExclusions` — the function that decides whether
/// each excluded calendar ID belongs to Apple, Google, or (for legacy un-namespaced
/// IDs) Apple by default. Other multi-source behaviour is covered by integration tests.
@MainActor
final class CalendarManagerRoutingTests: XCTestCase {
    func testRoutesAppleAndGoogleIDsToTheirNamespaces() {
        let manager = CalendarManager()
        let (apple, google) = manager.routeExclusions([
            "apple:ICAL-CAL-1",
            "google:work@example.com",
            "google:secondary",
        ])
        XCTAssertEqual(apple, ["ICAL-CAL-1"])
        XCTAssertEqual(google, ["work@example.com", "secondary"])
    }

    func testLegacyUnnamespacedIDsAreTreatedAsApple() {
        let manager = CalendarManager()
        let (apple, google) = manager.routeExclusions([
            "ICAL-CAL-1",
            "ICAL-CAL-2",
            "google:work@example.com",
        ])
        XCTAssertEqual(apple, ["ICAL-CAL-1", "ICAL-CAL-2"])
        XCTAssertEqual(google, ["work@example.com"])
    }

    func testEmptyInputProducesEmptyBuckets() {
        let manager = CalendarManager()
        let (apple, google) = manager.routeExclusions([])
        XCTAssertTrue(apple.isEmpty)
        XCTAssertTrue(google.isEmpty)
    }

    func testAppleEnabledDefaultsTrueAndCanBeToggled() {
        let manager = CalendarManager()
        XCTAssertTrue(manager.appleEnabled)
        manager.setAppleEnabled(false)
        XCTAssertFalse(manager.appleEnabled)
        manager.setAppleEnabled(true)
        XCTAssertTrue(manager.appleEnabled)
    }

    func testDisablingAppleExcludesAppleCalendarsFromAvailable() {
        // No google source attached → availableCalendars should be empty when apple is disabled.
        let manager = CalendarManager()
        manager.setAppleEnabled(false)
        // We don't have access to real EventKit calendars in tests; the point is that
        // availableCalendars short-circuits the apple branch and returns no apple entries.
        let calendars = manager.availableCalendars()
        XCTAssertTrue(calendars.allSatisfy { !$0.id.hasPrefix("apple:") })
    }
}
