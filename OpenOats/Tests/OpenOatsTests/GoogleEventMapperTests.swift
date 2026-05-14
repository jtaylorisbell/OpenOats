import XCTest
@testable import OpenOatsKit

final class GoogleEventMapperTests: XCTestCase {
    private let calendar = GoogleCalendarSummary(
        id: "primary@example.com",
        summary: "Work",
        backgroundColor: "#ABCDEF",
        primary: true,
        selected: true
    )

    func testMapsTimedEventWithHangoutLink() throws {
        let raw = makeEvent(
            id: "abc123",
            summary: "Design Review",
            startISO: "2026-05-13T10:00:00-07:00",
            endISO: "2026-05-13T11:00:00-07:00",
            hangoutLink: "https://meet.google.com/xyz-abc"
        )

        let event = try XCTUnwrap(GoogleEventMapper.calendarEvent(from: raw, calendar: calendar))

        XCTAssertEqual(event.id, "google:abc123")
        XCTAssertEqual(event.title, "Design Review")
        XCTAssertEqual(event.calendarID, "google:primary@example.com")
        XCTAssertEqual(event.calendarTitle, "Work")
        XCTAssertEqual(event.calendarColorHex, "#ABCDEF")
        XCTAssertEqual(event.meetingURL?.absoluteString, "https://meet.google.com/xyz-abc")
        XCTAssertTrue(event.isOnlineMeeting)
    }

    func testPrefersConferenceDataVideoEntryPoint() throws {
        let raw = GoogleEvent(
            id: "abc",
            summary: "Standup",
            start: GoogleEventDateTime(dateTime: "2026-05-13T09:00:00-07:00", date: nil, timeZone: nil),
            end: GoogleEventDateTime(dateTime: "2026-05-13T09:30:00-07:00", date: nil, timeZone: nil),
            recurringEventId: nil,
            hangoutLink: "https://meet.google.com/legacy-link",
            location: nil,
            description: nil,
            organizer: nil,
            attendees: nil,
            conferenceData: GoogleConferenceData(entryPoints: [
                GoogleConferenceEntryPoint(entryPointType: "more", uri: "tel:+1-555-555-5555"),
                GoogleConferenceEntryPoint(entryPointType: "video", uri: "https://meet.google.com/new-link"),
            ])
        )

        let event = try XCTUnwrap(GoogleEventMapper.calendarEvent(from: raw, calendar: calendar))
        XCTAssertEqual(event.meetingURL?.absoluteString, "https://meet.google.com/new-link")
    }

    func testSkipsAllDayEvents() {
        let raw = GoogleEvent(
            id: "all-day",
            summary: "Holiday",
            start: GoogleEventDateTime(dateTime: nil, date: "2026-05-13", timeZone: nil),
            end: GoogleEventDateTime(dateTime: nil, date: "2026-05-14", timeZone: nil),
            recurringEventId: nil,
            hangoutLink: nil,
            location: nil,
            description: nil,
            organizer: nil,
            attendees: nil,
            conferenceData: nil
        )

        XCTAssertNil(GoogleEventMapper.calendarEvent(from: raw, calendar: calendar))
    }

    func testRecurringSeriesIDIsPreservedInExternalIdentifier() throws {
        let raw = makeEvent(
            id: "abc_2026",
            summary: "Weekly 1:1",
            startISO: "2026-05-13T10:00:00-07:00",
            endISO: "2026-05-13T10:30:00-07:00",
            recurringEventId: "abc-series"
        )

        let event = try XCTUnwrap(GoogleEventMapper.calendarEvent(from: raw, calendar: calendar))
        XCTAssertEqual(event.externalIdentifier, "abc-series")
    }

    func testNoMeetingLinkInferredFromNonMeetingDescription() throws {
        let raw = GoogleEvent(
            id: "abc",
            summary: "Doc review",
            start: GoogleEventDateTime(dateTime: "2026-05-13T10:00:00-07:00", date: nil, timeZone: nil),
            end: GoogleEventDateTime(dateTime: "2026-05-13T10:30:00-07:00", date: nil, timeZone: nil),
            recurringEventId: nil,
            hangoutLink: nil,
            location: "Conference Room A",
            description: "Background reading: https://docs.example.com/page",
            organizer: nil,
            attendees: nil,
            conferenceData: nil
        )

        let event = try XCTUnwrap(GoogleEventMapper.calendarEvent(from: raw, calendar: calendar))
        XCTAssertNil(event.meetingURL)
        XCTAssertFalse(event.isOnlineMeeting)
    }

    // MARK: - Helpers

    private func makeEvent(
        id: String,
        summary: String,
        startISO: String,
        endISO: String,
        hangoutLink: String? = nil,
        recurringEventId: String? = nil
    ) -> GoogleEvent {
        GoogleEvent(
            id: id,
            summary: summary,
            start: GoogleEventDateTime(dateTime: startISO, date: nil, timeZone: nil),
            end: GoogleEventDateTime(dateTime: endISO, date: nil, timeZone: nil),
            recurringEventId: recurringEventId,
            hangoutLink: hangoutLink,
            location: nil,
            description: nil,
            organizer: nil,
            attendees: nil,
            conferenceData: nil
        )
    }
}
