import Foundation
import XCTest
@testable import MacParakeetCore

final class GoogleCalendarOccurrenceSelectionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(
        calendar: String, id: String = "instance", uid: String? = "shared-uid",
        offset: TimeInterval = 0, original: Date? = nil, primary: Bool? = false,
        personal: Bool? = false, title: String = "Synthetic meeting"
    ) -> CalendarEvent {
        CalendarEvent(
            id: "google:\(calendar):\(id)", title: title, startTime: start.addingTimeInterval(offset),
            endTime: start.addingTimeInterval(offset + 3_600), calendarIdentifier: calendar,
            externalId: uid, provider: .google, providerEventID: id,
            originalOccurrenceStart: original, isUserMeeting: personal, isPrimaryCalendar: primary)
    }

    func testOwnAndSharedCopiesProduceOnePrimaryCardRegardlessOfInputOrder() throws {
        let own = event(calendar: "own", primary: true, personal: true)
        let shared = event(calendar: "ajay", personal: true)
        for input in [[shared, own], [own, shared]] {
            let result = GoogleCalendarOccurrenceSelection.distinct(input)
            XCTAssertEqual(result.map(\.id), [own.id])
            XCTAssertEqual(try XCTUnwrap(result.first).preparationCalendarID, "own")
        }
    }

    func testDistinctRecurringOccurrencesDoNotMerge() {
        let first = event(calendar: "own", id: "first", original: start, primary: true)
        let firstCopy = event(calendar: "ajay", id: "first-copy", original: start)
        let second = event(
            calendar: "own", id: "second", offset: 86_400,
            original: start.addingTimeInterval(86_400), primary: true)
        let result = GoogleCalendarOccurrenceSelection.distinct([second, firstCopy, first])
        XCTAssertEqual(result.map(\.id), [first.id, second.id])
    }

    func testMovedOccurrenceUsesOriginalStartToChooseItsPrimaryCopy() {
        let moved = event(calendar: "own", offset: 7_200, original: start, primary: true)
        let unchangedCopy = event(calendar: "ajay", original: start)
        XCTAssertEqual(
            GoogleCalendarOccurrenceSelection.distinct([unchangedCopy, moved]).map(\.id), [moved.id])
    }

    func testExcludedPrimaryIsNotReintroducedWhenCallerSuppliesOnlySharedCopy() {
        let shared = event(calendar: "ajay", personal: false)
        XCTAssertEqual(GoogleCalendarOccurrenceSelection.distinct([shared]).map(\.id), [shared.id])
    }

    func testMissingOrBlankUIDNeverMergesDifferentEventIDs() {
        let first = event(calendar: "own", id: "first", uid: nil, primary: true)
        let second = event(calendar: "ajay", id: "second", uid: nil)
        let blank = event(calendar: "other", id: "third", uid: "   ")
        let result = GoogleCalendarOccurrenceSelection.distinct([blank, second, first, first])
        XCTAssertEqual(Set(result.map(\.id)), Set([first.id, second.id, blank.id]))
        XCTAssertEqual(result.count, 3, "Only an exact event ID may collapse without a shared UID")
    }

    func testSameTitleAndTimeWithDifferentUIDsRemainSeparate() {
        let first = event(calendar: "own", uid: "unrelated-A", primary: true)
        let second = event(calendar: "ajay", uid: "unrelated-B")
        XCTAssertEqual(GoogleCalendarOccurrenceSelection.distinct([first, second]).count, 2)
    }

    func testPersonalCopyThenStableCalendarIDBreakTiesWithoutPrimary() {
        let nonPersonal = event(calendar: "A", personal: false)
        let personal = event(calendar: "Z", personal: true)
        XCTAssertEqual(
            GoogleCalendarOccurrenceSelection.distinct([nonPersonal, personal]).map(\.id), [personal.id])
        let earlierID = event(calendar: "B", personal: true)
        XCTAssertEqual(
            GoogleCalendarOccurrenceSelection.distinct([personal, earlierID]).map(\.id), [earlierID.id])
    }

    func testEventKitEntriesAreNotMergedAndOutputHasStableTimeOrder() {
        let later = event(calendar: "Z", uid: "later", offset: 60)
        let first = event(calendar: "A", uid: "first")
        var native = event(calendar: "native", uid: "first")
        native.provider = .eventKit
        let result = GoogleCalendarOccurrenceSelection.distinct([later, native, first])
        XCTAssertEqual(result.map(\.id), [native.id, first.id, later.id])
    }

    func testPrimaryMetadataRoundTripsAndLegacyPayloadDefaultsToNil() throws {
        let original = event(calendar: "own", primary: true)
        let encoded = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(CalendarEvent.self, from: encoded).isPrimaryCalendar, true)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "isPrimaryCalendar")
        let legacy = try JSONDecoder().decode(
            CalendarEvent.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.isPrimaryCalendar)
    }
}
