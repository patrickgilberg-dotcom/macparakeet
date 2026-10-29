import Foundation
import XCTest
@testable import MacParakeetCore

final class CalendarRecordingIdentityTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func googleEvent(id: String = "instance-original-0900", calendar: String = "shared-calendar")
        -> CalendarEvent
    {
        CalendarEvent(
            id: "google-list-id-\(calendar)-\(id)", title: "Calendar name", startTime: start,
            endTime: start.addingTimeInterval(3_600), calendarIdentifier: calendar, isRecurring: true,
            provider: .google, providerEventID: id, providerRecurringEventID: "series",
            originalOccurrenceStart: start, isUserMeeting: false)
    }

    func testPreparationUsesRawGoogleOccurrenceAndCalendarIDs() {
        let event = googleEvent()
        XCTAssertEqual(event.preparationCalendarID, "shared-calendar")
        XCTAssertEqual(event.preparationEventID, "instance-original-0900")
        XCTAssertNotEqual(event.preparationEventID, event.id)
        XCTAssertNotEqual(event.preparationEventID, event.providerRecurringEventID)
    }

    func testTitleAndRescheduleDoNotChangePreparationOccurrenceIdentity() {
        var event = googleEvent()
        event.title = "Changed calendar title 🦜"
        event.startTime = start.addingTimeInterval(7_200)
        event.endTime = start.addingTimeInterval(10_800)
        XCTAssertEqual(event.preparationCalendarID, "shared-calendar")
        XCTAssertEqual(event.preparationEventID, "instance-original-0900")
        XCTAssertEqual(event.originalOccurrenceStart, start)
    }

    func testRecurringInstancesAndDifferentCalendarsRemainDistinct() {
        XCTAssertNotEqual(
            googleEvent(id: "instance-A").preparationEventID, googleEvent(id: "instance-B").preparationEventID)
        XCTAssertNotEqual(
            googleEvent(calendar: "calendar-A").preparationCalendarID,
            googleEvent(calendar: "calendar-B").preparationCalendarID)
    }

    func testEventKitAndIncompleteGoogleEventsNeverInventPreparationKeys() {
        let legacy = CalendarEvent(
            id: "native-event", title: "Same title", startTime: start, endTime: start.addingTimeInterval(60))
        XCTAssertNil(legacy.preparationCalendarID)
        XCTAssertNil(legacy.preparationEventID)
        var incomplete = googleEvent()
        incomplete.providerEventID = nil
        XCTAssertNil(incomplete.preparationEventID)
        incomplete.calendarIdentifier = ""
        XCTAssertNil(incomplete.preparationCalendarID)
    }

    func testGoogleProviderMetadataAndSharedParticipationRoundTrip() throws {
        let event = googleEvent()
        let decoded = try JSONDecoder().decode(CalendarEvent.self, from: JSONEncoder().encode(event))
        XCTAssertEqual(decoded.provider, .google)
        XCTAssertEqual(decoded.providerEventID, event.providerEventID)
        XCTAssertEqual(decoded.providerRecurringEventID, "series")
        XCTAssertEqual(decoded.originalOccurrenceStart, start)
        XCTAssertEqual(decoded.isUserMeeting, false, "Seeing a shared event must not imply participation")
        let snapshot = MeetingCalendarSnapshot(event: decoded, confidence: .confirmed)
        let archived = try JSONDecoder().decode(MeetingCalendarSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(archived.calendarIdentifier, "shared-calendar")
        XCTAssertEqual(archived.providerEventID, "instance-original-0900")
        XCTAssertEqual(archived.provider, .google)
    }

    func testLegacyCalendarPayloadKeepsEventKitAndUnknownParticipation() throws {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(googleEvent())) as! [String: Any]
        for key in [
            "provider", "providerEventID", "providerRecurringEventID", "originalOccurrenceStart", "isUserMeeting",
        ] {
            object.removeValue(forKey: key)
        }
        let decoded = try JSONDecoder().decode(CalendarEvent.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.provider, .eventKit)
        XCTAssertNil(decoded.isUserMeeting)
        XCTAssertNil(decoded.preparationEventID)
        XCTAssertNil(MeetingCalendarSnapshot(event: decoded, confidence: .probable).providerEventID)
    }

    func testCalendarTitlesRemainExactThroughLocksOutputsAndTranscription() throws {
        for title in ["Meeting", "Meeting January Planning", "  Ajay’s R&D / Q4 🦜: \"Go?\"  "] {
            let snapshot = MeetingCalendarSnapshot(
                confidence: .confirmed, eventIdentifier: "synthetic-event", title: title,
                scheduledStartAt: start, scheduledEndAt: start.addingTimeInterval(60))
            let lock = MeetingRecordingLockFile(
                sessionId: UUID(), startedAt: start, displayName: title,
                calendarEventSnapshot: snapshot, titleOverride: title
            )
            .withState(.awaitingTranscription)
            .withNotes("Synthetic note")
            let recovered = try JSONDecoder().decode(MeetingRecordingLockFile.self, from: JSONEncoder().encode(lock))
            XCTAssertEqual(recovered.displayName, title)
            XCTAssertEqual(recovered.titleOverride, title)
            let folder = URL(fileURLWithPath: "/synthetic/uuid-folder")
            let output = MeetingRecordingOutput(
                sessionID: recovered.sessionId, displayName: recovered.displayName, folderURL: folder,
                mixedAudioURL: folder.appendingPathComponent("meeting-playback.m4a"),
                microphoneAudioURL: folder.appendingPathComponent("microphone-raw.m4a"),
                systemAudioURL: folder.appendingPathComponent("system-raw.m4a"), durationSeconds: 60,
                sourceAlignment: .init(meetingOriginHostTime: nil, microphone: nil, system: nil),
                calendarEventSnapshot: recovered.calendarEventSnapshot, titleOverride: recovered.titleOverride)
            XCTAssertEqual(output.titleOverride, title)
            let transcription = Transcription(
                fileName: output.titleOverride ?? output.displayName, sourceType: .meeting,
                calendarEventSnapshot: snapshot, titleOverride: output.titleOverride)
            let archived = try JSONDecoder().decode(Transcription.self, from: JSONEncoder().encode(transcription))
            XCTAssertEqual(archived.fileName, title)
            XCTAssertEqual(archived.effectiveDisplayTitle, title)
            XCTAssertEqual(
                archived.normalizedTitleOverride, title, "A protected title bypasses automatic title generation")
            XCTAssertEqual(output.folderURL, folder, "Visible calendar names never determine recording folder paths")
        }
    }

    func testOrdinaryUserRenameWinsOverCalendarAndRetainsWhitespaceNormalization() {
        let snapshot = MeetingCalendarSnapshot(
            confidence: .confirmed, eventIdentifier: "event", title: "Calendar event",
            scheduledStartAt: start, scheduledEndAt: start.addingTimeInterval(60))
        var transcription = Transcription(
            fileName: "  My own title  ", sourceType: .meeting,
            calendarEventSnapshot: snapshot, titleOverride: "  My own title  ")
        XCTAssertEqual(transcription.titleOverride, "My own title")
        XCTAssertEqual(transcription.effectiveDisplayTitle, "My own title")
        transcription.fileName = "Later manual rename"
        XCTAssertEqual(
            transcription.effectiveDisplayTitle, "Later manual rename", "Stale title intent cannot undo a rename")
    }
}
