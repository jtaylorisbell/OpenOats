import AppKit
import EventKit
import Foundation

/// `CalendarSource` backed by Apple's EventKit (`EKEventStore`).
/// All event identifiers it emits are namespaced with the `apple:` prefix.
@MainActor
@Observable
final class AppleCalendarSource: CalendarSource {
    @ObservationIgnored private let store = EKEventStore()

    let sourceID: CalendarSourceID = .apple

    private(set) var accessState: CalendarAccessState

    init() {
        self.accessState = Self.currentAccessState()
    }

    func refreshFromSystem() {
        let current = Self.currentAccessState()
        if current != accessState {
            accessState = current
        }
    }

    func requestAccess() async -> Bool {
        do {
            let granted = try await store.requestFullAccessToEvents()
            accessState = granted ? .authorized : .denied
            return granted
        } catch {
            accessState = .denied
            return false
        }
    }

    func currentEvent(at date: Date, excludingCalendarIDs: Set<String>) -> CalendarEvent? {
        guard accessState == .authorized else { return nil }
        let calendars = eventCalendars(excludingCalendarIDs: excludingCalendarIDs)
        guard !calendars.isEmpty else { return nil }

        let windowStart = date.addingTimeInterval(-15 * 60)
        let windowEnd = date.addingTimeInterval(15 * 60)

        let predicate = store.predicateForEvents(
            withStart: windowStart,
            end: windowEnd,
            calendars: calendars
        )
        let events = store.events(matching: predicate)

        let best = events
            .filter { !$0.isAllDay }
            .min { a, b in
                let distA = abs(a.startDate.timeIntervalSince(date))
                let distB = abs(b.startDate.timeIntervalSince(date))
                if distA != distB { return distA < distB }
                return a.startDate < b.startDate
            }

        return best.map { CalendarEvent(from: $0) }
    }

    func upcomingEvents(
        from date: Date,
        within window: TimeInterval,
        limit: Int,
        excludingCalendarIDs: Set<String>
    ) -> [CalendarEvent] {
        guard accessState == .authorized else { return [] }
        let calendars = eventCalendars(excludingCalendarIDs: excludingCalendarIDs)
        guard !calendars.isEmpty else { return [] }

        let windowEnd = date.addingTimeInterval(window)
        let predicate = store.predicateForEvents(
            withStart: date,
            end: windowEnd,
            calendars: calendars
        )
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.startDate >= date }
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)

        return events.map { CalendarEvent(from: $0) }
    }

    func events(onSameDayAs date: Date, excludingCalendarIDs: Set<String>) -> [CalendarEvent] {
        guard accessState == .authorized else { return [] }
        let calendars = eventCalendars(excludingCalendarIDs: excludingCalendarIDs)
        guard !calendars.isEmpty else { return [] }
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return []
        }

        let predicate = store.predicateForEvents(
            withStart: startOfDay,
            end: endOfDay,
            calendars: calendars
        )
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }

        return events.map { CalendarEvent(from: $0) }
    }

    func availableCalendars() -> [AvailableCalendar] {
        guard accessState == .authorized else { return [] }
        return eventCalendars()
            .map { calendar in
                AvailableCalendar(
                    id: CalendarSourceID.apple.prefix + calendar.calendarIdentifier,
                    title: calendar.title,
                    sourceTitle: calendar.source.title.nilIfBlank,
                    colorHex: CalendarColorCodec.hexString(from: calendar.cgColor)
                )
            }
            .sorted { lhs, rhs in
                let lhsSource = lhs.sourceTitle ?? ""
                let rhsSource = rhs.sourceTitle ?? ""
                let sourceComparison = lhsSource.localizedCaseInsensitiveCompare(rhsSource)
                if sourceComparison != .orderedSame {
                    return sourceComparison == .orderedAscending
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    // MARK: - Internals

    private func eventCalendars(excludingCalendarIDs: Set<String> = []) -> [EKCalendar] {
        store.calendars(for: .event)
            .filter { !excludingCalendarIDs.contains($0.calendarIdentifier) }
    }

    private static func currentAccessState() -> CalendarAccessState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return .authorized
        case .notDetermined:
            return .notDetermined
        default:
            return .denied
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - EKEvent → CalendarEvent

extension CalendarEvent {
    init(from event: EKEvent) {
        let meetingURL = CalendarMeetingLinkResolver.meetingURL(
            rawURL: event.url,
            notes: event.notes,
            location: event.location
        )
        self.init(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? "Untitled Event",
            startDate: event.startDate,
            endDate: event.endDate,
            externalIdentifier: event.calendarItemExternalIdentifier,
            calendarID: CalendarSourceID.apple.prefix + event.calendar.calendarIdentifier,
            calendarTitle: event.calendar.title,
            calendarColorHex: CalendarColorCodec.hexString(from: event.calendar.cgColor),
            organizer: event.organizer?.name,
            participants: (event.attendees ?? []).map { Participant(from: $0) },
            isOnlineMeeting: CalendarMeetingLinkResolver.isOnlineMeeting(
                rawURL: event.url,
                notes: event.notes,
                location: event.location
            ),
            meetingURL: meetingURL
        )
    }
}

extension Participant {
    init(from attendee: EKParticipant) {
        self.init(
            name: attendee.name,
            email: attendee.url.absoluteString
                .replacingOccurrences(of: "mailto:", with: "")
        )
    }
}

enum CalendarMeetingLinkResolver {
    private static let hostHints = [
        "zoom.us",
        "teams.microsoft",
        "teams.live",
        "meet.google",
        "webex",
        "whereby.com",
        "around.co",
        "jitsi",
        "chime.aws",
        "gotomeeting",
        "bluejeans",
        "facetime",
    ]

    private static let textHints = [
        "zoom",
        "teams",
        "meet",
        "webex",
        "facetime",
        "join",
    ]

    static func meetingURL(rawURL: URL?, notes: String?, location: String?) -> URL? {
        if let rawURL {
            return rawURL
        }

        let candidates = detectedURLs(in: notes) + detectedURLs(in: location)

        if let preferred = candidates.first(where: isLikelyMeetingURL) {
            return preferred
        }

        return nil
    }

    static func isOnlineMeeting(rawURL: URL?, notes: String?, location: String?) -> Bool {
        if meetingURL(rawURL: rawURL, notes: notes, location: location) != nil {
            return true
        }

        let haystack = "\(notes ?? "")\n\(location ?? "")".lowercased()
        return textHints.contains { haystack.contains($0) }
    }

    private static func detectedURLs(in text: String?) -> [URL] {
        guard let text, !text.isEmpty else { return [] }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, options: [], range: nsRange).compactMap { match in
            guard let url = match.url else { return nil }
            guard let scheme = url.scheme?.lowercased() else { return nil }
            guard scheme == "http" || scheme == "https" || scheme == "facetime" else {
                return nil
            }
            return url
        }
    }

    private static func isLikelyMeetingURL(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "facetime" {
            return true
        }

        let host = url.host?.lowercased() ?? ""
        if hostHints.contains(where: host.contains) {
            return true
        }

        let absolute = url.absoluteString.lowercased()
        return textHints.contains(where: absolute.contains)
    }
}

enum CalendarColorCodec {
    static func hexString(from cgColor: CGColor?) -> String? {
        guard let cgColor,
              let nsColor = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB) else { return nil }

        let red = Int(round(nsColor.redComponent * 255))
        let green = Int(round(nsColor.greenComponent * 255))
        let blue = Int(round(nsColor.blueComponent * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
