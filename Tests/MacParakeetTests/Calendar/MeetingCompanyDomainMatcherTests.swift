import Foundation
import XCTest
@testable import MacParakeetCore

final class MeetingCompanyDomainMatcherTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testDomainRulesNormalizeCaseWhitespacePrefixAndDuplicates() throws {
        XCTAssertEqual(
            try MeetingCompanyDomainMatcher.normalizedDomains([" @Example.COM ", "example.com", "other.example"]),
            ["example.com", "other.example"])
        XCTAssertEqual(try MeetingCompanyDomainMatcher.normalizedDomains([]), [])
    }

    func testMalformedDomainRulesAreRejectedRatherThanLooselyMatched() {
        for value in [
            "", " ", "someone@example.com", "https://example.com", "*.example.com", "@@example.com",
            "example", "example..com", "example.com.", ".example.com", "-example.com", "example-.com",
            "exa_mple.com", "exam ple.com", "127.0.0.1", "example.com?spoof", "éxample.com",
            String(repeating: "a", count: 64) + ".com",
        ] {
            XCTAssertThrowsError(try MeetingCompanyDomainMatcher.normalizedDomains([value]), value)
        }
        XCTAssertThrowsError(
            try MeetingCompanyDomainMatcher.normalizedDomains(Array(repeating: "example.com", count: 101)))
    }

    func testOnlyWholeWellFormedMailboxDomainsAreExtracted() {
        XCTAssertEqual(MeetingCompanyDomainMatcher.domain(fromEmail: " Person+tag@EXAMPLE.COM "), "example.com")
        for value in [
            "example.com", "@example.com", "a@@example.com", "a@", "a@ example.com", "a@exam ple.com",
            "Person <a@example.com>", "mailto:a@example.com", "a@example.com?cc=other", "a\n@example.com",
            ".a@example.com", "a.@example.com", "a..b@example.com", "a@127.0.0.1", "é@example.com",
        ] {
            XCTAssertNil(MeetingCompanyDomainMatcher.domain(fromEmail: value), value)
        }
    }

    func testExactDomainMatchesWithoutTitleOrNameGuessing() {
        let company = MeetingCompany(name: "Example", attendeeDomains: ["EXAMPLE.COM"])
        let match = resolve([.init(email: "a@example.com")], companies: [company])
        XCTAssertEqual(match.source, .attendeeDomain)
        XCTAssertEqual(match.company?.id, company.id)
        XCTAssertEqual(match.matchedDomains, ["example.com"])
        for email in ["a@notexample.com", "a@example.com.evil.test", "a@sub.example.com", "a@gmail.com"] {
            XCTAssertEqual(resolve([.init(email: email, name: "Example")], companies: [company]).source, .unmatched)
        }
        XCTAssertEqual(resolve([.init(name: "Example")], companies: [company]).source, .unmatched)
        let noRules = MeetingCompany(name: "Example")
        XCTAssertEqual(resolve([.init(email: "a@example.com")], companies: [noRules]).source, .unmatched)
    }

    func testExplicitSubdomainRuleCanMatch() {
        let company = MeetingCompany(name: "Region", attendeeDomains: ["division.example.com"])
        XCTAssertEqual(resolve([.init(email: "a@division.example.com")], companies: [company]).company?.id, company.id)
    }

    func testDeclinedAndNonpersonEntriesCannotChooseCompany() {
        let company = MeetingCompany(name: "Example", attendeeDomains: ["example.com"])
        let excluded: [EventParticipant] = [
            .init(email: "a@example.com", status: .declined),
            .init(email: "room@example.com", kind: .room),
            .init(email: "resource@example.com", kind: .resource),
            .init(email: "group@example.com", kind: .group),
            .init(email: "unknown@example.com", kind: .unknown),
        ]
        XCTAssertEqual(resolve(excluded, companies: [company]).source, .unmatched)
        for status in [EventParticipant.ParticipantStatus.accepted, .tentative, .pending, .unknown] {
            XCTAssertEqual(
                resolve([.init(email: "a@example.com", status: status, kind: .person)], companies: [company]).source,
                .attendeeDomain)
        }
    }

    func testPersonOrganizerCanSupplyDomainButDeclinedOrRoomCannot() {
        let company = MeetingCompany(name: "Example", attendeeDomains: ["example.com"])
        var value = event()
        value.organizer = .init(email: "a@example.com", kind: .person)
        XCTAssertEqual(
            MeetingCompanyDomainMatcher.resolve(event: value, companies: [company], preparation: nil).source,
            .attendeeDomain)
        value.organizer?.status = .declined
        XCTAssertEqual(
            MeetingCompanyDomainMatcher.resolve(event: value, companies: [company], preparation: nil).source,
            .unmatched)
        value.organizer = .init(email: "room@example.com", kind: .room)
        XCTAssertEqual(
            MeetingCompanyDomainMatcher.resolve(event: value, companies: [company], preparation: nil).source,
            .unmatched)
    }

    func testSeveralDomainsForOneCompanyRemainOneCertainChoice() {
        let company = MeetingCompany(name: "Example", attendeeDomains: ["example.com", "subsidiary.test"])
        let result = resolve(
            [.init(email: "a@example.com"), .init(email: "b@subsidiary.test"), .init(email: "c@example.com")],
            companies: [company])
        XCTAssertEqual(result.source, .attendeeDomain)
        XCTAssertEqual(result.candidateCompanies.map(\.id), [company.id])
        XCTAssertEqual(result.matchedDomains, ["example.com", "subsidiary.test"])
    }

    func testDifferentCompaniesOrDuplicateRulesRequireChoice() {
        let first = MeetingCompany(name: "Alpha", attendeeDomains: ["alpha.test"])
        let second = MeetingCompany(name: "Beta", attendeeDomains: ["beta.test"])
        let value = event([.init(email: "a@alpha.test"), .init(email: "b@beta.test")])
        for companies in [[first, second], [second, first]] {
            let result = MeetingCompanyDomainMatcher.resolve(event: value, companies: companies, preparation: nil)
            XCTAssertEqual(result.source, .ambiguous)
            XCTAssertNil(result.company)
            XCTAssertNil(result.effectivePreparation(for: value))
            XCTAssertEqual(result.candidateCompanies.map(\.id), [first.id, second.id])
        }
        var duplicate = second
        duplicate.attendeeDomains = ["alpha.test"]
        XCTAssertEqual(resolve([.init(email: "a@alpha.test")], companies: [first, duplicate]).source, .ambiguous)
    }

    func testArchivedCompanyDoesNotMatchAndDoesNotCauseAmbiguity() {
        let active = MeetingCompany(name: "Active", attendeeDomains: ["example.com"])
        let archived = MeetingCompany(name: "Archived", attendeeDomains: ["example.com"], isArchived: true)
        XCTAssertEqual(resolve([.init(email: "a@example.com")], companies: [archived]).source, .unmatched)
        XCTAssertEqual(resolve([.init(email: "a@example.com")], companies: [archived, active]).company?.id, active.id)
    }

    func testSavedCompanyAlwaysWinsConflictingDomainRules() throws {
        let automatic = MeetingCompany(name: "Automatic", attendeeDomains: ["example.com"])
        let manual = MeetingCompany(name: "Manual")
        let value = event([.init(email: "a@example.com")])
        let saved = preparation(for: value, companyID: manual.id)
        let result = MeetingCompanyDomainMatcher.resolve(
            event: value, companies: [automatic, manual], preparation: saved)
        XCTAssertEqual(result.source, .manual)
        XCTAssertEqual(result.company?.id, manual.id)
        XCTAssertTrue(result.matchedDomains.isEmpty)
        let effective = try XCTUnwrap(result.effectivePreparation(for: value))
        XCTAssertEqual(effective.id, saved.id)
        XCTAssertEqual(effective.context, saved.context)
        XCTAssertEqual(effective.companyID, manual.id)
        XCTAssertEqual(effective.titleSnapshot, value.title)
    }

    func testSavedNoCompanyIsAnExplicitOptOutAndRetainsAuthoredContext() throws {
        let automatic = MeetingCompany(name: "Automatic", attendeeDomains: ["example.com"])
        let value = event([.init(email: "a@example.com")])
        let saved = preparation(for: value, companyID: nil)
        let result = MeetingCompanyDomainMatcher.resolve(event: value, companies: [automatic], preparation: saved)
        XCTAssertEqual(result.source, .manual)
        XCTAssertNil(result.company)
        XCTAssertEqual(try XCTUnwrap(result.effectivePreparation(for: value)).context, saved.context)
        XCTAssertNil(result.effectivePreparation(for: value)?.companyID)
    }

    func testDeletedOrArchivedManualChoiceNeverFallsBackToDomain() throws {
        let automatic = MeetingCompany(name: "Automatic", attendeeDomains: ["example.com"])
        let archived = MeetingCompany(name: "Archived", isArchived: true)
        let value = event([.init(email: "a@example.com")])
        for companyID in [UUID(), archived.id] {
            let saved = preparation(for: value, companyID: companyID)
            let result = MeetingCompanyDomainMatcher.resolve(
                event: value, companies: [automatic, archived], preparation: saved)
            XCTAssertEqual(result.source, .manual)
            XCTAssertNil(result.company)
            let effective = try XCTUnwrap(result.effectivePreparation(for: value))
            XCTAssertEqual(effective.context, saved.context)
            XCTAssertNil(effective.companyID)
        }
    }

    func testInferredPreparationIsStableAndKeepsExactOccurrenceMetadata() throws {
        let company = MeetingCompany(name: "Example", attendeeDomains: ["example.com"])
        var value = event([.init(email: "a@example.com")])
        value.title = "  Exact — Meeting 🪴  "
        let first = try XCTUnwrap(
            MeetingCompanyDomainMatcher.resolve(event: value, companies: [company], preparation: nil)
                .effectivePreparation(for: value))
        let second = try XCTUnwrap(
            MeetingCompanyDomainMatcher.resolve(event: value, companies: [company], preparation: nil)
                .effectivePreparation(for: value))
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.context, "")
        XCTAssertEqual(first.titleSnapshot, value.title)
        XCTAssertEqual(first.scheduledStartAt, value.startTime)
        XCTAssertEqual(first.scheduledEndAt, value.endTime)
        XCTAssertEqual(first.key, .init(calendarID: "calendar", eventID: "instance"))
        value.startTime = start.addingTimeInterval(60)
        let moved = try XCTUnwrap(
            MeetingCompanyDomainMatcher.resolve(event: value, companies: [company], preparation: nil)
                .effectivePreparation(for: value))
        XCTAssertEqual(moved.id, first.id, "A reschedule changes metadata, not occurrence identity")
        let other = MeetingCompany(name: "Other", attendeeDomains: ["example.com"])
        XCTAssertNotEqual(
            MeetingCompanyDomainMatcher.resolve(event: value, companies: [other], preparation: nil)
                .effectivePreparation(for: value)?.id, first.id)
    }

    func testResolutionNeverCarriesPreparationIntoAnotherOccurrence() {
        let company = MeetingCompany(name: "Example", attendeeDomains: ["example.com"])
        let value = event([.init(email: "a@example.com")])
        let result = MeetingCompanyDomainMatcher.resolve(event: value, companies: [company], preparation: nil)
        var other = value
        other.providerEventID = "other"
        XCTAssertNil(result.effectivePreparation(for: other))
        let saved = preparation(for: other, companyID: company.id)
        let wrong = MeetingCompanyDomainMatcher.resolve(event: value, companies: [company], preparation: saved)
        XCTAssertEqual(wrong.source, .unmatched)
        XCTAssertNil(wrong.effectivePreparation(for: value))
    }

    func testNativeOrMissingGoogleIdentityCannotCreateAutomaticPreparation() {
        let company = MeetingCompany(name: "Example", attendeeDomains: ["example.com"])
        var value = event([.init(email: "a@example.com")])
        value.provider = .eventKit
        XCTAssertEqual(
            MeetingCompanyDomainMatcher.resolve(event: value, companies: [company], preparation: nil).source,
            .unmatched)
        value.provider = .google
        value.providerEventID = nil
        XCTAssertEqual(
            MeetingCompanyDomainMatcher.resolve(event: value, companies: [company], preparation: nil).source,
            .unmatched)
    }

    func testExternalBusinessOrganizerWinsOverOtherAttendeeCompanies() {
        let host = MeetingCompany(name: "Host", attendeeDomains: ["host.test"])
        let guest = MeetingCompany(name: "Guest", attendeeDomains: ["guest.test"])
        var value = event([.init(email: "a@guest.test")])
        value.organizer = .init(email: "b@host.test")
        let result = MeetingCompanyDomainMatcher.resolve(event: value, companies: [guest, host], preparation: nil)
        XCTAssertEqual(result.source, .attendeeDomain)
        XCTAssertEqual(result.company?.id, host.id)
        XCTAssertEqual(result.matchedDomains, ["host.test"])
    }

    func testInternalDomainsAndProperDescendantsNeverCreateClientSignals() {
        let client = MeetingCompany(name: "Client", attendeeDomains: ["client.test"])
        let internalCompany = MeetingCompany(name: "Our team", attendeeDomains: ["team.test", "dev.team.test"])
        var value = event([
            .init(email: "a@TEAM.TEST"), .init(email: "b@dev.team.test"), .init(email: "c@client.test"),
            .init(email: "spoof@notteam.test"),
        ])
        value.organizer = .init(email: "host@dev.team.test")
        XCTAssertEqual(
            MeetingCompanyDomainMatcher.discoverableDomains(event: value, internalDomains: ["team.test"]),
            ["client.test", "notteam.test"])
        value.participants.removeLast()
        let result = MeetingCompanyDomainMatcher.resolve(
            event: value, companies: [internalCompany, client], preparation: nil, internalDomains: ["TEAM.TEST"])
        XCTAssertEqual(result.company?.id, client.id)
    }

    func testPublicMailServiceCalendarAndResourcesAreNotDiscovered() {
        let value = event([
            .init(email: "a@gmail.com"), .init(email: "a@outlook.com"), .init(email: "a@proton.me"),
            .init(email: "a@group.calendar.google.com"), .init(email: "a@service.gserviceaccount.com"),
            .init(email: "room@roomcompany.test", kind: .room),
            .init(email: "declined@declined.test", status: .declined), .init(email: "a@business.test"),
        ])
        XCTAssertEqual(MeetingCompanyDomainMatcher.discoverableDomains(event: value), ["business.test"])
        let publicRule = MeetingCompany(name: "Personal", attendeeDomains: ["gmail.com"])
        XCTAssertEqual(resolve([.init(email: "a@gmail.com")], companies: [publicRule]).source, .unmatched)
    }

    func testUnknownBusinessSignalPreventsKnownTitleFallbackAndFalseCertainty() {
        let known = MeetingCompany(name: "Example", attendeeDomains: ["example.com"])
        var value = event([.init(email: "a@unknown.test")])
        value.title = "Example weekly meeting"
        let result = MeetingCompanyDomainMatcher.resolve(event: value, companies: [known], preparation: nil)
        XCTAssertEqual(result.source, .unmatched)
        XCTAssertNil(result.company)
        value.participants.append(.init(email: "b@example.com"))
        let mixed = MeetingCompanyDomainMatcher.resolve(event: value, companies: [known], preparation: nil)
        XCTAssertEqual(mixed.source, .ambiguous)
        XCTAssertNil(mixed.company)
    }

    func testKnownTitleFallbackUsesWholeWordsAndUnicodeCaseFolding() {
        let company = MeetingCompany(name: "Straße", attendeeDomains: ["strasse.test"])
        var value = event([.init(email: "a@gmail.com")])
        value.title = "STRASSE: weekly review"
        XCTAssertEqual(
            MeetingCompanyDomainMatcher.resolve(event: value, companies: [company], preparation: nil).source, .title)
        let brand = MeetingCompany(name: "example.com", attendeeDomains: ["example.com"])
        value.title = "Example — review"
        let match = MeetingCompanyDomainMatcher.resolve(event: value, companies: [brand], preparation: nil)
        XCTAssertEqual(match.source, .title)
        XCTAssertEqual(match.company?.id, brand.id)
        value.title = "Notexample discussion"
        XCTAssertEqual(
            MeetingCompanyDomainMatcher.resolve(event: value, companies: [brand], preparation: nil).source, .unmatched)
    }

    func testShortGenericAndAmbiguousTitleNamesDoNotChooseCompany() {
        var value = event()
        value.title = "Weekly Company Project AB review"
        let short = MeetingCompany(name: "AB", attendeeDomains: ["ab.test"])
        let generic = MeetingCompany(name: "Company Project")
        XCTAssertEqual(
            MeetingCompanyDomainMatcher.resolve(event: value, companies: [short, generic], preparation: nil).source,
            .unmatched)
        value.title = "Alpha and Beta planning"
        let result = MeetingCompanyDomainMatcher.resolve(
            event: value, companies: [MeetingCompany(name: "Alpha"), MeetingCompany(name: "Beta")], preparation: nil)
        XCTAssertEqual(result.source, .ambiguous)
        XCTAssertNil(result.company)
    }

    func testAutomaticCompanyPreparationNeverInventsProject() throws {
        let company = MeetingCompany(name: "Example", attendeeDomains: ["example.com"])
        let value = event([.init(email: "a@example.com")])
        let result = MeetingCompanyDomainMatcher.resolve(event: value, companies: [company], preparation: nil)
        let preparation = try XCTUnwrap(result.effectivePreparation(for: value))
        XCTAssertEqual(preparation.companyID, company.id)
        XCTAssertNil(preparation.projectID)
    }

    func testMultipartPublicSuffixIsNeverMistakenForCompanyBrand() {
        let company = MeetingCompany(name: "foo.com.au", attendeeDomains: ["foo.com.au"])
        var value = event()
        value.title = "COM review"
        XCTAssertEqual(
            MeetingCompanyDomainMatcher.resolve(event: value, companies: [company], preparation: nil).source,
            .unmatched)
        value.title = "foo.com.au review"
        XCTAssertEqual(
            MeetingCompanyDomainMatcher.resolve(event: value, companies: [company], preparation: nil).source, .title)
    }

    func testLegacyContextOnlyDraftCanInferCompanyWithoutLosingAuthoredTextOrIdentity() throws {
        let company = MeetingCompany(name: "Example", attendeeDomains: ["example.com"])
        let value = event([.init(email: "a@example.com")])
        for flag in [Optional<Bool>.none, false] {
            let legacy = MeetingPreparation(
                key: .init(calendarID: "calendar", eventID: "instance"), context: "Keep this authored agenda.",
                companySelectionIsExplicit: flag, titleSnapshot: "Earlier title", createdAt: start, updatedAt: start)
            let result = MeetingCompanyDomainMatcher.resolve(event: value, companies: [company], preparation: legacy)
            XCTAssertEqual(result.source, .attendeeDomain)
            XCTAssertEqual(result.company?.id, company.id)
            XCTAssertEqual(result.persistedPreparationID, legacy.id)
            let effective = try XCTUnwrap(result.effectivePreparation(for: value))
            XCTAssertEqual(effective.id, legacy.id)
            XCTAssertEqual(effective.context, legacy.context)
            XCTAssertEqual(effective.companyID, company.id)
            XCTAssertNil(effective.projectID)
            XCTAssertEqual(effective.companySelectionIsExplicit, flag)
        }
    }

    func testNewExplicitNoCompanyIsDifferentFromLegacyAbsence() throws {
        let company = MeetingCompany(name: "Example", attendeeDomains: ["example.com"])
        let value = event([.init(email: "a@example.com")])
        let explicit = preparation(for: value, companyID: nil)
        XCTAssertEqual(explicit.companySelectionIsExplicit, true)
        let result = MeetingCompanyDomainMatcher.resolve(event: value, companies: [company], preparation: explicit)
        XCTAssertEqual(result.source, .manual)
        XCTAssertNil(result.company)
        XCTAssertEqual(result.persistedPreparationID, explicit.id)
        XCTAssertEqual(try XCTUnwrap(result.effectivePreparation(for: value)).context, explicit.context)
    }

    func testLegacyProjectChoiceStillPreventsAutomaticCompanyReclassification() throws {
        let company = MeetingCompany(name: "Example", attendeeDomains: ["example.com"])
        let value = event([.init(email: "a@example.com")])
        let projectID = UUID()
        let legacy = MeetingPreparation(
            key: .init(calendarID: "calendar", eventID: "instance"), context: "Authored project agenda.",
            companySelectionIsExplicit: nil, projectID: projectID, titleSnapshot: "Earlier")
        let result = MeetingCompanyDomainMatcher.resolve(event: value, companies: [company], preparation: legacy)
        XCTAssertEqual(result.source, .manual)
        XCTAssertNil(result.company)
        let effective = try XCTUnwrap(result.effectivePreparation(for: value))
        XCTAssertEqual(effective.projectID, projectID)
        XCTAssertEqual(effective.context, legacy.context)
    }

    func testLegacyAuthoredContextSurvivesUnmatchedAndAmbiguousCompanySignals() throws {
        let first = MeetingCompany(name: "First", attendeeDomains: ["first.test"])
        let second = MeetingCompany(name: "Second", attendeeDomains: ["second.test"])
        let value = event()
        let legacy = MeetingPreparation(
            key: .init(calendarID: "calendar", eventID: "instance"), context: "Authored context remains.",
            companySelectionIsExplicit: nil, titleSnapshot: "Earlier")
        let unmatched = MeetingCompanyDomainMatcher.resolve(
            event: value, companies: [first, second], preparation: legacy)
        XCTAssertEqual(unmatched.source, .unmatched)
        XCTAssertEqual(try XCTUnwrap(unmatched.effectivePreparation(for: value)).context, legacy.context)
        var mixed = value
        mixed.participants = [.init(email: "a@first.test"), .init(email: "b@second.test")]
        let ambiguous = MeetingCompanyDomainMatcher.resolve(
            event: mixed, companies: [first, second], preparation: legacy)
        XCTAssertEqual(ambiguous.source, .ambiguous)
        let effective = try XCTUnwrap(ambiguous.effectivePreparation(for: mixed))
        XCTAssertEqual(effective.id, legacy.id)
        XCTAssertEqual(effective.context, legacy.context)
        XCTAssertNil(effective.companyID)
    }

    private func resolve(_ participants: [EventParticipant], companies: [MeetingCompany]) -> MeetingCompanyResolution {
        MeetingCompanyDomainMatcher.resolve(event: event(participants), companies: companies, preparation: nil)
    }

    private func event(_ participants: [EventParticipant] = []) -> CalendarEvent {
        CalendarEvent(
            id: "google:calendar:instance", title: "Unrelated meeting", startTime: start,
            endTime: start.addingTimeInterval(3_600), participants: participants,
            calendarIdentifier: "calendar", provider: .google, providerEventID: "instance")
    }

    private func preparation(for event: CalendarEvent, companyID: UUID?) -> MeetingPreparation {
        MeetingPreparation(
            key: .init(calendarID: "calendar", eventID: event.providerEventID!), context: "Authored context.",
            companyID: companyID, titleSnapshot: "Earlier title", createdAt: start, updatedAt: start)
    }
}
