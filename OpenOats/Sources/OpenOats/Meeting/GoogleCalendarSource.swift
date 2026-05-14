import AppKit
import Foundation

/// `CalendarSource` backed by Google Calendar v3 via OAuth 2.0.
///
/// Maintains a local in-memory cache of events for the next ~24h so synchronous reads
/// (used in the meeting-detection hot path) never block on the network. The cache is
/// refreshed in the background on a timer and on demand via `refreshFromSystem()`.
@MainActor
@Observable
final class GoogleCalendarSource: CalendarSource {
    let sourceID: CalendarSourceID = .google

    private(set) var accessState: CalendarAccessState = .notDetermined
    private(set) var accountEmail: String?

    @ObservationIgnored private let oauth: GoogleOAuthClient
    @ObservationIgnored private let api: GoogleCalendarAPI
    @ObservationIgnored private var cachedCalendars: [GoogleCalendarSummary] = []
    @ObservationIgnored private var cachedEvents: [CalendarEvent] = []
    @ObservationIgnored private var lastRefreshAt: Date?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// Minimum interval between automatic background refreshes.
    private let backgroundRefreshInterval: TimeInterval = 5 * 60

    init(
        oauth: GoogleOAuthClient,
        api: GoogleCalendarAPI = GoogleCalendarAPI()
    ) {
        self.oauth = oauth
        self.api = api
        self.accessState = oauth.hasStoredTokens ? .authorized : .notDetermined
        self.accountEmail = oauth.storedAccountEmail
        if accessState == .authorized {
            scheduleRefresh()
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    // MARK: - CalendarSource

    func refreshFromSystem() {
        let newState: CalendarAccessState = oauth.hasStoredTokens ? .authorized : .notDetermined
        if newState != accessState {
            accessState = newState
        }
        accountEmail = oauth.storedAccountEmail
        if accessState == .authorized,
           lastRefreshAt == nil || Date().timeIntervalSince(lastRefreshAt ?? .distantPast) > backgroundRefreshInterval {
            scheduleRefresh()
        }
    }

    /// Kick off the OAuth flow. Returns true on successful sign-in.
    func requestAccess() async -> Bool {
        do {
            let email = try await oauth.authorize()
            accountEmail = email
            accessState = .authorized
            await refresh()
            return true
        } catch {
            accessState = .denied
            return false
        }
    }

    /// Sign out — clears stored tokens, clears the cache.
    func disconnect() {
        refreshTask?.cancel()
        refreshTask = nil
        oauth.signOut()
        accessState = .notDetermined
        accountEmail = nil
        cachedCalendars = []
        cachedEvents = []
        lastRefreshAt = nil
    }

    func currentEvent(at date: Date, excludingCalendarIDs: Set<String>) -> CalendarEvent? {
        guard accessState == .authorized else { return nil }
        let windowStart = date.addingTimeInterval(-15 * 60)
        let windowEnd = date.addingTimeInterval(15 * 60)
        let candidates = cachedEvents.filter { event in
            guard let rawCalendarID = stripPrefix(event.calendarID),
                  !excludingCalendarIDs.contains(rawCalendarID) else { return false }
            return event.startDate < windowEnd && event.endDate > windowStart
        }
        return candidates.min { a, b in
            let distA = abs(a.startDate.timeIntervalSince(date))
            let distB = abs(b.startDate.timeIntervalSince(date))
            if distA != distB { return distA < distB }
            return a.startDate < b.startDate
        }
    }

    func upcomingEvents(
        from date: Date,
        within window: TimeInterval,
        limit: Int,
        excludingCalendarIDs: Set<String>
    ) -> [CalendarEvent] {
        guard accessState == .authorized else { return [] }
        let end = date.addingTimeInterval(window)
        let filtered = cachedEvents
            .filter { event in
                guard event.startDate >= date && event.startDate < end else { return false }
                guard let rawCalendarID = stripPrefix(event.calendarID) else { return false }
                return !excludingCalendarIDs.contains(rawCalendarID)
            }
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)
        return Array(filtered)
    }

    func events(onSameDayAs date: Date, excludingCalendarIDs: Set<String>) -> [CalendarEvent] {
        guard accessState == .authorized else { return [] }
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return []
        }
        return cachedEvents
            .filter { event in
                guard event.startDate >= startOfDay && event.startDate < endOfDay else { return false }
                guard let rawCalendarID = stripPrefix(event.calendarID) else { return false }
                return !excludingCalendarIDs.contains(rawCalendarID)
            }
            .sorted { $0.startDate < $1.startDate }
    }

    func availableCalendars() -> [AvailableCalendar] {
        guard accessState == .authorized else { return [] }
        return cachedCalendars.map { calendar in
            AvailableCalendar(
                id: CalendarSourceID.google.prefix + calendar.id,
                title: calendar.summary,
                sourceTitle: accountEmail ?? "Google",
                colorHex: calendar.backgroundColor
            )
        }
    }

    // MARK: - Refresh

    /// Force-refresh calendars and events from Google now.
    func refresh() async {
        guard accessState == .authorized else { return }
        do {
            let token = try await oauth.accessToken()
            let calendars = try await api.fetchCalendarList(accessToken: token)
            let now = Date()
            let timeMin = now.addingTimeInterval(-2 * 60 * 60)
            let timeMax = now.addingTimeInterval(7 * 24 * 60 * 60)

            var fetched: [CalendarEvent] = []
            for calendar in calendars where calendar.selected != false {
                let events = try await api.fetchEvents(
                    accessToken: token,
                    calendarID: calendar.id,
                    timeMin: timeMin,
                    timeMax: timeMax
                )
                let mapped = events.compactMap {
                    GoogleEventMapper.calendarEvent(from: $0, calendar: calendar)
                }
                fetched.append(contentsOf: mapped)
            }

            cachedCalendars = calendars
            cachedEvents = fetched
            lastRefreshAt = Date()
        } catch GoogleAPIError.unauthorized {
            // Refresh token rejected — clear state and require re-auth.
            oauth.signOut()
            accessState = .notDetermined
            accountEmail = nil
            cachedCalendars = []
            cachedEvents = []
        } catch {
            // Transient error — keep cache, try again on next tick.
        }
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(backgroundRefreshInterval))
                guard !Task.isCancelled else { break }
                await self.refresh()
            }
        }
    }

    private func stripPrefix(_ namespacedID: String?) -> String? {
        guard let namespacedID else { return nil }
        let prefix = CalendarSourceID.google.prefix
        guard namespacedID.hasPrefix(prefix) else { return nil }
        return String(namespacedID.dropFirst(prefix.count))
    }
}
