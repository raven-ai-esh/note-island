import AppKit
@preconcurrency import EventKit
import Foundation

struct MeetingCalendar: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let color: MeetingColor
    let isDefault: Bool
}

enum MeetingDateRange {
    static func eventKitEnd(_ end: Date, isAllDay: Bool) -> Date {
        isAllDay ? end.addingTimeInterval(-1) : end
    }

    static func exclusiveEnd(_ end: Date, isAllDay: Bool, calendar: Calendar = .autoupdatingCurrent) -> Date {
        guard isAllDay else { return end }
        let day = calendar.startOfDay(for: end)
        // EventKit may return 23:59:59 for all-day events after a database read.
        // Keep the UI model exclusive so reopening/saving does not lose a day.
        guard end != day else { return end }
        return calendar.date(byAdding: .day, value: 1, to: day) ?? end
    }
}

enum MeetingEditingError: LocalizedError {
    case permissionDenied, noWritableCalendar, readOnly, eventNotFound, changedExternally
    case missingTitle, invalidDates, invalidURL

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Нет доступа к календарю. Разрешите полный доступ в настройках macOS."
        case .noWritableCalendar: "Нет доступного для записи календаря. Добавьте его в Apple Calendar."
        case .readOnly: "Этот календарь доступен только для чтения."
        case .eventNotFound: "Событие больше не существует. Обновите список встреч."
        case .changedExternally: "Событие изменилось в календаре. Закройте редактор и откройте его заново."
        case .missingTitle: "Введите название встречи."
        case .invalidDates: "Окончание должно быть позже начала."
        case .invalidURL: "Укажите полную ссылку, начинающуюся с https:// или http://."
        }
    }
}

struct MeetingDraft: Identifiable, Equatable {
    let id = UUID()
    let original: MeetingItem?
    var title: String
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var calendarID: String
    var location: String
    var urlText: String
    var notes: String

    init(calendarID: String, now: Date = Date()) {
        original = nil
        title = ""
        startDate = Date(timeIntervalSinceReferenceDate: ceil(now.timeIntervalSinceReferenceDate / 900) * 900)
        endDate = startDate.addingTimeInterval(3600)
        isAllDay = false
        self.calendarID = calendarID
        location = ""
        urlText = ""
        notes = ""
    }

    init(meeting: MeetingItem) {
        original = meeting
        title = meeting.title
        startDate = meeting.startDate
        endDate = meeting.endDate
        isAllDay = meeting.isAllDay
        calendarID = meeting.calendarID ?? ""
        location = meeting.location ?? ""
        urlText = meeting.storedURL?.absoluteString ?? ""
        notes = meeting.notes ?? ""
    }

    mutating func setAllDay(_ value: Bool, calendar: Calendar = .autoupdatingCurrent) {
        isAllDay = value
        if value {
            startDate = calendar.startOfDay(for: startDate)
            let lastDay = calendar.startOfDay(for: max(startDate, endDate.addingTimeInterval(-1)))
            endDate = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? startDate.addingTimeInterval(86400)
        } else {
            endDate = startDate.addingTimeInterval(3600)
        }
    }

    func validated(calendar: Calendar = .autoupdatingCurrent) throws -> MeetingDraft {
        var result = self
        result.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.title.isEmpty else { throw MeetingEditingError.missingTitle }
        guard !calendarID.isEmpty else { throw MeetingEditingError.noWritableCalendar }
        if isAllDay {
            result.startDate = calendar.startOfDay(for: startDate)
            result.endDate = calendar.startOfDay(for: endDate)
        }
        guard result.endDate > result.startDate else { throw MeetingEditingError.invalidDates }
        result.urlText = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !result.urlText.isEmpty {
            guard let url = URL(string: result.urlText),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty else { throw MeetingEditingError.invalidURL }
        }
        return result
    }
}

extension CalendarEventProviding {
    func calendarsForEditing() throws -> [MeetingCalendar] { [] }
    func saveMeeting(_ draft: MeetingDraft) throws { throw MeetingEditingError.readOnly }
    func deleteMeeting(_ meeting: MeetingItem) throws { throw MeetingEditingError.readOnly }
}

extension EventKitCalendarProvider {
    func calendarsForEditing() throws -> [MeetingCalendar] {
        guard accessState == .authorized else { throw MeetingEditingError.permissionDenied }
        let defaultID = eventStore.defaultCalendarForNewEvents?.calendarIdentifier
        return eventStore.calendars(for: .event)
            .filter(\.allowsContentModifications)
            .map { calendar in
                let color = calendar.cgColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.deviceRGB) }
                return MeetingCalendar(
                    id: calendar.calendarIdentifier, title: calendar.title,
                    color: color.map { MeetingColor(red: $0.redComponent, green: $0.greenComponent, blue: $0.blueComponent) } ?? .fallback,
                    isDefault: calendar.calendarIdentifier == defaultID
                )
            }
            .sorted { $0.isDefault != $1.isDefault ? $0.isDefault : $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func saveMeeting(_ draft: MeetingDraft) throws {
        guard accessState == .authorized else { throw MeetingEditingError.permissionDenied }
        let draft = try draft.validated()
        guard let destination = eventStore.calendar(withIdentifier: draft.calendarID),
              destination.allowsContentModifications else { throw MeetingEditingError.readOnly }
        let event: EKEvent
        if let original = draft.original {
            event = try editableEvent(for: original)
        } else {
            event = EKEvent(eventStore: eventStore)
        }
        // Edit the fetched event so recurrence, attendees, alarms and other fields survive.
        event.title = draft.title
        event.calendar = destination
        event.isAllDay = draft.isAllDay
        event.startDate = draft.startDate
        event.endDate = MeetingDateRange.eventKitEnd(draft.endDate, isAllDay: draft.isAllDay)
        event.location = draft.location.isEmpty ? nil : draft.location
        event.url = draft.urlText.isEmpty ? nil : URL(string: draft.urlText)
        event.notes = draft.notes.isEmpty ? nil : draft.notes
        try eventStore.save(event, span: .thisEvent, commit: true)
    }

    func deleteMeeting(_ meeting: MeetingItem) throws {
        guard accessState == .authorized else { throw MeetingEditingError.permissionDenied }
        try eventStore.remove(editableEvent(for: meeting), span: .thisEvent, commit: true)
    }

    private func editableEvent(for meeting: MeetingItem) throws -> EKEvent {
        guard meeting.canEdit else { throw MeetingEditingError.readOnly }
        // Looking up an identifier alone can return the series master. Match the occurrence.
        let predicate = eventStore.predicateForEvents(
            withStart: meeting.startDate.addingTimeInterval(-1),
            end: meeting.endDate.addingTimeInterval(1), calendars: nil
        )
        guard let event = eventStore.events(matching: predicate).first(where: {
            Self.meetingItem(from: $0).id == meeting.id && $0.calendar.calendarIdentifier == meeting.calendarID
        }) else { throw MeetingEditingError.eventNotFound }
        guard event.calendar.allowsContentModifications else { throw MeetingEditingError.readOnly }
        if let expected = meeting.lastModifiedDate, let actual = event.lastModifiedDate,
           abs(expected.timeIntervalSince(actual)) > 0.001 {
            throw MeetingEditingError.changedExternally
        }
        return event
    }
}
