import Carbon
import Foundation

/// Registers only the Live answer chord with macOS, without monitoring keyboard
/// events. Carbon registration and disposal are confined to the main actor.
@MainActor
final class LiveAnswerHotkey {
    enum Chord: Equatable, Sendable {
        case optionCommandSpace
        case controlOptionCommandSpace

        var label: String {
            self == .optionCommandSpace ? "⌥⌘Space" : "⌃⌥⌘Space"
        }

        var modifiers: UInt32 {
            UInt32(cmdKey | optionKey | (self == .controlOptionCommandSpace ? controlKey : 0))
        }
    }

    var onTrigger: (@MainActor (ContinuousClock.Instant) -> Void)?
    private(set) var registeredChord: Chord?
    private(set) var registrationStatus: OSStatus = noErr

    private let registration: any LiveAnswerHotkeyRegistration
    private var registrationID: UInt32?
    private var isPressed = false

    // The C callback carries no object pointer. A stopped/deallocated owner is
    // never dereferenced, and IDs are not reused for a later meeting.
    nonisolated static let signature: OSType = 0x4D504C41  // MPLA
    private static var nextID: UInt32 = 0
    private static var registrations: [UInt32: Entry] = [:]

    private final class Entry {
        weak var owner: LiveAnswerHotkey?
        let registration: any LiveAnswerHotkeyRegistration

        init(owner: LiveAnswerHotkey, registration: any LiveAnswerHotkeyRegistration) {
            self.owner = owner
            self.registration = registration
        }
    }

    init(registration: (any LiveAnswerHotkeyRegistration)? = nil) {
        if let registration {
            self.registration = registration
        } else {
            self.registration = CarbonLiveAnswerHotkeyRegistration()
        }
    }

    deinit {
        if let registrationID {
            // Explicit stop is synchronous; this is a safety net for an owner
            // released without teardown. The registry retains the native handles.
            Task { @MainActor in
                Self.removeRegistration(id: registrationID)
            }
        }
    }

    @discardableResult
    func start() -> Bool {
        stop()
        guard Self.nextID < UInt32.max else {
            registrationStatus = OSStatus(eventHotKeyInvalidErr)
            return false
        }
        Self.nextID += 1
        let id = Self.nextID

        registrationStatus = registration.installHandler()
        guard registrationStatus == noErr else {
            registration.removeHandler()
            return false
        }

        var chord = Chord.optionCommandSpace
        registrationStatus = registration.register(chord: chord, id: id)
        if registrationStatus == OSStatus(eventHotKeyExistsErr) {
            chord = .controlOptionCommandSpace
            registrationStatus = registration.register(chord: chord, id: id)
        }
        guard registrationStatus == noErr else {
            registration.unregister()
            registration.removeHandler()
            return false
        }

        registrationID = id
        registeredChord = chord
        Self.registrations[id] = Entry(owner: self, registration: registration)
        return true
    }

    func stop() {
        guard let registrationID else { return }
        self.registrationID = nil
        registeredChord = nil
        isPressed = false
        Self.removeRegistration(id: registrationID)
    }

    private static func removeRegistration(id: UInt32) {
        // Remove routing before disposal, including already queued callbacks.
        guard let entry = registrations.removeValue(forKey: id) else { return }
        entry.registration.unregister()
        entry.registration.removeHandler()
    }

    static func deliver(
        signature: OSType, id: UInt32, isPressed: Bool, requestedAt: ContinuousClock.Instant
    ) {
        guard signature == Self.signature,
            let owner = registrations[id]?.owner,
            owner.registrationID == id
        else { return }
        guard isPressed else {
            owner.isPressed = false
            return
        }
        guard !owner.isPressed else { return }
        owner.isPressed = true
        owner.onTrigger?(requestedAt)
    }
}

/// Injectable native resource boundary; tests never register a system shortcut.
@MainActor
protocol LiveAnswerHotkeyRegistration: AnyObject {
    func installHandler() -> OSStatus
    func register(chord: LiveAnswerHotkey.Chord, id: UInt32) -> OSStatus
    func unregister()
    func removeHandler()
}

@MainActor
private final class CarbonLiveAnswerHotkeyRegistration: LiveAnswerHotkeyRegistration {
    private var handler: EventHandlerRef?
    private var hotkey: EventHotKeyRef?

    func installHandler() -> OSStatus {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var hotkeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID)
                guard status == noErr, hotkeyID.signature == LiveAnswerHotkey.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let signature = hotkeyID.signature
                let id = hotkeyID.id
                let isPressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                let requestedAt = ContinuousClock.now
                DispatchQueue.main.async {
                    LiveAnswerHotkey.deliver(
                        signature: signature, id: id, isPressed: isPressed, requestedAt: requestedAt)
                }
                return noErr
            }, eventTypes.count, &eventTypes, nil, &handler)
        return status == noErr && handler == nil ? OSStatus(eventInternalErr) : status
    }

    func register(chord: LiveAnswerHotkey.Chord, id: UInt32) -> OSStatus {
        // Nonexclusive registration can report success while an existing
        // exclusive owner suppresses delivery. Exclusive registration detects
        // collisions instead of silently claiming the shortcut works.
        let status = RegisterEventHotKey(
            UInt32(kVK_Space), chord.modifiers,
            EventHotKeyID(signature: LiveAnswerHotkey.signature, id: id),
            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotkey)
        return status == noErr && hotkey == nil ? OSStatus(eventHotKeyInvalidErr) : status
    }

    func unregister() {
        if let hotkey {
            UnregisterEventHotKey(hotkey)
            self.hotkey = nil
        }
    }

    func removeHandler() {
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
    }
}
