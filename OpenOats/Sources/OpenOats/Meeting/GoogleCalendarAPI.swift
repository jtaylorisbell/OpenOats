import Foundation

/// Errors that can be raised by Google Calendar REST calls.
enum GoogleAPIError: Error {
    case unauthorized
    case http(status: Int, body: String)
    case invalidResponse
}

// MARK: - Wire Types

struct GoogleCalendarSummary: Sendable, Decodable {
    let id: String
    let summary: String
    let backgroundColor: String?
    let primary: Bool?
    /// `selected` is whether the calendar is shown in the user's Google Calendar UI.
    /// Defaults to `true` per the Google docs.
    let selected: Bool?
}

private struct GoogleCalendarListResponse: Decodable {
    let items: [GoogleCalendarSummary]
}

struct GoogleEvent: Sendable, Decodable {
    let id: String
    let summary: String?
    let start: GoogleEventDateTime
    let end: GoogleEventDateTime
    let recurringEventId: String?
    let hangoutLink: String?
    let location: String?
    let description: String?
    let organizer: GoogleEventPerson?
    let attendees: [GoogleEventPerson]?
    let conferenceData: GoogleConferenceData?
}

struct GoogleEventDateTime: Sendable, Decodable {
    let dateTime: String?
    let date: String?
    let timeZone: String?
}

struct GoogleEventPerson: Sendable, Decodable {
    let displayName: String?
    let email: String?
}

struct GoogleConferenceData: Sendable, Decodable {
    let entryPoints: [GoogleConferenceEntryPoint]?
}

struct GoogleConferenceEntryPoint: Sendable, Decodable {
    let entryPointType: String?
    let uri: String?
}

private struct GoogleEventsResponse: Decodable {
    let items: [GoogleEvent]
}

// MARK: - API client

/// Minimal Google Calendar v3 client backed by URLSession.
struct GoogleCalendarAPI: Sendable {
    let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    func fetchCalendarList(accessToken: String) async throws -> [GoogleCalendarSummary] {
        let url = URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList?fields=items(id,summary,backgroundColor,primary,selected)")!
        let data = try await get(url: url, accessToken: accessToken)
        do {
            return try JSONDecoder().decode(GoogleCalendarListResponse.self, from: data).items
        } catch {
            throw GoogleAPIError.invalidResponse
        }
    }

    func fetchEvents(
        accessToken: String,
        calendarID: String,
        timeMin: Date,
        timeMax: Date
    ) async throws -> [GoogleEvent] {
        guard let encodedID = calendarID
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw GoogleAPIError.invalidResponse
        }
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedID)/events")!
        components.queryItems = [
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "timeMin", value: Self.iso8601(timeMin)),
            URLQueryItem(name: "timeMax", value: Self.iso8601(timeMax)),
            URLQueryItem(name: "maxResults", value: "250"),
        ]
        guard let url = components.url else {
            throw GoogleAPIError.invalidResponse
        }
        let data = try await get(url: url, accessToken: accessToken)
        do {
            return try JSONDecoder().decode(GoogleEventsResponse.self, from: data).items
        } catch {
            throw GoogleAPIError.invalidResponse
        }
    }

    private func get(url: URL, accessToken: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw GoogleAPIError.unauthorized
        }
        guard (200..<300).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GoogleAPIError.http(status: status, body: body)
        }
        return data
    }
}

// MARK: - GoogleEvent → CalendarEvent

enum GoogleEventMapper {
    static func calendarEvent(from event: GoogleEvent, calendar: GoogleCalendarSummary) -> CalendarEvent? {
        guard let startDate = parseDate(event.start) else { return nil }
        let endDate = parseDate(event.end) ?? startDate.addingTimeInterval(30 * 60)
        // Skip all-day events (date-only, no time) — matches Apple-source behaviour.
        if event.start.dateTime == nil { return nil }

        let meetingURL = meetingURL(from: event)
        let isOnline = meetingURL != nil
            || (event.location?.lowercased().contains("meet") ?? false)
            || (event.location?.lowercased().contains("zoom") ?? false)

        return CalendarEvent(
            id: CalendarSourceID.google.prefix + event.id,
            title: event.summary ?? "Untitled Event",
            startDate: startDate,
            endDate: endDate,
            externalIdentifier: event.recurringEventId ?? event.id,
            calendarID: CalendarSourceID.google.prefix + calendar.id,
            calendarTitle: calendar.summary,
            calendarColorHex: calendar.backgroundColor,
            organizer: event.organizer?.displayName ?? event.organizer?.email,
            participants: (event.attendees ?? []).map {
                Participant(name: $0.displayName, email: $0.email)
            },
            isOnlineMeeting: isOnline,
            meetingURL: meetingURL
        )
    }

    private static func parseDate(_ value: GoogleEventDateTime) -> Date? {
        if let raw = value.dateTime {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: raw) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: raw)
        }
        return nil
    }

    private static func meetingURL(from event: GoogleEvent) -> URL? {
        if let video = event.conferenceData?.entryPoints?
            .first(where: { $0.entryPointType == "video" })?.uri,
           let url = URL(string: video) {
            return url
        }
        if let hangoutLink = event.hangoutLink, let url = URL(string: hangoutLink) {
            return url
        }
        // Fall back to the existing meeting-link resolver applied to description/location.
        return CalendarMeetingLinkResolver.meetingURL(
            rawURL: nil,
            notes: event.description,
            location: event.location
        )
    }
}
