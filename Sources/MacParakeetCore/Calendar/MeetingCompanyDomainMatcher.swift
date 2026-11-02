import CryptoKit
import Foundation

/// A local company decision, separate from project selection and meeting facts.
public struct MeetingCompanyResolution: Sendable, Equatable {
    public enum Source: String, Sendable { case manual, attendeeDomain, title, ambiguous, unmatched }
    public let source: Source
    public let company: MeetingCompany?
    public let matchedDomains: [String]
    public let candidateCompanies: [MeetingCompany]
    public let explanation: String
    /// Existing authored provenance can coexist with an inferred company.
    public var persistedPreparationID: UUID? { manualPreparation?.id }
    private let manualPreparation: MeetingPreparation?
    private let key: MeetingPreparationKey?

    fileprivate init(
        source: Source, company: MeetingCompany? = nil, matchedDomains: [String] = [],
        candidateCompanies: [MeetingCompany] = [], explanation: String,
        manualPreparation: MeetingPreparation? = nil, key: MeetingPreparationKey? = nil
    ) {
        self.source = source; self.company = company; self.matchedDomains = matchedDomains
        self.candidateCompanies = candidateCompanies; self.explanation = explanation
        self.manualPreparation = manualPreparation; self.key = key
    }

    /// Inferred company context is transient, not a saved calendar inventory.
    /// It never invents a project or changes user-authored preparation.
    public func effectivePreparation(for event: CalendarEvent) -> MeetingPreparation? {
        guard let key, event.preparationCalendarID == key.calendarID,
            event.preparationEventID == key.eventID
        else { return nil }
        if var manual = manualPreparation {
            if source != .manual || manual.companyID != company?.id { manual.projectID = nil }
            manual.companyID = company?.id
            manual.titleSnapshot = event.title
            manual.scheduledStartAt = event.startTime
            manual.scheduledEndAt = event.endTime
            return manual
        }
        guard (source == .attendeeDomain || source == .title), let company else { return nil }
        return MeetingPreparation(
            id: Self.automaticID(key: key, companyID: company.id), key: key, companyID: company.id,
            companySelectionIsExplicit: false,
            titleSnapshot: event.title, scheduledStartAt: event.startTime, scheduledEndAt: event.endTime,
            createdAt: event.startTime, updatedAt: event.startTime)
    }

    private static func automaticID(key: MeetingPreparationKey, companyID: UUID) -> UUID {
        let fields = ["company-domain-v1", key.calendarID, key.eventID, companyID.uuidString]
        let identity = fields.map { "\($0.utf8.count):\($0)" }.joined()
        var bytes = Array(SHA256.hash(data: Data(identity.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }
}

/// Exact email-domain matching and conservative known-company title fallback.
/// No model, network request, calendar cache or transcript mutation is involved.
public enum MeetingCompanyDomainMatcher {
    public static let maximumDomainsPerCompany = 100

    public static func normalizedDomains(_ domains: [String]) throws -> [String] {
        guard domains.count <= maximumDomainsPerCompany else {
            throw MeetingCompanyRepositoryError.invalidAttendeeDomain
        }
        return try Array(
            Set(
                domains.map { value in
                    guard let domain = normalizedDomain(value) else {
                        throw MeetingCompanyRepositoryError.invalidAttendeeDomain
                    }
                    return domain
                })
        ).sorted()
    }

    public static func domain(fromEmail email: String) -> String? {
        let value = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 254 else { return nil }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let local = parts[0]
        guard !local.isEmpty, local.utf8.count <= 64,
            local.first != ".", local.last != ".", !local.contains("..")
        else { return nil }
        let punctuation = ".!#$%&'*+-/=?^_`{|}~"
        guard local.utf8.allSatisfy({ isASCIILetterOrDigit($0) || punctuation.utf8.contains($0) }) else { return nil }
        let rawDomain = String(parts[1])
        guard rawDomain.trimmingCharacters(in: .whitespacesAndNewlines) == rawDomain else { return nil }
        return normalizedDomain(rawDomain)
    }

    /// Expand own-team domains only through one explicit configured company
    /// that owns the exact signed-in mailbox domain. Similar names, parent
    /// domains and ambiguous rule ownership never establish extra aliases.
    /// Archived own-team configuration still identifies internal addresses;
    /// this read does not restore or otherwise edit that company.
    public static func internalDomains(accountEmail: String, companies: [MeetingCompany]) -> Set<String> {
        guard let signedInDomain = domain(fromEmail: accountEmail) else { return [] }
        let owners = companies.filter { company in
            company.attendeeDomains.contains { normalizedDomain($0) == signedInDomain }
        }
        guard owners.count == 1, let owner = owners.first,
            let aliases = try? normalizedDomains(owner.attendeeDomains)
        else { return [signedInDomain] }
        return Set(aliases)
    }

    /// Account, calendar selection and own-team aliases jointly define one
    /// discovery scope. Changing only alias settings invalidates a stale sweep
    /// before it can commit another company from the old interpretation.
    public static func discoverySourceIdentity(
        accountID: String, excludedCalendarIDs: Set<String>, internalDomains: Set<String>
    ) -> String {
        let fields =
            ["company-discovery-v2", "account", accountID, "excluded", String(excludedCalendarIDs.count)]
            + excludedCalendarIDs.sorted() + ["internal", String(internalDomains.count)] + internalDomains.sorted()
        let identity = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Only plausible external business domains are company-discovery inputs.
    /// Internal domains include proper dot descendants, never suffix lookalikes.
    public static func discoverableDomains(event: CalendarEvent, internalDomains: Set<String> = []) -> [String] {
        guard event.provider == .google else { return [] }
        let participants = event.participants + (event.organizer.map { [$0] } ?? [])
        return Array(
            Set(
                participants.compactMap {
                    externalDomain(of: $0, internalDomains: internalDomains)
                })
        ).sorted()
    }

    public static func resolve(
        event: CalendarEvent, companies: [MeetingCompany], preparation: MeetingPreparation?,
        internalDomains: Set<String> = []
    ) -> MeetingCompanyResolution {
        guard let calendarID = event.preparationCalendarID, let eventID = event.preparationEventID else {
            return .init(source: .unmatched, explanation: "Choose a connected Google Calendar occurrence.")
        }
        let key = MeetingPreparationKey(calendarID: calendarID, eventID: eventID)
        let active = companies.filter { !$0.isArchived }
        if let preparation {
            guard preparation.key == key else {
                return .init(source: .unmatched, explanation: "Preparation belongs to a different calendar event.")
            }
        }
        if let preparation,
            preparation.companyID != nil || preparation.companySelectionIsExplicit == true
                || preparation.projectID != nil
        {
            let company = preparation.companyID.flatMap { id in active.first { $0.id == id } }
            let explanation: String
            if let company {
                explanation = "Saved company: \(company.name)."
            } else if preparation.companyID != nil {
                explanation = "The saved company is unavailable. Choose a company."
            } else {
                explanation = "No company saved for this meeting. Automatic matching is overridden."
            }
            return .init(
                source: .manual, company: company, explanation: explanation,
                manualPreparation: preparation, key: key)
        }

        // A business organizer supplies the strongest company signal. Room,
        // resource, declined and own-team organizers never establish a client.
        if let organizer = event.organizer,
            let domain = externalDomain(of: organizer, internalDomains: internalDomains)
        {
            let organizerMatches = matchingCompanies(domains: [domain], companies: active)
            if !organizerMatches.isEmpty {
                return domainResolution(
                    companies: organizerMatches, domains: [domain], key: key, preparation: preparation)
            }
        }

        let domains = discoverableDomains(event: event, internalDomains: internalDomains)
        if !domains.isEmpty {
            let matches = matchingCompanies(domains: Set(domains), companies: active)
            let covered = Set(matches.flatMap { (try? normalizedDomains($0.attendeeDomains)) ?? [] })
            // Unknown external domains are not erased to make a known company
            // look certain. Discovery may add their distinct companies later.
            if matches.count == 1, Set(domains).isSubset(of: covered) {
                return domainResolution(companies: matches, domains: domains, key: key, preparation: preparation)
            }
            if matches.count > 1 || domains.count > 1 {
                return .init(
                    source: .ambiguous, matchedDomains: domains, candidateCompanies: matches,
                    explanation: "External attendees do not identify one company. Choose a company for this meeting.",
                    manualPreparation: preparation, key: key)
            }
            return .init(
                source: .unmatched, matchedDomains: domains,
                explanation: "This business domain has no available company yet.", manualPreparation: preparation,
                key: key)
        }

        // Titles can recognize an existing company only when business email
        // evidence is absent. They never create companies or choose projects.
        let titleMatches = active.filter { company in
            titleAliases(company).contains { containsWholePhrase($0, in: event.title) }
        }.sorted(by: companyOrder)
        if titleMatches.count == 1, let company = titleMatches.first {
            return .init(
                source: .title, company: company, candidateCompanies: titleMatches,
                explanation: "Matched the known company \(company.name) in this meeting title.",
                manualPreparation: preparation, key: key)
        }
        if !titleMatches.isEmpty {
            return .init(
                source: .ambiguous, candidateCompanies: titleMatches,
                explanation: "The title names more than one company. Choose a company for this meeting.",
                manualPreparation: preparation, key: key)
        }
        return .init(
            source: .unmatched, explanation: "No company match is available for this meeting.",
            manualPreparation: preparation, key: key)
    }

    private static func domainResolution(
        companies: [MeetingCompany], domains: [String], key: MeetingPreparationKey, preparation: MeetingPreparation?
    ) -> MeetingCompanyResolution {
        if companies.count == 1, let company = companies.first {
            return .init(
                source: .attendeeDomain, company: company, matchedDomains: domains, candidateCompanies: companies,
                explanation: "Matched \(company.name) from \(domains.joined(separator: ", ")).",
                manualPreparation: preparation, key: key)
        }
        return .init(
            source: .ambiguous, matchedDomains: domains, candidateCompanies: companies,
            explanation: "This business domain matches more than one company. Choose a company.",
            manualPreparation: preparation, key: key)
    }

    private static func matchingCompanies(domains: Set<String>, companies: [MeetingCompany]) -> [MeetingCompany] {
        var unique: [UUID: MeetingCompany] = [:]
        for company in companies {
            guard let configured = try? normalizedDomains(company.attendeeDomains),
                !domains.isDisjoint(with: configured)
            else { continue }
            unique[company.id] = company
        }
        return unique.values.sorted(by: companyOrder)
    }

    private static func companyOrder(_ lhs: MeetingCompany, _ rhs: MeetingCompany) -> Bool {
        if lhs.name.lowercased() != rhs.name.lowercased() { return lhs.name.lowercased() < rhs.name.lowercased() }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func externalDomain(of participant: EventParticipant, internalDomains: Set<String>) -> String? {
        guard participant.status != .declined, participant.kind == nil || participant.kind == .person,
            let email = participant.email, let domain = domain(fromEmail: email)
        else { return nil }
        let sender = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !schedulingTransportSenders.contains(sender) else { return nil }
        let internalRules = internalDomains.compactMap(normalizedDomain)
        guard !internalRules.contains(where: { domain == $0 || domain.hasSuffix("." + $0) }),
            !nonBusinessDomains.contains(where: { domain == $0 || domain.hasSuffix("." + $0) })
        else { return nil }
        return domain
    }

    // These mailboxes deliver another person's scheduling invitation. They
    // do not establish Calendly as that meeting's company. Keep this precise:
    // a real employee at the same domain remains a valid business signal.
    private static let schedulingTransportSenders: Set<String> = [
        "noreply@calendly.com", "no-reply@calendly.com", "notifications@calendly.com",
    ]

    private static let nonBusinessDomains: Set<String> = [
        "gmail.com", "googlemail.com", "yahoo.com", "yahoo.ca", "yahoo.co.uk", "ymail.com", "rocketmail.com",
        "hotmail.com", "hotmail.ca", "hotmail.co.uk", "outlook.com", "live.com", "live.ca", "msn.com", "aol.com",
        "icloud.com", "me.com", "mac.com", "proton.me", "protonmail.com", "pm.me", "tutanota.com", "tuta.com",
        "fastmail.com", "hey.com", "gmx.com", "gmx.de", "mail.com", "qq.com", "163.com", "126.com",
        "yandex.com", "yandex.ru", "zoho.com", "calendar.google.com", "gserviceaccount.com",
    ]

    private static func titleAliases(_ company: MeetingCompany) -> Set<String> {
        var values = Set([company.name.trimmingCharacters(in: .whitespacesAndNewlines)])
        for domain in company.attendeeDomains {
            guard let normalized = normalizedDomain(domain) else { continue }
            let labels = normalized.split(separator: ".")
            if labels.count == 2 { values.insert(String(labels[0])) }
        }
        let generic: Set<String> = [
            "company", "project", "meeting", "team", "internal", "weekly", "sync", "customer", "client",
            "test", "work", "other", "unknown", "sales", "operations", "management", "delivery", "business",
        ]
        return Set(
            values.filter {
                let folded = $0.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
                let words = folded.split { !$0.isLetter && !$0.isNumber }
                return $0.count >= 3 && !words.isEmpty && !words.allSatisfy { generic.contains(String($0)) }
            })
    }

    private static func containsWholePhrase(_ phrase: String, in text: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive]
        let locale = Locale(identifier: "en_US_POSIX")
        let title = text.folding(options: options, locale: locale)
        let alias = phrase.folding(options: options, locale: locale)
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: alias) + "(?![\\p{L}\\p{N}])"
        return title.range(of: pattern, options: .regularExpression) != nil
    }

    private static func normalizedDomain(_ input: String) -> String? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("@") { value.removeFirst() }
        guard !value.isEmpty, value.utf8.count <= 253 else { return nil }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return nil }
        for label in labels {
            guard !label.isEmpty, label.utf8.count <= 63, label.first != "-", label.last != "-",
                label.utf8.allSatisfy({ isASCIILetterOrDigit($0) || $0 == 45 })
            else { return nil }
        }
        guard let last = labels.last, last.utf8.contains(where: { (97...122).contains($0) }) else { return nil }
        return value
    }

    private static func isASCIILetterOrDigit(_ byte: UInt8) -> Bool {
        (97...122).contains(byte) || (65...90).contains(byte) || (48...57).contains(byte)
    }
}
