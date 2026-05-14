import Foundation

/// Stable identifier for a calendar source kind.
/// Used to namespace per-source calendar identifiers (e.g. "apple:<id>", "google:<id>")
/// so multiple sources can coexist without collisions in persisted settings.
enum CalendarSourceID: String, Sendable, Hashable, Codable {
    case apple
    case google

    var prefix: String { "\(rawValue):" }
}

/// Authorization status of a calendar source.
enum CalendarAccessState: Sendable, Hashable {
    case notDetermined
    case authorized
    case denied
}

/// A user-visible calendar inside a source (e.g. an iCloud calendar, or a Google calendar).
/// `id` is always namespaced with the source prefix.
struct AvailableCalendar: Sendable, Hashable, Identifiable {
    let id: String
    let title: String
    let sourceTitle: String?
    let colorHex: String?
}

/// Abstracts a backing calendar provider (Apple EventKit, Google Calendar, ...).
/// Implementations are responsible for emitting namespaced calendar IDs and for accepting
/// the same namespaced IDs in `excludingCalendarIDs` parameters.
///
/// All read methods are synchronous; sources that talk to the network (Google) should
/// maintain a local cache and refresh it asynchronously.
@MainActor
protocol CalendarSource: AnyObject {
    /// Source kind. Determines the ID namespace ("apple:" / "google:").
    var sourceID: CalendarSourceID { get }

    /// Current authorization / connection status.
    var accessState: CalendarAccessState { get }

    /// Re-read the latest authorization status from the system or remote service.
    /// Must be cheap and side-effect free (no UI dialogs, no network calls beyond cache validation).
    func refreshFromSystem()

    /// Prompt the user / OAuth flow to grant access. Returns true on success.
    func requestAccess() async -> Bool

    /// Event currently overlapping `date`, if any. Returns nil if not authorized.
    func currentEvent(at date: Date, excludingCalendarIDs: Set<String>) -> CalendarEvent?

    /// Upcoming events in a window, ordered by start date.
    func upcomingEvents(
        from date: Date,
        within window: TimeInterval,
        limit: Int,
        excludingCalendarIDs: Set<String>
    ) -> [CalendarEvent]

    /// Events occurring on the same local day as `date`.
    func events(onSameDayAs date: Date, excludingCalendarIDs: Set<String>) -> [CalendarEvent]

    /// Calendars the user could choose to include / exclude. Returns [] if not authorized.
    func availableCalendars() -> [AvailableCalendar]
}
