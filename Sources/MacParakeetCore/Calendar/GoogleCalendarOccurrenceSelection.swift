import Foundation

/// Selects a consistent Google calendar copy for presentation and recording.
/// Apply the caller's excluded-calendar and participation policy first so a
/// hidden copy cannot displace an eligible occurrence.
public enum GoogleCalendarOccurrenceSelection {
    private enum OccurrenceKey: Hashable {
        case calendarUID(String, Date)
        case exactEventID(String)
    }

    public static func distinct(_ events: [CalendarEvent]) -> [CalendarEvent] {
        var selected: [OccurrenceKey: CalendarEvent] = [:]
        var otherEvents: [CalendarEvent] = []
        for event in events {
            guard event.provider == .google else {
                otherEvents.append(event)
                continue
            }
            let key: OccurrenceKey
            if let uid = event.externalId, !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                key = .calendarUID(uid, event.originalOccurrenceStart ?? event.startTime)
            } else {
                // Display IDs are provider/calendar/event scoped. Without a
                // shared UID, never guess equivalence from a title or time.
                key = .exactEventID(event.id)
            }
            if let current = selected[key] {
                if preferred(event, over: current) { selected[key] = event }
            } else {
                selected[key] = event
            }
        }
        return (otherEvents + Array(selected.values)).sorted(by: chronologicalOrder)
    }

    private static func preferred(_ lhs: CalendarEvent, over rhs: CalendarEvent) -> Bool {
        if (lhs.isPrimaryCalendar == true) != (rhs.isPrimaryCalendar == true) {
            return lhs.isPrimaryCalendar == true
        }
        if (lhs.isUserMeeting == true) != (rhs.isUserMeeting == true) {
            return lhs.isUserMeeting == true
        }
        return stableOrder(lhs, rhs)
    }

    private static func chronologicalOrder(_ lhs: CalendarEvent, _ rhs: CalendarEvent) -> Bool {
        if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
        return stableOrder(lhs, rhs)
    }

    private static func stableOrder(_ lhs: CalendarEvent, _ rhs: CalendarEvent) -> Bool {
        let leftIDs = [lhs.provider.rawValue, lhs.calendarIdentifier ?? "", lhs.providerEventID ?? "", lhs.id]
        let rightIDs = [rhs.provider.rawValue, rhs.calendarIdentifier ?? "", rhs.providerEventID ?? "", rhs.id]
        if leftIDs != rightIDs { return leftIDs.lexicographicallyPrecedes(rightIDs) }
        if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
        if lhs.endTime != rhs.endTime { return lhs.endTime < rhs.endTime }
        return lhs.title < rhs.title
    }
}
