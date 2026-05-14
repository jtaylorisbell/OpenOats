import AppKit
import SwiftUI

struct CalendarSettingsTab: View {
    @Bindable var settings: AppSettings
    @Environment(AppContainer.self) private var container

    @State private var accessState: CalendarAccessState = .notDetermined
    @State private var availableCalendars: [AvailableCalendar] = []
    @State private var refreshTick: Int = 0
    @State private var isManualRefreshInFlight = false
    @State private var showReloadSuccess = false
    @State private var reloadErrorMessage: String?

    @State private var googleSignInInProgress = false
    @State private var googleSignInError: String?

    private struct CalendarSourceGroup: Identifiable {
        let title: String
        let calendars: [AvailableCalendar]

        var id: String { title }
    }

    private enum CalendarSourceChoice: Hashable {
        case none, apple, google
    }

    private var currentSourceChoice: CalendarSourceChoice {
        if settings.googleCalendarEnabled { return .google }
        if settings.calendarIntegrationEnabled { return .apple }
        return .none
    }

    private var calendarSourceBinding: Binding<CalendarSourceChoice> {
        Binding(
            get: { currentSourceChoice },
            set: { newValue in
                switch newValue {
                case .none:
                    settings.googleCalendarEnabled = false
                    settings.calendarIntegrationEnabled = false
                case .apple:
                    settings.googleCalendarEnabled = false
                    settings.calendarIntegrationEnabled = true
                case .google:
                    settings.calendarIntegrationEnabled = true
                    settings.googleCalendarEnabled = true
                }
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sourcePickerCard

                switch currentSourceChoice {
                case .none:
                    EmptyView()
                case .apple:
                    accessCard
                    if accessState == .authorized {
                        calendarsCard
                        cloudSharingCard
                    }
                case .google:
                    googleCalendarCard
                    if isGoogleConnected {
                        calendarsCard
                        cloudSharingCard
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            container.syncCalendarSources(settings: settings)
            refreshTick &+= 1
        }
        .task(id: refreshTaskID) {
            await refresh()
            guard settings.calendarIntegrationEnabled else { return }
            try? await Task.sleep(for: .seconds(30))
            refreshTick &+= 1
        }
        .onChange(of: settings.calendarIntegrationEnabled) {
            container.syncCalendarSources(settings: settings)
            refreshTick &+= 1
        }
        .onChange(of: settings.excludedCalendarIDs) {
            refreshTick &+= 1
        }
        .onChange(of: settings.googleCalendarEnabled) {
            container.syncCalendarSources(settings: settings)
            refreshTick &+= 1
        }
    }

    private var sourcePickerCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 2) {
                Text("Calendar source")
                    .font(.system(size: 15, weight: .semibold))
                Text("Pick where OpenOats reads meeting events from. Only one source can be active at a time.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Picker("", selection: calendarSourceBinding) {
                Text("None").tag(CalendarSourceChoice.none)
                Text("macOS Calendar").tag(CalendarSourceChoice.apple)
                Text("Google Calendar").tag(CalendarSourceChoice.google)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }

    private var refreshTaskID: String {
        "\(settings.calendarIntegrationEnabled)-\(settings.excludedCalendarIDs.joined(separator: ","))-\(refreshTick)"
    }

    private var selectedCalendarCount: Int {
        let excluded = Set(settings.excludedCalendarIDs)
        return availableCalendars.filter { !excluded.contains($0.id) }.count
    }

    private var calendarSelectionSummary: String {
        guard !availableCalendars.isEmpty else {
            return "No calendars available"
        }
        if selectedCalendarCount == 0 {
            return "No calendars selected"
        }
        if selectedCalendarCount == availableCalendars.count {
            return availableCalendars.count == 1
                ? "1 calendar selected"
                : "All \(availableCalendars.count) calendars selected"
        }
        return "\(selectedCalendarCount) of \(availableCalendars.count) calendars selected"
    }

    private var calendarGroups: [CalendarSourceGroup] {
        var groups: [CalendarSourceGroup] = []
        var currentTitle: String?
        var currentCalendars: [AvailableCalendar] = []

        for calendar in availableCalendars {
            let title = calendar.sourceTitle ?? "Other"
            if currentTitle == title {
                currentCalendars.append(calendar)
            } else {
                if let currentTitle {
                    groups.append(CalendarSourceGroup(title: currentTitle, calendars: currentCalendars))
                }
                currentTitle = title
                currentCalendars = [calendar]
            }
        }

        if let currentTitle {
            groups.append(CalendarSourceGroup(title: currentTitle, calendars: currentCalendars))
        }

        return groups
    }

    private var accessCard: some View {
        settingsCard {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("macOS Calendar")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Match meetings and title sessions using your macOS Calendar events.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                refreshButton
            }

            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .font(.system(size: 12))
                    .foregroundStyle(statusColor)
                Text(statusLabel)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if accessState == .authorized, !availableCalendars.isEmpty {
                    Text("\(availableCalendars.count) visible")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            accessDetail
        }
    }

    private var isGoogleConnected: Bool {
        container.calendarManager?.connectedGoogleSource?.accessState == .authorized
    }

    private var googleAccountEmail: String? {
        container.calendarManager?.connectedGoogleSource?.accountEmail
    }

    private var googleCalendarCard: some View {
        settingsCard {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Google Calendar")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Sign in with a Google account to read events from your Google Calendar.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("OAuth Client (Desktop app)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Create a Desktop OAuth client in Google Cloud Console and paste the credentials here. See the README for the step-by-step setup.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Text("Client ID")
                        .font(.system(size: 11))
                        .frame(width: 88, alignment: .trailing)
                    TextField("123…apps.googleusercontent.com", text: $settings.googleOAuthClientID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .disabled(isGoogleConnected)
                }
                HStack(spacing: 8) {
                    Text("Client secret")
                        .font(.system(size: 11))
                        .frame(width: 88, alignment: .trailing)
                    SecureField("GOCSPX-…", text: $settings.googleOAuthClientSecret)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .disabled(isGoogleConnected)
                }
            }

            Divider()

            HStack(spacing: 12) {
                if isGoogleConnected {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Connected")
                                .font(.system(size: 12, weight: .medium))
                            if let email = googleAccountEmail {
                                Text(email)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Spacer()
                    Button("Disconnect", role: .destructive) {
                        container.disconnectGoogleCalendar()
                        googleSignInError = nil
                        refreshTick &+= 1
                    }
                    .font(.system(size: 12))
                } else {
                    if googleSignInInProgress {
                        ProgressView()
                            .controlSize(.small)
                        Text("Waiting for browser sign-in…")
                            .font(.system(size: 12))
                    } else {
                        Spacer()
                    }
                    Spacer()
                    Button("Connect Google Account") {
                        connectGoogleCalendar()
                    }
                    .font(.system(size: 12))
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        googleSignInInProgress
                            || settings.googleOAuthClientID.isEmpty
                            || settings.googleOAuthClientSecret.isEmpty
                    )
                }
            }

            if let googleSignInError {
                Text(googleSignInError)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            if isGoogleConnected {
                Text("OpenOats fetches events for the next 7 days from your selected Google calendars. Refreshes every 5 minutes while the app is running.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func connectGoogleCalendar() {
        googleSignInError = nil
        googleSignInInProgress = true
        Task { @MainActor in
            let success = await container.connectGoogleCalendar(settings: settings)
            googleSignInInProgress = false
            if !success {
                googleSignInError = "Sign-in failed. Check that the client ID and secret are correct and that you approved access in the browser."
            }
            refreshTick &+= 1
        }
    }

    private var cloudSharingCard: some View {
        settingsCard {
            Text("Cloud Notes")
                .font(.system(size: 15, weight: .semibold))

            Toggle("Share calendar details with cloud notes", isOn: $settings.shareCalendarContextWithCloudNotes)
                .font(.system(size: 12))

            Text("Remote note providers may receive event title, organizer, and invited participant names as text context. Local providers are excluded.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var calendarsCard: some View {
        settingsCard {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Included Calendars")
                        .font(.system(size: 15, weight: .semibold))
                    Text(calendarSelectionSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button("All") {
                        settings.excludedCalendarIDs = []
                    }
                    .font(.system(size: 12))
                    .disabled(availableCalendars.isEmpty || selectedCalendarCount == availableCalendars.count)
                    .help("Include all calendars")

                    Button("None") {
                        settings.excludedCalendarIDs = availableCalendars.map(\.id)
                    }
                    .font(.system(size: 12))
                    .disabled(availableCalendars.isEmpty || selectedCalendarCount == 0)
                    .help("Exclude all calendars")
                }
            }

            Text("Choose which calendars OpenOats can use when matching meetings.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if availableCalendars.isEmpty {
                Text("No calendars are currently available from macOS Calendar.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(calendarGroups) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(group.title)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)

                                ForEach(Array(group.calendars.enumerated()), id: \.element.id) { index, calendar in
                                    VStack(alignment: .leading, spacing: 8) {
                                        Toggle(isOn: inclusionBinding(for: calendar.id)) {
                                            HStack(spacing: 8) {
                                                Circle()
                                                    .fill(calendarColor(for: calendar))
                                                    .frame(width: 8, height: 8)
                                                Text(calendar.title)
                                                    .font(.system(size: 12, weight: .medium))
                                                    .lineLimit(1)
                                                    .truncationMode(.tail)
                                            }
                                        }
                                        .toggleStyle(.checkbox)

                                        if index < group.calendars.count - 1 {
                                            Divider()
                                                .padding(.leading, 28)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 220, maxHeight: 320)
                .background(cardInsetBackground)
            }
        }
    }

    private var refreshButton: some View {
        Group {
            if isManualRefreshInFlight {
                Label {
                    Text("Reloading…")
                } icon: {
                    ProgressView()
                        .controlSize(.small)
                }
                .font(.system(size: 12))
            } else {
                Button {
                    reloadErrorMessage = nil
                    showReloadSuccess = false
                    Task {
                        container.reloadCalendarIntegration()
                        await refresh(showManualProgress: true)
                    }
                } label: {
                    Label(showReloadSuccess ? "Updated" : "Reload", systemImage: showReloadSuccess ? "checkmark" : "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .help("Reload calendar access and the visible calendar list")
            }
        }
    }

    @ViewBuilder
    private var accessDetail: some View {
        switch accessState {
        case .authorized:
            if let reloadErrorMessage {
                Text(reloadErrorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        case .denied:
            VStack(alignment: .leading, spacing: 6) {
                Text("Calendar access is denied. Grant access in System Settings for OpenOats to see your events.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("Open Privacy Settings…") {
                    openCalendarPrivacySettings()
                }
                .font(.system(size: 12))
            }
        case .notDetermined:
            Text("OpenOats will request Calendar access when this setting is enabled.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var statusIcon: String {
        switch accessState {
        case .authorized: return "checkmark.circle.fill"
        case .denied: return "exclamationmark.triangle.fill"
        case .notDetermined: return "clock"
        }
    }

    private var statusColor: Color {
        switch accessState {
        case .authorized: return .green
        case .denied: return .orange
        case .notDetermined: return .secondary
        }
    }

    private var statusLabel: String {
        switch accessState {
        case .authorized: return "Calendar access authorized"
        case .denied: return "Calendar access denied"
        case .notDetermined: return "Calendar access not yet requested"
        }
    }

    private func inclusionBinding(for calendarID: String) -> Binding<Bool> {
        Binding(
            get: { !settings.excludedCalendarIDs.contains(calendarID) },
            set: { isIncluded in
                var excluded = Set(settings.excludedCalendarIDs)
                if isIncluded {
                    excluded.remove(calendarID)
                } else {
                    excluded.insert(calendarID)
                }
                settings.excludedCalendarIDs = availableCalendars.map(\.id).filter { excluded.contains($0) }
            }
        )
    }

    @MainActor
    private func refresh(showManualProgress: Bool = false) async {
        let refreshStart = ContinuousClock.now
        if showManualProgress {
            isManualRefreshInFlight = true
        }
        defer {
            if showManualProgress {
                Task { @MainActor in
                    let minimumVisibleDuration = Duration.milliseconds(400)
                    let elapsed = refreshStart.duration(to: ContinuousClock.now)
                    if elapsed < minimumVisibleDuration {
                        try? await Task.sleep(for: minimumVisibleDuration - elapsed)
                    }
                    isManualRefreshInFlight = false
                }
            }
        }

        guard settings.calendarIntegrationEnabled else {
            accessState = .notDetermined
            availableCalendars = []
            reloadErrorMessage = nil
            showReloadSuccess = false
            return
        }

        if container.calendarManager == nil {
            container.syncCalendarSources(settings: settings)
        }

        guard let manager = container.calendarManager else {
            accessState = .notDetermined
            availableCalendars = []
            reloadErrorMessage = "Could not reload Calendar access."
            return
        }

        manager.refreshFromSystem()
        accessState = manager.accessState

        guard manager.accessState == .authorized else {
            availableCalendars = []
            reloadErrorMessage = nil
            showReloadSuccess = true
            clearReloadSuccessSoon()
            return
        }

        let calendars = manager.availableCalendars()
        availableCalendars = calendars

        let availableIDs = Set(calendars.map(\.id))
        let prunedExcludedIDs = settings.excludedCalendarIDs.filter { availableIDs.contains($0) }
        if prunedExcludedIDs != settings.excludedCalendarIDs {
            settings.excludedCalendarIDs = prunedExcludedIDs
        }
        reloadErrorMessage = nil
        if showManualProgress {
            showReloadSuccess = true
            clearReloadSuccessSoon()
        }
    }

    private func clearReloadSuccessSoon() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !isManualRefreshInFlight else { return }
            showReloadSuccess = false
        }
    }

    private func calendarColor(for calendar: AvailableCalendar) -> Color {
        guard let hex = calendar.colorHex,
              let color = Color(calendarHex: hex) else { return .secondary }
        return color
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.2), lineWidth: 1)
            )
    }

    private var cardInsetBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .windowBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.15), lineWidth: 1)
            )
    }

    private func openCalendarPrivacySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
        ]
        for urlString in urls {
            guard let url = URL(string: urlString) else { continue }
            if NSWorkspace.shared.open(url) { return }
        }
    }
}

private extension Color {
    init?(calendarHex: String) {
        let cleaned = calendarHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count == 7, cleaned.hasPrefix("#") else { return nil }
        let redString = String(cleaned.dropFirst().prefix(2))
        let greenString = String(cleaned.dropFirst(3).prefix(2))
        let blueString = String(cleaned.dropFirst(5).prefix(2))
        guard let red = UInt8(redString, radix: 16),
              let green = UInt8(greenString, radix: 16),
              let blue = UInt8(blueString, radix: 16) else { return nil }
        self = Color(
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255
        )
    }
}
