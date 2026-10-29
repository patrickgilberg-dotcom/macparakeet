import Foundation

/// Direct, read-only Google Calendar provider. Calendar polling has no native
/// Calendar/TCC dependency and never starts sign-in implicitly.
public actor GoogleCalendarService: CalendarServicing {
    public static let shared = GoogleCalendarService()

    private let auth: GoogleCalendarAuth
    private let session: URLSession
    private var excludedCalendarIDs: Set<String> = []
    private var selectionGeneration: UInt64 = 0
    private var errorMessage: String?

    public var lookAheadDays = 7
    public var excludeAllDay = true
    public var excludeDeclined = true

    public init() {
        self.init(auth: .shared, session: GoogleCalendarNetworkDelegate.session())
    }

    init(auth: GoogleCalendarAuth, session: URLSession) {
        self.auth = auth
        self.session = session
    }

    public nonisolated var permissionStatus: CalendarService.PermissionStatus {
        auth.isConnected ? .granted : .notDetermined
    }

    /// Only explicit user actions should call this protocol method.
    public func requestPermission() async -> Bool {
        do { _ = try await auth.signIn(); errorMessage = nil; return true } catch {
            errorMessage = Self.safeMessage(error); return false
        }
    }

    public func setExcludedCalendarIDs(_ identifiers: Set<String>) {
        if identifiers != excludedCalendarIDs {
            excludedCalendarIDs = identifiers
            selectionGeneration &+= 1
        }
    }

    public func lastErrorMessage() -> String? { errorMessage }

    /// The protocol is nonthrowing; Settings can use the throwing overload to
    /// distinguish an empty list from a connection or API setup failure.
    public func availableCalendars() async -> [CalendarInfo] {
        do { return try await loadAvailableCalendars() } catch { errorMessage = Self.safeMessage(error); return [] }
    }

    public func loadAvailableCalendars() async throws -> [CalendarInfo] {
        let authorization = try await auth.authorization()
        let calendars = try await calendarList(authorization: authorization)
        try await auth.validate(authorization)
        errorMessage = nil
        return calendars.map {
            CalendarInfo(
                id: $0.id, title: $0.summaryOverride ?? $0.summary ?? "Calendar", sourceTitle: "Google Calendar")
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    public func fetchUpcomingEvents(from: Date = Date(), days: Int? = nil) async throws -> [CalendarEvent] {
        let count = days ?? lookAheadDays
        guard (1...366).contains(count), from.timeIntervalSince1970.isFinite,
            let end = Calendar.current.date(byAdding: .day, value: count, to: from)
        else {
            throw GoogleCalendarError("invalid_date_range", "Choose a valid upcoming calendar date range.")
        }
        let authorization = try await auth.authorization()
        guard let connection = await auth.connection(), connection.id == authorization.accountID else {
            throw Self.changedError
        }
        let selection = selectionGeneration
        let excluded = excludedCalendarIDs
        let dropAllDay = excludeAllDay
        let dropDeclined = excludeDeclined
        let calendars = try await calendarList(authorization: authorization)
        try validateSelection(selection)
        var events: [CalendarEvent] = []
        var seenIDs: Set<String> = []
        for calendar in calendars where !excluded.contains(calendar.id) {
            var page: String?
            var seenPages: Set<String> = []
            repeat {
                try validateSelection(selection)
                let url = Self.eventsURL(calendarID: calendar.id, from: from, to: end, page: page)
                let response: EventsPage = try await read(url, authorization: authorization)
                try validateSelection(selection)
                for event in response.items ?? [] {
                    guard let value = event.calendarEvent(calendar: calendar, accountEmail: connection.email),
                        value.endTime > from, value.startTime < end,
                        !dropAllDay || !value.isAllDay,
                        !dropDeclined || value.userStatus != .declined,
                        seenIDs.insert(value.id).inserted
                    else { continue }
                    events.append(value)
                }
                page = try Self.nextPage(response.nextPageToken, seen: &seenPages)
            } while page != nil
        }
        try await auth.validate(authorization)
        try validateSelection(selection)
        errorMessage = nil
        return events.sorted { $0.startTime == $1.startTime ? $0.id < $1.id : $0.startTime < $1.startTime }
    }

    private func validateSelection(_ expected: UInt64) throws {
        try Task.checkCancellation()
        guard selectionGeneration == expected else { throw Self.changedError }
    }

    private func calendarList(authorization: GoogleCalendarAuth.Authorization) async throws -> [CalendarResource] {
        var page: String?
        var seenPages: Set<String> = []
        var result: [CalendarResource] = []
        var seenIDs: Set<String> = []
        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!
            components.queryItems = [
                URLQueryItem(name: "maxResults", value: "250"),
                URLQueryItem(name: "minAccessRole", value: "reader"),
                URLQueryItem(name: "showHidden", value: "true"),
                URLQueryItem(name: "showDeleted", value: "false"),
            ]
            if let page { components.queryItems?.append(URLQueryItem(name: "pageToken", value: page)) }
            let response: CalendarsPage = try await read(components.url!, authorization: authorization)
            for value in response.items ?? [] where value.deleted != true && !value.id.isEmpty {
                guard value.accessRole != "none", value.accessRole != "freeBusyReader",
                    seenIDs.insert(value.id).inserted
                else { continue }
                result.append(value)
            }
            page = try Self.nextPage(response.nextPageToken, seen: &seenPages)
        } while page != nil
        return result
    }

    private func read<T: Decodable>(_ url: URL, authorization: GoogleCalendarAuth.Authorization) async throws -> T {
        try await auth.validate(authorization)
        let token = try await auth.accessToken(expectedAccountID: authorization.accountID)
        try await auth.validate(authorization)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try await auth.validate(authorization)
        guard let response = response as? HTTPURLResponse else { throw Self.unavailableError }
        guard response.statusCode == 200 else {
            if response.statusCode == 401 {
                try await auth.rejectUnauthorized(authorization)
                throw GoogleCalendarError(
                    "access_removed", "Google Calendar access expired or was removed. Connect again.")
            }
            if response.statusCode == 403 {
                throw GoogleCalendarError(
                    "calendar_forbidden",
                    "Google Calendar could not be read. Check the app's Google Calendar API setup and account access.")
            }
            if response.statusCode == 429 {
                throw GoogleCalendarError(
                    "rate_limited", "Google Calendar is receiving too many requests. Try again shortly.")
            }
            throw Self.unavailableError
        }
        guard data.count <= 8_388_608, let value = try? JSONDecoder().decode(T.self, from: data) else {
            throw GoogleCalendarError(
                "invalid_calendar_response", "Google Calendar returned an unreadable response. Try again.")
        }
        return value
    }

    static func eventsURL(calendarID: String, from: Date, to: Date, page: String?) -> URL {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let identifier = calendarID.addingPercentEncoding(withAllowedCharacters: allowed)!
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(identifier)/events")!
        let formatter = ISO8601DateFormatter()
        components.queryItems = [
            URLQueryItem(name: "singleEvents", value: "true"), URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "showDeleted", value: "false"), URLQueryItem(name: "maxResults", value: "250"),
            URLQueryItem(name: "timeMin", value: formatter.string(from: from)),
            URLQueryItem(name: "timeMax", value: formatter.string(from: to)),
        ]
        if let page { components.queryItems?.append(URLQueryItem(name: "pageToken", value: page)) }
        return components.url!
    }

    private static func nextPage(_ value: String?, seen: inout Set<String>) throws -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard value.utf8.count <= 8192, seen.count < 100, seen.insert(value).inserted else {
            throw GoogleCalendarError(
                "pagination_failed", "Google Calendar could not finish loading all results. Try again.")
        }
        return value
    }

    private static func safeMessage(_ error: Error) -> String {
        (error as? GoogleCalendarError)?.localizedDescription ?? "Google Calendar could not be loaded. Try again."
    }

    private static let changedError = GoogleCalendarError(
        "calendar_selection_changed", "The selected Google calendars changed. Refresh to see the current selection.")
    private static let unavailableError = GoogleCalendarError(
        "calendar_unavailable", "Google Calendar is temporarily unavailable. Try again.")

    struct CalendarsPage: Decodable { let nextPageToken: String?; let items: [CalendarResource]? }
    struct CalendarResource: Decodable, Sendable {
        let id: String
        let summary: String?
        let summaryOverride: String?
        let timeZone: String?
        let primary: Bool?
        let deleted: Bool?
        let accessRole: String?
    }
    struct EventsPage: Decodable { let nextPageToken: String?; let items: [EventResource]? }

    struct EventResource: Decodable {
        let id: String
        let status: String?
        let summary: String?
        let description: String?
        let location: String?
        let start: EventDate?
        let end: EventDate?
        let hangoutLink: String?
        let conferenceData: ConferenceData?
        let attendees: [Person]?
        let organizer: Person?
        let iCalUID: String?
        let recurringEventId: String?
        let originalStartTime: EventDate?
        let recurrence: [String]?

        struct ConferenceData: Decodable {
            let entryPoints: [EntryPoint]?
            struct EntryPoint: Decodable { let entryPointType: String?; let uri: String? }
        }

        struct Person: Decodable {
            let email: String?
            let displayName: String?
            let responseStatus: String?
            let resource: Bool?
            let isSelf: Bool?

            enum CodingKeys: String, CodingKey {
                case email, displayName, responseStatus, resource
                case isSelf = "self"
            }

            var participant: EventParticipant {
                EventParticipant(
                    email: email, name: displayName, status: participationStatus,
                    kind: resource == true ? .resource : .person)
            }
            var participationStatus: EventParticipant.ParticipantStatus {
                switch responseStatus {
                case "accepted": return .accepted
                case "declined": return .declined
                case "tentative": return .tentative
                case "needsAction": return .pending
                default: return .unknown
                }
            }
        }

        func calendarEvent(calendar: CalendarResource, accountEmail: String) -> CalendarEvent? {
            guard status != "cancelled", !id.isEmpty,
                let startTime = start?.value(fallbackTimeZone: calendar.timeZone),
                let endTime = end?.value(fallbackTimeZone: calendar.timeZone), endTime > startTime
            else { return nil }
            // On shared calendars `self` denotes that calendar's owner/copy,
            // which can be Ajay rather than the connected Google user.
            func isCurrentUser(_ person: Person) -> Bool {
                person.email?.caseInsensitiveCompare(accountEmail) == .orderedSame
                    || (calendar.primary == true && person.isSelf == true)
            }
            let currentAttendee = attendees?.first(where: isCurrentUser)
            let ownOrganizer = organizer?.email?.caseInsensitiveCompare(accountEmail) == .orderedSame
            let isUserMeeting = calendar.primary == true || ownOrganizer || currentAttendee != nil
            let video = conferenceData?.entryPoints?.first(where: { $0.entryPointType == "video" })?.uri
            let meetURL = MeetingLinkParser.shared.extractMeetingUrl(
                location: location, notes: description, url: hangoutLink ?? video)
            // Length-delimited namespace avoids provider/calendar collisions.
            let namespaced = "google:\(calendar.id.utf8.count):\(calendar.id):\(id)"
            return CalendarEvent(
                id: namespaced, title: summary ?? "Untitled event", startTime: startTime, endTime: endTime,
                location: location, meetUrl: meetURL,
                participants: (attendees ?? []).filter { !isCurrentUser($0) }.map(\.participant),
                organizer: organizer?.participant, isAllDay: start?.date != nil,
                calendarName: calendar.summaryOverride ?? calendar.summary, calendarIdentifier: calendar.id,
                userStatus: currentAttendee?.participationStatus, externalId: iCalUID,
                isRecurring: recurringEventId != nil || !(recurrence ?? []).isEmpty,
                provider: .google, providerEventID: id, providerRecurringEventID: recurringEventId,
                originalOccurrenceStart: originalStartTime?.value(fallbackTimeZone: calendar.timeZone),
                isUserMeeting: isUserMeeting, isPrimaryCalendar: calendar.primary)
        }
    }

    struct EventDate: Decodable {
        let date: String?
        let dateTime: String?
        let timeZone: String?

        func value(fallbackTimeZone: String?) -> Date? {
            if let dateTime {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let value = iso.date(from: dateTime) { return value }
                iso.formatOptions = [.withInternetDateTime]
                if let value = iso.date(from: dateTime) { return value }
                // Google permits an offset-free dateTime with an IANA zone.
                guard let zone = timeZone ?? fallbackTimeZone, let timeZone = TimeZone(identifier: zone) else {
                    return nil
                }
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.timeZone = timeZone
                formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                return formatter.date(from: dateTime)
            }
            guard let date else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = (timeZone ?? fallbackTimeZone).flatMap(TimeZone.init(identifier:)) ?? .current
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: date)
        }
    }
}
