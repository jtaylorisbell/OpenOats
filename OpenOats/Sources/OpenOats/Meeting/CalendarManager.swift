import AppKit
import EventKit
import Foundation

/// Coordinator that exposes a unified calendar interface across multiple sources
/// (Apple EventKit, Google Calendar, ...).
///
/// The rest of the app interacts only with `CalendarManager`. Source-specific behaviour
/// (auth, fetching, caching) lives in `CalendarSource` implementations.
///
/// Calendar identifiers everywhere outside of source implementations are *namespaced*:
/// `"apple:<EK-id>"` or `"google:<gcal-id>"`. Pre-existing un-namespaced excluded IDs
/// (from before this refactor) are treated as `"apple:<id>"` for backwards compatibility.
@MainActor
@Observable
final class CalendarManager {
    private let appleSource: AppleCalendarSource
    private var googleSource: GoogleCalendarSource?

    /// Aggregated access state. `authorized` if any enabled source is authorized.
    /// Falls back to the most restrictive non-authorized state otherwise.
    private(set) var accessState: CalendarAccessState

    init(
        appleSource: AppleCalendarSource = AppleCalendarSource(),
        googleSource: GoogleCalendarSource? = nil
    ) {
        self.appleSource = appleSource
        self.googleSource = googleSource
        self.accessState = Self.aggregateAccessState(apple: appleSource, google: googleSource)
    }

    // MARK: - Sources

    /// Connect a Google Calendar source (or replace an existing one).
    /// Pass `nil` to remove the Google source entirely.
    func setGoogleSource(_ source: GoogleCalendarSource?) {
        googleSource = source
        accessState = Self.aggregateAccessState(apple: appleSource, google: source)
    }

    /// Returns the connected Google source, if any.
    var connectedGoogleSource: GoogleCalendarSource? { googleSource }

    /// Returns the access state of just the Apple source — used by UI that distinguishes
    /// between system-level Calendar permission and overall connectivity.
    var appleAccessState: CalendarAccessState { appleSource.accessState }

    // MARK: - Authorization

    /// Re-reads source authorization status. Never shows a dialog.
    func refreshFromSystem() {
        appleSource.refreshFromSystem()
        googleSource?.refreshFromSystem()
        accessState = Self.aggregateAccessState(apple: appleSource, google: googleSource)
    }

    /// Request Apple Calendar access. Returns true if authorized.
    /// Google access is requested via the dedicated OAuth flow (see `GoogleCalendarSource`).
    func requestAccess() async -> Bool {
        let granted = await appleSource.requestAccess()
        accessState = Self.aggregateAccessState(apple: appleSource, google: googleSource)
        return granted
    }

    // MARK: - Aggregated Lookups

    func currentEvent(
        at date: Date = Date(),
        excludingCalendarIDs: [String] = []
    ) -> CalendarEvent? {
        let routed = routeExclusions(excludingCalendarIDs)
        let appleEvent = appleSource.currentEvent(at: date, excludingCalendarIDs: routed.apple)
        let googleEvent = googleSource?.currentEvent(at: date, excludingCalendarIDs: routed.google)
        return bestMatch(appleEvent, googleEvent, target: date)
    }

    func upcomingEvents(
        from date: Date = Date(),
        within window: TimeInterval = 12 * 60 * 60,
        limit: Int = 5,
        excludingCalendarIDs: [String] = []
    ) -> [CalendarEvent] {
        let routed = routeExclusions(excludingCalendarIDs)
        var combined = appleSource.upcomingEvents(
            from: date,
            within: window,
            limit: limit,
            excludingCalendarIDs: routed.apple
        )
        if let googleSource {
            combined.append(contentsOf: googleSource.upcomingEvents(
                from: date,
                within: window,
                limit: limit,
                excludingCalendarIDs: routed.google
            ))
        }
        return Array(
            combined
                .sorted { $0.startDate < $1.startDate }
                .prefix(limit)
        )
    }

    func events(
        onSameDayAs date: Date = Date(),
        excludingCalendarIDs: [String] = []
    ) -> [CalendarEvent] {
        let routed = routeExclusions(excludingCalendarIDs)
        var combined = appleSource.events(onSameDayAs: date, excludingCalendarIDs: routed.apple)
        if let googleSource {
            combined.append(contentsOf: googleSource.events(
                onSameDayAs: date,
                excludingCalendarIDs: routed.google
            ))
        }
        return combined.sorted { $0.startDate < $1.startDate }
    }

    func availableCalendars() -> [AvailableCalendar] {
        var calendars: [AvailableCalendar] = []
        calendars.append(contentsOf: appleSource.availableCalendars())
        if let googleSource {
            calendars.append(contentsOf: googleSource.availableCalendars())
        }
        return calendars
    }

    // MARK: - Helpers

    /// Splits caller-supplied excluded IDs by source. Un-namespaced IDs are assumed Apple
    /// (legacy persisted data from before multi-source support).
    /// `internal` for unit tests.
    func routeExclusions(_ ids: [String]) -> (apple: Set<String>, google: Set<String>) {
        var apple: Set<String> = []
        var google: Set<String> = []
        for raw in ids {
            if raw.hasPrefix(CalendarSourceID.apple.prefix) {
                apple.insert(String(raw.dropFirst(CalendarSourceID.apple.prefix.count)))
            } else if raw.hasPrefix(CalendarSourceID.google.prefix) {
                google.insert(String(raw.dropFirst(CalendarSourceID.google.prefix.count)))
            } else {
                // Legacy un-namespaced IDs are Apple identifiers.
                apple.insert(raw)
            }
        }
        return (apple, google)
    }

    private func bestMatch(
        _ a: CalendarEvent?,
        _ b: CalendarEvent?,
        target: Date
    ) -> CalendarEvent? {
        switch (a, b) {
        case (nil, nil): return nil
        case let (some?, nil): return some
        case let (nil, some?): return some
        case let (l?, r?):
            let distL = abs(l.startDate.timeIntervalSince(target))
            let distR = abs(r.startDate.timeIntervalSince(target))
            return distL <= distR ? l : r
        }
    }

    private static func aggregateAccessState(
        apple: AppleCalendarSource,
        google: GoogleCalendarSource?
    ) -> CalendarAccessState {
        let states = [apple.accessState, google?.accessState].compactMap { $0 }
        if states.contains(.authorized) { return .authorized }
        if states.contains(.notDetermined) { return .notDetermined }
        return .denied
    }
}
