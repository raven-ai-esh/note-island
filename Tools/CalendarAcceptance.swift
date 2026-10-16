// Build this probe with MeetingEditing.swift, MeetingsStore.swift and
// MeetingNotifications.swift, then launch it as a signed macOS app with this
// project's Info.plist/entitlements. It uses only its own temporary calendar.
import AppKit
@preconcurrency import EventKit

@main
enum CalendarAcceptance {
    static func main() {
        let application = NSApplication.shared
        let delegate = CalendarAcceptanceDelegate()
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
private final class CalendarAcceptanceDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let result: String
            do { result = try await verifyCalendar() }
            catch { result = "FAIL: \(error.localizedDescription)\n" }
            let path = ProcessInfo.processInfo.arguments.dropFirst().first ?? "/tmp/note-island-calendar-acceptance.txt"
            try? result.write(toFile: path, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    private func verifyCalendar() async throws -> String {
        let ekStore = EKEventStore()
        let provider = EventKitCalendarProvider(eventStore: ekStore)
        try require(provider.accessState == .authorized, "Full Calendar access is required")
        let local = ekStore.sources.first { $0.sourceType == .local }
        guard let source = local ?? ekStore.defaultCalendarForNewEvents?.source else {
            throw failure("No calendar source available")
        }
        let calendar = EKCalendar(for: .event, eventStore: ekStore)
        calendar.title = "Note Island acceptance \(UUID().uuidString)"
        calendar.source = source
        try ekStore.saveCalendar(calendar, commit: true)
        do {
            let store = MeetingsStore(provider: provider)
            store.activate()
            var draft = try store.newMeetingDraft()
            draft.calendarID = calendar.calendarIdentifier
            draft.title = "Note Island synthetic roundtrip"
            draft.startDate = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
            draft.endDate = draft.startDate.addingTimeInterval(3600)
            draft.location = "Demo room"
            draft.notes = "Synthetic acceptance data"
            draft.urlText = "https://example.com/demo"

            func readFresh() throws -> [EKEvent] {
                let verifier = EKEventStore()
                guard let target = verifier.calendar(withIdentifier: calendar.calendarIdentifier) else {
                    throw failure("Committed test calendar is not visible to a separate EventKit store")
                }
                return verifier.events(matching: verifier.predicateForEvents(
                    withStart: draft.startDate.addingTimeInterval(-3600),
                    end: draft.endDate.addingTimeInterval(3 * 86400), calendars: [target]
                )).sorted { $0.startDate < $1.startDate }
            }

            try require(store.saveMeeting(draft), store.mutationError ?? "Create failed")
            guard let created = store.meetings.first(where: { $0.title == draft.title }) else { throw failure("Created item absent from UI store") }
            try require(try readFresh().first?.title == draft.title, "Create did not reach a separate EventKit store")
            var edit = try store.editingDraft(for: created)
            edit.title = "Note Island updated roundtrip"
            edit.location = "Updated demo room"
            try require(store.saveMeeting(edit), store.mutationError ?? "Update failed")
            let fresh = try readFresh()
            try require(fresh.first?.title == edit.title && fresh.first?.location == edit.location, "Update did not reach Calendar")
            guard let updated = store.meetings.first(where: { $0.title == edit.title }) else { throw failure("Updated item absent") }
            try require(store.deleteMeeting(updated), store.mutationError ?? "Delete failed")
            try require(try readFresh().isEmpty, "Deleted item remains in Calendar")

            let series = EKEvent(eventStore: ekStore)
            series.calendar = calendar
            series.title = "Note Island synthetic recurring"
            series.startDate = draft.startDate
            series.endDate = draft.endDate
            series.notes = "Keep this note"
            series.addAlarm(EKAlarm(relativeOffset: -300))
            series.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .daily, interval: 1,
                                                    end: EKRecurrenceEnd(occurrenceCount: 3)))
            try ekStore.save(series, span: .thisEvent, commit: true)
            store.refresh()
            guard let first = store.meetings.first(where: { $0.title == series.title }) else { throw failure("Series occurrence absent") }
            var occurrence = try store.editingDraft(for: first)
            occurrence.title = "Note Island one occurrence only"
            try require(store.saveMeeting(occurrence), store.mutationError ?? "Occurrence edit failed")
            let occurrences = try readFresh()
            try require(occurrences.count == 3, "Recurrence count changed")
            try require(occurrences[0].title == occurrence.title, "Selected occurrence unchanged")
            try require(occurrences.dropFirst().allSatisfy { $0.title == "Note Island synthetic recurring" }, "Other occurrences were changed")
            try require(occurrences[0].notes == "Keep this note" && occurrences[0].alarms?.first?.relativeOffset == -300,
                        "Existing notes or alarms were lost")
            store.refresh()
            guard let detached = store.meetings.first(where: { $0.title == occurrence.title }) else { throw failure("Detached occurrence absent") }
            try require(store.deleteMeeting(detached), store.mutationError ?? "Occurrence deletion failed")
            try require(try readFresh().count == 2, "Deletion affected other occurrences")

            let external = EKEvent(eventStore: ekStore)
            external.calendar = calendar
            external.title = "Note Island synthetic external"
            external.startDate = draft.startDate
            external.endDate = draft.endDate
            try ekStore.save(external, span: .thisEvent, commit: true)
            for _ in 0..<60 where !store.meetings.contains(where: { $0.title == external.title }) {
                try await Task.sleep(for: .milliseconds(100))
            }
            try require(store.meetings.contains { $0.title == external.title }, "External Calendar change did not refresh UI store")

            guard let beforeExternalChange = store.meetings.first(where: { $0.title == external.title }) else { throw failure("External fixture missing") }
            var staleDraft = try store.editingDraft(for: beforeExternalChange)
            staleDraft.title = "Stale draft must not overwrite Calendar"
            try await Task.sleep(for: .milliseconds(1100))
            external.title = "Note Island externally changed"
            try ekStore.save(external, span: .thisEvent, commit: true)
            try require(!store.saveMeeting(staleDraft), "A stale draft overwrote a newer Calendar change")
            try require(try readFresh().contains { $0.title == external.title }, "Newer external data was lost")
            try ekStore.remove(external, span: .thisEvent, commit: true)
            try require(!store.saveMeeting(staleDraft), "A deleted event was recreated by stale save")

            var allDay = draft
            allDay.title = "Note Island synthetic all-day"
            allDay.setAllDay(true)
            allDay.endDate = Calendar.current.date(byAdding: .day, value: 2, to: allDay.startDate)!
            try require(store.saveMeeting(allDay), store.mutationError ?? "All-day create failed")
            let allDayEvents = try readFresh().filter { $0.title == allDay.title }
            try require(allDayEvents.count == 1 && allDayEvents[0].isAllDay, "All-day value did not reach Calendar")
            try require(allDayEvents[0].startDate == allDay.startDate
                        && MeetingDateRange.exclusiveEnd(allDayEvents[0].endDate, isAllDay: true) == allDay.endDate,
                        "All-day date range changed: expected \(allDay.startDate) ... \(allDay.endDate), actual \(String(describing: allDayEvents[0].startDate)) ... \(String(describing: allDayEvents[0].endDate))")
            store.refresh()
            guard let reloadedAllDay = store.meetings.first(where: { $0.title == allDay.title }) else { throw failure("All-day item absent from UI store") }
            var allDayEdit = try store.editingDraft(for: reloadedAllDay)
            try require(allDayEdit.endDate == allDay.endDate, "Reopened all-day draft lost its final day")
            allDayEdit.title = "Note Island all-day reopened"
            try require(store.saveMeeting(allDayEdit), store.mutationError ?? "All-day resave failed")
            guard let resavedAllDay = try readFresh().first(where: { $0.title == allDayEdit.title }) else { throw failure("Resaved all-day item missing") }
            try require(MeetingDateRange.exclusiveEnd(resavedAllDay.endDate, isAllDay: true) == allDay.endDate,
                        "Resaving the all-day event changed range: expected \(allDay.startDate) ... \(allDay.endDate), actual \(String(describing: resavedAllDay.startDate)) ... \(String(describing: resavedAllDay.endDate)); normalized end \(MeetingDateRange.exclusiveEnd(resavedAllDay.endDate, isAllDay: true))")
            store.deactivate()
            try await removeTemporaryCalendar(id: calendar.calendarIdentifier)
            return "PASS: create, update, delete, independent EventKit readback, single-occurrence edit/delete, notes/alarms preserved, external change refresh, stale/deleted drafts blocked, multi-day all-day event, temporary calendar removed.\n"
        } catch {
            try await removeTemporaryCalendar(id: calendar.calendarIdentifier)
            throw error
        }
    }

    private func removeTemporaryCalendar(id: String) async throws {
        // Resolve a fresh object: an older EKCalendar can have stale server metadata
        // after commits in the test. Confirm deletion through another store too.
        let cleanupStore = EKEventStore()
        if let calendar = cleanupStore.calendar(withIdentifier: id) {
            try cleanupStore.removeCalendar(calendar, commit: true)
        }
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            if EKEventStore().calendar(withIdentifier: id) == nil { return }
        }
        throw failure("Temporary acceptance calendar was not removed from the database")
    }

    private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw failure(message) }
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "NoteIsland.CalendarAcceptance", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
