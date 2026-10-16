import AppKit
import EventKit
import XCTest
@testable import NoteIsland

@MainActor
final class MeetingEditingTests: XCTestCase {
    func testCreateUpdateDeleteRefreshTheListAndTargetTheChosenEvent() throws {
        let provider = EditingCalendarProvider()
        let store = MeetingsStore(provider: provider)
        store.activate()
        var draft = try store.newMeetingDraft()
        draft.title = "Проверка календаря"
        draft.location = "Переговорная"
        draft.notes = "Повестка встречи"
        draft.urlText = "https://example.com/meeting"
        XCTAssertTrue(store.saveMeeting(draft))
        let created = try XCTUnwrap(store.meetings.first)
        XCTAssertEqual(created.title, draft.title)
        XCTAssertEqual(provider.savedDrafts.count, 1)

        var edit = try store.editingDraft(for: created)
        edit.title = "Обновлённая встреча"
        XCTAssertTrue(store.saveMeeting(edit))
        XCTAssertEqual(provider.savedDrafts.last?.original?.id, created.id)
        XCTAssertEqual(store.meetings.first?.title, edit.title)
        XCTAssertTrue(store.deleteMeeting(try XCTUnwrap(store.meetings.first)))
        XCTAssertEqual(provider.deletedIDs, [created.id])
        XCTAssertTrue(store.meetings.isEmpty)
    }

    func testValidationAndReadOnlyCalendarDoNotWriteAnything() throws {
        let provider = EditingCalendarProvider()
        let store = MeetingsStore(provider: provider)
        var draft = try store.newMeetingDraft()
        XCTAssertFalse(store.saveMeeting(draft))
        XCTAssertNotNil(store.mutationError)
        draft.title = "Встреча"
        draft.endDate = draft.startDate
        XCTAssertFalse(store.saveMeeting(draft))
        draft.endDate = draft.startDate.addingTimeInterval(600)
        draft.urlText = "not a URL"
        XCTAssertFalse(store.saveMeeting(draft))
        draft.urlText = ""
        draft.calendarID = "read-only"
        XCTAssertFalse(store.saveMeeting(draft))
        XCTAssertTrue(provider.savedDrafts.isEmpty)
    }

    func testPermissionRevocationAndMissingEventNeverReportSuccess() throws {
        let provider = EditingCalendarProvider()
        let store = MeetingsStore(provider: provider)
        var draft = try store.newMeetingDraft()
        draft.title = "Встреча"
        provider.accessState = .denied
        XCTAssertFalse(store.saveMeeting(draft))
        XCTAssertTrue(provider.savedDrafts.isEmpty)
        provider.accessState = .authorized
        XCTAssertTrue(store.saveMeeting(draft))
        let event = try XCTUnwrap(store.meetings.first)
        provider.failure = MeetingEditingError.eventNotFound
        XCTAssertFalse(store.deleteMeeting(event))
        XCTAssertEqual(store.meetings.count, 1)
        XCTAssertNotNil(store.mutationError)
    }

    func testFailureKeepsTheDraftAndRetryRefreshesList() throws {
        let provider = EditingCalendarProvider()
        let store = MeetingsStore(provider: provider)
        var draft = try store.newMeetingDraft()
        draft.title = "Не терять черновик"
        provider.failure = TestCalendarError.fetchFailed
        XCTAssertFalse(store.saveMeeting(draft))
        XCTAssertNotNil(store.mutationError)
        provider.failure = nil
        XCTAssertTrue(store.saveMeeting(draft))
        XCTAssertNil(store.mutationError)
        XCTAssertEqual(store.meetings.map(\.title), [draft.title])
    }

    func testAllDayDraftUsesExclusiveEndAndSupportsMultiDayEvents() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        var draft = MeetingDraft(calendarID: "local", now: now)
        draft.title = "Отпуск"
        draft.setAllDay(true, calendar: calendar)
        XCTAssertEqual(draft.startDate, calendar.startOfDay(for: now))
        XCTAssertEqual(draft.endDate, calendar.date(byAdding: .day, value: 1, to: draft.startDate))
        XCTAssertNoThrow(try draft.validated(calendar: calendar))
    }

    func testEventKitInclusiveAllDayEndNormalizesWithoutLosingLastDayOnResave() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_789_000_000))
        let exclusiveEnd = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: start))
        let inclusiveEnd = exclusiveEnd.addingTimeInterval(-1)
        XCTAssertEqual(MeetingDateRange.exclusiveEnd(inclusiveEnd, isAllDay: true, calendar: calendar), exclusiveEnd)
        XCTAssertEqual(MeetingDateRange.exclusiveEnd(exclusiveEnd, isAllDay: true, calendar: calendar), exclusiveEnd)
        XCTAssertEqual(MeetingDateRange.exclusiveEnd(inclusiveEnd, isAllDay: false, calendar: calendar), inclusiveEnd)
        XCTAssertEqual(MeetingDateRange.eventKitEnd(exclusiveEnd, isAllDay: true), inclusiveEnd)
        XCTAssertEqual(MeetingDateRange.eventKitEnd(exclusiveEnd, isAllDay: false), exclusiveEnd)
    }

    func testNoWritableCalendarIsAnExplicitFailure() {
        let provider = EditingCalendarProvider()
        provider.calendars = []
        let store = MeetingsStore(provider: provider)
        XCTAssertThrowsError(try store.newMeetingDraft())
        XCTAssertFalse(store.canCreateMeetings)
    }

    func testMutationsRescheduleAndCancelMeetingNotifications() throws {
        let provider = EditingCalendarProvider()
        let scheduler = EditingNotificationScheduler()
        let now = Date()
        let store = MeetingsStore(provider: provider, notificationScheduler: scheduler, now: { now })
        store.activate()
        store.toggleNotifications()
        var draft = try store.newMeetingDraft()
        draft.title = "Напоминание"
        draft.startDate = now.addingTimeInterval(3600)
        draft.endDate = now.addingTimeInterval(7200)
        XCTAssertTrue(store.saveMeeting(draft))
        XCTAssertEqual(scheduler.requests.count, 1)
        XCTAssertEqual(scheduler.requests.first?.title, "Скоро: Напоминание")
        var edit = try store.editingDraft(for: XCTUnwrap(store.meetings.first))
        edit.startDate = edit.startDate.addingTimeInterval(900)
        XCTAssertTrue(store.saveMeeting(edit))
        XCTAssertEqual(scheduler.requests.first?.fireDate, edit.startDate.addingTimeInterval(-600))
        XCTAssertTrue(store.deleteMeeting(try XCTUnwrap(store.meetings.first)))
        XCTAssertTrue(scheduler.requests.isEmpty)
    }

    func testEventKitMappingExposesPermissionAndRecurringOccurrenceIdentity() {
        let ekStore = EKEventStore()
        let calendar = EKCalendar(for: .event, eventStore: ekStore)
        calendar.title = "Demo"
        let event = EKEvent(eventStore: ekStore)
        event.calendar = calendar
        event.title = "Повторяющаяся встреча"
        event.startDate = Date()
        event.endDate = Date().addingTimeInterval(3600)
        event.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil))
        let mapped = EventKitCalendarProvider.meetingItem(from: event)
        XCTAssertTrue(mapped.isRecurring)
        XCTAssertEqual(mapped.calendarID, calendar.calendarIdentifier)
        XCTAssertEqual(mapped.canEdit, calendar.allowsContentModifications)
    }
}

@MainActor
private final class EditingNotificationScheduler: MeetingNotificationScheduling {
    var requests: [MeetingNotificationRequest] = []
    func getAuthorizationStatus(_ completion: @escaping @MainActor @Sendable (MeetingNotificationAuthorization) -> Void) {
        completion(.authorized)
    }
    func requestAuthorization(_ completion: @escaping @MainActor @Sendable (Result<Bool, Error>) -> Void) {
        completion(.success(true))
    }
    func replacePendingRequests(with requests: [MeetingNotificationRequest], completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void) {
        self.requests = requests
        completion(.success(()))
    }
    func cancelAll() { requests = [] }
}

@MainActor
final class EditingCalendarProvider: CalendarEventProviding {
    var accessState: CalendarAccessState = .authorized
    var calendars = [MeetingCalendar(id: "local", title: "Личный", color: .fallback, isDefault: true)]
    var items: [MeetingItem] = []
    var failure: Error?
    var savedDrafts: [MeetingDraft] = []
    var deletedIDs: [String] = []
    var change: (() -> Void)?

    func requestFullAccess(completion: @escaping (Result<Bool, Error>) -> Void) { completion(.success(true)) }
    func events(from startDate: Date, through endDate: Date) throws -> [MeetingItem] { items }
    func observeChanges(_ handler: @escaping () -> Void) { change = handler }
    func calendarsForEditing() throws -> [MeetingCalendar] { calendars }
    func saveMeeting(_ draft: MeetingDraft) throws {
        if let failure { throw failure }
        savedDrafts.append(draft)
        let id = draft.original?.id ?? UUID().uuidString
        items.removeAll { $0.id == id }
        items.append(MeetingItem(
            id: id, title: draft.title, startDate: draft.startDate, endDate: draft.endDate,
            isAllDay: draft.isAllDay, location: draft.location, calendarTitle: "Личный",
            calendarColor: .fallback, url: URL(string: draft.urlText), notes: draft.notes,
            calendarID: draft.calendarID, canEdit: true
        ))
    }
    func deleteMeeting(_ meeting: MeetingItem) throws {
        if let failure { throw failure }
        deletedIDs.append(meeting.id)
        items.removeAll { $0.id == meeting.id }
    }
}

@MainActor
final class IslandAutoCollapseTests: XCTestCase {
    func testOutsideClickCollapsesOnlyAnExpandedUnpinnedPanel() {
        let defaults = UserDefaults(suiteName: "NoteIsland.pin-test.\(UUID().uuidString)")!
        let state = IslandPresentationState(defaults: defaults)
        XCTAssertFalse(state.shouldAutomaticallyCollapse)
        state.isExpanded = true
        XCTAssertTrue(state.shouldAutomaticallyCollapse)
        state.togglePanelPin()
        XCTAssertFalse(state.shouldAutomaticallyCollapse)
        XCTAssertTrue(IslandPresentationState(defaults: defaults).isPanelPinned)
        state.togglePanelPin()
        XCTAssertTrue(state.shouldAutomaticallyCollapse)
        state.isExpanded = false
        XCTAssertFalse(state.shouldAutomaticallyCollapse)
    }

    func testInsideAndMenuClicksAreNotTreatedAsOutsideButAnotherWindowIs() {
        let panel = IslandPanel(contentRect: NSRect(x: 200, y: 200, width: 560, height: 388),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        let otherWindow = NSWindow(contentRect: NSRect(x: 800, y: 200, width: 300, height: 200),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        let menu = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        menu.level = .popUpMenu
        XCTAssertFalse(IslandOutsideClickMonitor.isOutside(panel, point: panel.frame.centerPoint, eventWindow: panel))
        XCTAssertFalse(IslandOutsideClickMonitor.isOutside(panel, point: .zero, eventWindow: menu))
        XCTAssertTrue(IslandOutsideClickMonitor.isOutside(panel, point: .zero, eventWindow: otherWindow))
        XCTAssertTrue(IslandOutsideClickMonitor.isOutside(panel, point: .zero, eventWindow: nil))
    }

    func testInstalledMonitorProcessesRealAppKitDispatchAndKeepsOriginalClick() throws {
        let panel = IslandPanel(contentRect: NSRect(x: 200, y: 200, width: 560, height: 388),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: NSRect(x: 800, y: 200, width: 300, height: 200),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        panel.orderFront(nil)
        defer { panel.orderOut(nil); other.orderOut(nil) }
        var pinned = false
        var collapseCount = 0
        let monitor = IslandOutsideClickMonitor(panel: panel, shouldCollapse: { !pinned },
                                                collapse: { collapseCount += 1 })
        defer { monitor.stop() }
        func click(in window: NSWindow) throws {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown, location: NSPoint(x: 25, y: 25), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1
            ))
            NSApp.sendEvent(event)
        }
        try click(in: panel)
        XCTAssertEqual(collapseCount, 0)
        try click(in: other)
        XCTAssertEqual(collapseCount, 1)
        pinned = true
        try click(in: other)
        XCTAssertEqual(collapseCount, 1)
        pinned = false
        try click(in: other)
        XCTAssertEqual(collapseCount, 2)
    }
}


private extension NSRect {
    var centerPoint: NSPoint { NSPoint(x: midX, y: midY) }
}
