import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

/// The app owns this Google connection. Calendar discovery does not depend on
/// macOS Internet Accounts or the Codex Google Calendar connector.
struct GoogleCalendarConnectionView: View {
    @Bindable var settings: SettingsViewModel
    var compact = false
    @State private var connection: GoogleCalendarConnection?
    @State private var calendars: [CalendarInfo] = []
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var calendarsExpanded = false
    @State private var credentialError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Google Calendar").font(.headline)
                    Text(connection?.email ?? "Connect to see your meetings and shared calendars.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if connection == nil {
                    Button(busy ? "Signing in…" : "Sign in with Google") { signIn() }
                        .parakeetAction(.primary)
                        .disabled(busy)
                        .accessibilityIdentifier("google-calendar-sign-in")
                } else {
                    Button("Refresh") { Task { await refresh() } }
                        .parakeetAction(.secondary).disabled(busy)
                    Button("Disconnect") {
                        Task {
                            do { try await GoogleCalendarAuth.shared.disconnect(); await refresh() } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    }
                    .parakeetAction(.secondary).disabled(busy)
                }
            }
            if busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Complete sign-in in your browser.").font(.caption)
                    Button("Cancel") { Task { await GoogleCalendarAuth.shared.cancelSignIn() } }
                        .parakeetAction(.secondary)
                }
            }
            if let credentialError {
                Text(credentialError).font(.caption).foregroundStyle(.secondary)
                Button("Unlock saved Google connection") {
                    Task {
                        do { _ = try await GoogleCalendarAuth.shared.unlockCredentialAccess(); await refresh() } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }.parakeetAction(.secondary)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.secondary)
            }
            if connection != nil {
                DisclosureGroup("Calendars shown in Live", isExpanded: $calendarsExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(calendars, id: \.id) { calendar in
                            Toggle(
                                calendar.title,
                                isOn: Binding(
                                    get: { !settings.calendarExcludedIdentifiers.contains(calendar.id) },
                                    set: { included in
                                        if included {
                                            settings.calendarExcludedIdentifiers.remove(calendar.id)
                                        } else {
                                            settings.calendarExcludedIdentifiers.insert(calendar.id)
                                        }
                                        let excluded = settings.calendarExcludedIdentifiers
                                        Task { await GoogleCalendarService.shared.setExcludedCalendarIDs(excluded) }
                                    })
                            )
                            .toggleStyle(.checkbox)
                        }
                        if calendars.isEmpty { Text("No calendars available.").font(.caption) }
                    }
                    .padding(.top, 6)
                }
                .font(.caption)
            }
            if !compact {
                Text("Your preparation is saved privately in Live. Calendar access is read-only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(compact ? 12 : 0)
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .googleCalendarConnectionDidChange)) { _ in
            Task { await refresh() }
        }
    }

    private func signIn() {
        busy = true
        errorMessage = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await GoogleCalendarAuth.shared.signIn(); await refresh() } catch is CancellationError {} catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor private func refresh() async {
        connection = await GoogleCalendarAuth.shared.connection()
        credentialError = await GoogleCalendarAuth.shared.credentialAccessError()
        await GoogleCalendarService.shared.setExcludedCalendarIDs(settings.calendarExcludedIdentifiers)
        await settings.refreshCalendarAccess()
        guard connection != nil else { calendars = []; return }
        do { calendars = try await GoogleCalendarService.shared.loadAvailableCalendars(); errorMessage = nil } catch {
            calendars = []; errorMessage = error.localizedDescription
        }
    }
}
