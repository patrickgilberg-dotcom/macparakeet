import Carbon
import XCTest
@testable import MacParakeet

@MainActor
final class LiveAnswerHotkeyTests: XCTestCase {
    func testPrimaryRegistersExactOptionCommandSpace() {
        let registration = RegistrationSpy()
        let hotkey = LiveAnswerHotkey(registration: registration)
        defer { hotkey.stop() }

        XCTAssertTrue(hotkey.start())
        XCTAssertEqual(hotkey.registeredChord, .optionCommandSpace)
        XCTAssertEqual(registration.chords, [.optionCommandSpace])
        XCTAssertEqual(registration.chords.first?.modifiers, UInt32(optionKey | cmdKey))
        XCTAssertEqual(hotkey.registeredChord?.label, "⌥⌘Space")
        XCTAssertEqual(registration.installCount, 1)
        XCTAssertEqual(hotkey.registrationStatus, noErr)
    }

    func testConflictUsesDisplayedControlOptionCommandFallback() {
        let registration = RegistrationSpy(statuses: [OSStatus(eventHotKeyExistsErr), noErr])
        let hotkey = LiveAnswerHotkey(registration: registration)
        defer { hotkey.stop() }

        XCTAssertTrue(hotkey.start())
        XCTAssertEqual(registration.chords, [.optionCommandSpace, .controlOptionCommandSpace])
        XCTAssertEqual(hotkey.registeredChord, .controlOptionCommandSpace)
        XCTAssertEqual(hotkey.registeredChord?.modifiers, UInt32(controlKey | optionKey | cmdKey))
        XCTAssertEqual(hotkey.registeredChord?.label, "⌃⌥⌘Space")
    }

    func testUnexpectedRegistrationFailureDoesNotGuessAnotherChord() {
        let registration = RegistrationSpy(statuses: [OSStatus(paramErr)])
        let hotkey = LiveAnswerHotkey(registration: registration)

        XCTAssertFalse(hotkey.start())
        XCTAssertNil(hotkey.registeredChord)
        XCTAssertEqual(hotkey.registrationStatus, OSStatus(paramErr))
        XCTAssertEqual(registration.chords, [.optionCommandSpace])
        XCTAssertEqual(registration.unregisterCount, 1)
        XCTAssertEqual(registration.removeCount, 1)
        hotkey.stop()
        XCTAssertEqual(registration.unregisterCount, 1)
    }

    func testBothChordsOccupiedRemainsUnavailableAndDisposesHandler() {
        let registration = RegistrationSpy(
            statuses: [OSStatus(eventHotKeyExistsErr), OSStatus(eventHotKeyExistsErr)])
        let hotkey = LiveAnswerHotkey(registration: registration)

        XCTAssertFalse(hotkey.start())
        XCTAssertNil(hotkey.registeredChord)
        XCTAssertEqual(registration.chords.count, 2)
        XCTAssertEqual(registration.unregisterCount, 1)
        XCTAssertEqual(registration.removeCount, 1)
    }

    func testHandlerFailureNeverRegistersAChord() {
        let registration = RegistrationSpy()
        registration.installStatus = OSStatus(eventInternalErr)
        let hotkey = LiveAnswerHotkey(registration: registration)

        XCTAssertFalse(hotkey.start())
        XCTAssertEqual(hotkey.registrationStatus, OSStatus(eventInternalErr))
        XCTAssertTrue(registration.chords.isEmpty)
        XCTAssertEqual(registration.removeCount, 1)
    }

    func testOnlyOwnedIDTriggersAndHeldKeyDoesNotRepeat() throws {
        let registration = RegistrationSpy()
        let hotkey = LiveAnswerHotkey(registration: registration)
        defer { hotkey.stop() }
        var received: [ContinuousClock.Instant] = []
        hotkey.onTrigger = { received.append($0) }
        XCTAssertTrue(hotkey.start())
        let id = try XCTUnwrap(registration.ids.last)
        let requestedAt = ContinuousClock.now

        LiveAnswerHotkey.deliver(signature: 0, id: id, isPressed: true, requestedAt: requestedAt)
        LiveAnswerHotkey.deliver(
            signature: LiveAnswerHotkey.signature, id: 0, isPressed: true, requestedAt: requestedAt)
        XCTAssertTrue(received.isEmpty)
        deliver(id, at: requestedAt)
        deliver(id, at: requestedAt)
        XCTAssertEqual(received, [requestedAt])
        deliver(id, isPressed: false, at: requestedAt)
        deliver(id, at: requestedAt)
        XCTAssertEqual(received.count, 2)
    }

    func testStopUnregistersOnceAndOldCallbackCannotReachRestartedOwner() throws {
        let registration = RegistrationSpy()
        let hotkey = LiveAnswerHotkey(registration: registration)
        var count = 0
        hotkey.onTrigger = { _ in count += 1 }
        XCTAssertTrue(hotkey.start())
        let oldID = try XCTUnwrap(registration.ids.last)
        hotkey.stop()
        hotkey.stop()
        XCTAssertNil(hotkey.registeredChord)
        XCTAssertEqual(registration.unregisterCount, 1)
        XCTAssertEqual(registration.removeCount, 1)

        XCTAssertTrue(hotkey.start())
        let currentID = try XCTUnwrap(registration.ids.last)
        XCTAssertNotEqual(oldID, currentID)
        deliver(oldID)
        XCTAssertEqual(count, 0)
        deliver(currentID)
        XCTAssertEqual(count, 1)
        hotkey.stop()
        XCTAssertEqual(registration.unregisterCount, 2)
        XCTAssertEqual(registration.removeCount, 2)
    }

    func testRepeatedStartDisposesPreviousRegistrationBeforeReplacingIt() throws {
        let registration = RegistrationSpy()
        let hotkey = LiveAnswerHotkey(registration: registration)
        defer { hotkey.stop() }
        XCTAssertTrue(hotkey.start())
        let oldID = try XCTUnwrap(registration.ids.last)
        XCTAssertTrue(hotkey.start())
        XCTAssertNotEqual(oldID, registration.ids.last)
        XCTAssertEqual(registration.unregisterCount, 1)
        XCTAssertEqual(registration.removeCount, 1)
        XCTAssertEqual(registration.installCount, 2)
    }

    func testDeallocatedOwnerCannotTriggerAndEventuallyDisposesResources() async throws {
        let registration = RegistrationSpy()
        var hotkey: LiveAnswerHotkey? = LiveAnswerHotkey(registration: registration)
        var count = 0
        hotkey?.onTrigger = { _ in count += 1 }
        XCTAssertTrue(try XCTUnwrap(hotkey).start())
        let id = try XCTUnwrap(registration.ids.last)
        weak var weakHotkey: LiveAnswerHotkey?
        weakHotkey = hotkey
        hotkey = nil

        XCTAssertNil(weakHotkey)
        deliver(id)
        XCTAssertEqual(count, 0)
        for _ in 0..<100 where registration.unregisterCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(registration.unregisterCount, 1)
        XCTAssertEqual(registration.removeCount, 1)
    }

    private func deliver(
        _ id: UInt32, isPressed: Bool = true, at requestedAt: ContinuousClock.Instant = .now
    ) {
        LiveAnswerHotkey.deliver(
            signature: LiveAnswerHotkey.signature, id: id, isPressed: isPressed, requestedAt: requestedAt)
    }
}

@MainActor
private final class RegistrationSpy: LiveAnswerHotkeyRegistration {
    var installStatus: OSStatus = noErr
    var statuses: [OSStatus]
    var chords: [LiveAnswerHotkey.Chord] = []
    var ids: [UInt32] = []
    var installCount = 0
    var unregisterCount = 0
    var removeCount = 0

    init(statuses: [OSStatus] = []) { self.statuses = statuses }

    func installHandler() -> OSStatus {
        installCount += 1
        return installStatus
    }

    func register(chord: LiveAnswerHotkey.Chord, id: UInt32) -> OSStatus {
        chords.append(chord)
        ids.append(id)
        return statuses.isEmpty ? noErr : statuses.removeFirst()
    }

    func unregister() { unregisterCount += 1 }
    func removeHandler() { removeCount += 1 }
}
