import Foundation
import AppKit
@preconcurrency import EventKit
import SwiftUI
import XCTest
@testable import NoteIsland

@MainActor
final class MeetingsStoreTests: XCTestCase {
    func testAuthorizedCalendarLoadsOnlyTodayAndSortsProviderResult() throws {
        let provider = TestCalendarProvider()
        provider.accessState = .authorized
        provider.eventsResult = .success([sampleMeeting(title: "Созвон")])
        let calendar = fixedCalendar
        let store = MeetingsStore(provider: provider, calendar: calendar)

        store.activate()

        XCTAssertEqual(store.state, .ready)
        XCTAssertEqual(store.meetings.map(\.title), ["Созвон"])
        XCTAssertEqual(provider.fetchCount, 1)
        XCTAssertEqual(
            try XCTUnwrap(provider.lastStartDate).timeIntervalSinceReferenceDate,
            calendar.startOfDay(for: provider.referenceNow).timeIntervalSinceReferenceDate,
            accuracy: 1
        )
        XCTAssertEqual(
            try XCTUnwrap(provider.lastEndDate).timeIntervalSinceReferenceDate,
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: provider.referenceNow))!.timeIntervalSinceReferenceDate,
            accuracy: 1
        )
    }

    func testAuthorizedCalendarSupportsEmptyTodayState() {
        let provider = TestCalendarProvider()
        provider.accessState = .authorized
        provider.eventsResult = .success([])
        let store = MeetingsStore(provider: provider, calendar: fixedCalendar)

        store.activate()

        XCTAssertEqual(store.state, .ready)
        XCTAssertTrue(store.meetings.isEmpty)
    }

    func testFirstActivationWaitsForPermissionThenLoadsEvents() {
        let provider = TestCalendarProvider()
        provider.accessState = .notDetermined
        provider.eventsResult = .success([sampleMeeting(title: "Демо")])
        provider.completesRequestAutomatically = false
        let store = MeetingsStore(provider: provider, calendar: fixedCalendar)

        store.activate()
        XCTAssertEqual(store.state, .idle)
        XCTAssertEqual(provider.requestCount, 0)

        store.requestAuthorization()
        XCTAssertEqual(store.state, .requestingAccess)
        XCTAssertEqual(provider.requestCount, 1)
        XCTAssertEqual(provider.fetchCount, 0)

        provider.completeAccessRequest(.success(true))

        XCTAssertEqual(store.state, .ready)
        XCTAssertEqual(store.meetings.map(\.title), ["Демо"])
        XCTAssertEqual(provider.fetchCount, 1)
    }

    func testDeniedPermissionShowsDeniedWithoutReadingEvents() {
        let provider = TestCalendarProvider()
        provider.accessState = .notDetermined
        provider.requestResult = .success(false)
        let store = MeetingsStore(provider: provider, calendar: fixedCalendar)

        store.activate()
        store.requestAuthorization()

        XCTAssertEqual(store.state, .denied)
        XCTAssertTrue(store.meetings.isEmpty)
        XCTAssertEqual(provider.fetchCount, 0)
    }

    func testRestrictedAndWriteOnlyAccessNeverReadEvents() {
        for accessState in [CalendarAccessState.restricted, .writeOnly] {
            let provider = TestCalendarProvider()
            provider.accessState = accessState
            let store = MeetingsStore(provider: provider, calendar: fixedCalendar)

            store.activate()

            XCTAssertEqual(store.state, accessState == .restricted ? .restricted : .denied)
            XCTAssertEqual(provider.fetchCount, 0)
        }
    }

    func testFailureCanRetrySuccessfully() {
        let provider = TestCalendarProvider()
        provider.accessState = .authorized
        provider.eventsResult = .failure(TestCalendarError.fetchFailed)
        let store = MeetingsStore(provider: provider, calendar: fixedCalendar)

        store.activate()
        XCTAssertEqual(store.state, .failed("Не удалось прочитать календарь"))

        provider.eventsResult = .success([sampleMeeting(title: "После повтора")])
        store.retry()

        XCTAssertEqual(store.state, .ready)
        XCTAssertEqual(store.meetings.map(\.title), ["После повтора"])
        XCTAssertEqual(provider.fetchCount, 2)
    }

    func testCalendarChangeRefreshesOnlyWhileMeetingsAreVisible() {
        let provider = TestCalendarProvider()
        provider.accessState = .authorized
        provider.eventsResult = .success([])
        let store = MeetingsStore(provider: provider, calendar: fixedCalendar)

        store.activate()
        provider.sendCalendarChange()
        XCTAssertEqual(provider.fetchCount, 2)

        store.deactivate()
        provider.sendCalendarChange()
        XCTAssertEqual(provider.fetchCount, 2)
    }

    func testModeShortcutMetadataIsStable() {
        XCTAssertEqual(IslandMode.notes.shortcutTitle, "⌘⇧N")
        XCTAssertEqual(IslandMode.translator.shortcutTitle, "⌘⇧T")
        XCTAssertEqual(IslandMode.meetings.shortcutTitle, "⌘⇧M")
        XCTAssertEqual(IslandMode.recordings.shortcutTitle, "⌘⇧R")
        XCTAssertEqual(IslandMode.screenshots.shortcutTitle, "⌘⇧S")
        XCTAssertEqual(IslandMode(hotKeyID: 1), .notes)
        XCTAssertEqual(IslandMode(hotKeyID: 2), .translator)
        XCTAssertEqual(IslandMode(hotKeyID: 3), .meetings)
        XCTAssertEqual(IslandMode(hotKeyID: 4), .recordings)
        XCTAssertEqual(IslandMode(hotKeyID: 5), .screenshots)
        XCTAssertNil(IslandMode(hotKeyID: 99))
    }

    func testMeetingsTodayHeadingHasReadableLightPixelsOnDarkBackground() throws {
        let provider = TestCalendarProvider()
        provider.eventsResult = .success([])
        let store = MeetingsStore(provider: provider, calendar: fixedCalendar)
        store.activate()
        let bitmap = try render(
            MeetingsView(meetings: store).background(Color.black),
            size: NSSize(width: 560, height: 330)
        )
        var brightPixels = 0
        for x in 12..<150 {
            for y in 2..<65 {
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if pixel.redComponent + pixel.greenComponent + pixel.blueComponent > 2.45 {
                    brightPixels += 1
                }
            }
        }
        XCTAssertGreaterThan(brightPixels, 80)
    }

    func testMeetingsViewRendersTodayEventOnInitialDisplayPass() throws {
        let filledProvider = TestCalendarProvider()
        filledProvider.eventsResult = .success([sampleMeeting(title: "Встреча с командой")])
        let filledStore = MeetingsStore(provider: filledProvider, calendar: fixedCalendar)
        filledStore.activate()

        let emptyProvider = TestCalendarProvider()
        emptyProvider.eventsResult = .success([])
        let emptyStore = MeetingsStore(provider: emptyProvider, calendar: fixedCalendar)
        emptyStore.activate()

        let filledBitmap = try render(MeetingsView(meetings: filledStore), size: NSSize(width: 560, height: 330))
        let emptyBitmap = try render(MeetingsView(meetings: emptyStore), size: NSSize(width: 560, height: 330))
        var changedPixels = 0
        for x in 20..<540 {
            for y in 20..<260 {
                guard let filledPixel = filledBitmap.colorAt(x: x, y: y),
                      let emptyPixel = emptyBitmap.colorAt(x: x, y: y) else { continue }
                let red = abs(filledPixel.redComponent - emptyPixel.redComponent)
                let green = abs(filledPixel.greenComponent - emptyPixel.greenComponent)
                let blue = abs(filledPixel.blueComponent - emptyPixel.blueComponent)
                if red + green + blue > 0.15 { changedPixels += 1 }
            }
        }
        XCTAssertGreaterThan(changedPixels, 120)
    }

    func testMeetingTemporalStateUsesEndForPastAndStartEndForCurrent() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(
            MeetingTemporalState.resolve(
                startDate: now.addingTimeInterval(-3_600),
                endDate: now,
                now: now
            ),
            .past
        )
        XCTAssertEqual(
            MeetingTemporalState.resolve(
                startDate: now,
                endDate: now.addingTimeInterval(3_600),
                now: now
            ),
            .current
        )
        XCTAssertEqual(
            MeetingTemporalState.resolve(
                startDate: now.addingTimeInterval(60),
                endDate: now.addingTimeInterval(3_600),
                now: now
            ),
            .upcoming
        )
    }

    func testPastMeetingIsDimmedAndCurrentMeetingHasVisibleAccent() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func meeting(id: String, start: TimeInterval, end: TimeInterval) -> MeetingItem {
            MeetingItem(
                id: id,
                title: "Статус встречи",
                startDate: now.addingTimeInterval(start),
                endDate: now.addingTimeInterval(end),
                isAllDay: false,
                location: nil,
                calendarTitle: "Работа",
                calendarColor: MeetingColor(red: 0.2, green: 0.8, blue: 0.5)
            )
        }
        let actions = TestMeetingActions()
        let size = NSSize(width: 520, height: 82)
        let past = try render(
            MeetingRow(
                meeting: meeting(id: "past", start: -7_200, end: -3_600),
                expanded: false,
                actions: actions,
                now: now,
                toggleAction: {}
            ).background(Color.black),
            size: size
        )
        let current = try render(
            MeetingRow(
                meeting: meeting(id: "current", start: -1_800, end: 1_800),
                expanded: false,
                actions: actions,
                now: now,
                toggleAction: {}
            ).background(Color.black),
            size: size
        )
        let upcoming = try render(
            MeetingRow(
                meeting: meeting(id: "upcoming", start: 3_600, end: 7_200),
                expanded: false,
                actions: actions,
                now: now,
                toggleAction: {}
            ).background(Color.black),
            size: size
        )

        XCTAssertLessThan(brightPixelCount(in: past), brightPixelCount(in: upcoming) * 3 / 4)
        XCTAssertGreaterThan(
            matchingPixelCount(in: current, color: NSColor(red: 0.2, green: 0.8, blue: 0.5, alpha: 1)),
            matchingPixelCount(in: upcoming, color: NSColor(red: 0.2, green: 0.8, blue: 0.5, alpha: 1)) + 250
        )
    }

    func testEventKitMappingPreservesLocationNotesAndMeetingLink() throws {
        let eventStore = EKEventStore()
        let calendar = EKCalendar(for: .event, eventStore: eventStore)
        calendar.title = "Команда"
        calendar.cgColor = NSColor.systemPurple.cgColor
        let event = EKEvent(eventStore: eventStore)
        event.calendar = calendar
        event.title = "Планирование"
        event.startDate = Date(timeIntervalSince1970: 1_700_000_000)
        event.endDate = Date(timeIntervalSince1970: 1_700_003_600)
        event.location = "Переговорная 4"
        event.notes = "Подключение: https://meet.google.com/abc-defg-hij"

        let item = EventKitCalendarProvider.meetingItem(from: event)

        XCTAssertEqual(item.location, "Переговорная 4")
        XCTAssertEqual(item.notes, "Подключение: https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(item.url?.absoluteString, "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(item.calendarTitle, "Команда")
        XCTAssertTrue(item.hasExtendedDetails)
    }

    func testMeetingLinkPrefersConferenceURLAndFallsBackToExplicitOrEmbeddedWebURL() {
        let explicit = URL(string: "https://zoom.us/j/123")!
        XCTAssertEqual(
            MeetingLinkExtractor.firstWebURL(
                explicitURL: explicit,
                notes: "https://meet.google.com/fallback",
                location: nil
            ),
            explicit
        )
        XCTAssertEqual(
            MeetingLinkExtractor.firstWebURL(
                explicitURL: URL(string: "https://calendar.yandex.ru/event?id=123"),
                notes: "Ссылка: https://teams.microsoft.com/l/meetup-join/456",
                location: nil
            )?.host,
            "teams.microsoft.com"
        )
        XCTAssertEqual(
            MeetingLinkExtractor.firstWebURL(
                explicitURL: URL(string: "https://calendar.yandex.ru/event?id=123"),
                notes: "Документы без ссылки",
                location: nil
            )?.host,
            "calendar.yandex.ru"
        )
        XCTAssertNil(MeetingLinkExtractor.firstWebURL(explicitURL: nil, notes: "Без ссылки", location: "Офис"))
    }

    func testContextMenuAvailabilityAndEveryActionTargetsClickedMeeting() throws {
        let meeting = detailedMeeting()
        let actions = TestMeetingActions()
        var toggleCount = 0
        let row = MeetingRow(
            meeting: meeting,
            expanded: false,
            actions: actions,
            toggleAction: { toggleCount += 1 }
        )

        let menuActions = MeetingMenuAction.available(for: meeting)
        XCTAssertEqual(menuActions, [
            .toggleDetails, .openLink, .copyTitle, .copyLink, .copyLocation, .copyDetails
        ])
        XCTAssertEqual(menuActions.map { $0.title(expanded: false) }, [
            "Подробнее", "Открыть ссылку", "Скопировать название", "Скопировать ссылку",
            "Скопировать место", "Скопировать сведения"
        ])

        menuActions.forEach(row.perform)

        XCTAssertEqual(toggleCount, 1)
        XCTAssertEqual(actions.openedURLs, [try XCTUnwrap(meeting.url)])
        XCTAssertEqual(actions.copiedTexts[0], meeting.title)
        XCTAssertEqual(actions.copiedTexts[1], meeting.url?.absoluteString)
        XCTAssertEqual(actions.copiedTexts[2], meeting.location)
        XCTAssertEqual(actions.copiedTexts[3], MeetingActionContent.details(for: meeting))
    }

    func testEventWithoutOptionalDetailsHasUsefulContextMenuAndNoEmptyExpansionAction() {
        let meeting = sampleMeeting(title: "Фокус-время")

        XCTAssertFalse(meeting.hasExtendedDetails)
        XCTAssertEqual(MeetingMenuAction.available(for: meeting), [.copyTitle, .copyDetails])
    }

    func testExpandedMeetingRendersAllDetailSectionsAndIsTallerThanCollapsedRow() {
        let meeting = detailedMeeting()
        let actions = TestMeetingActions()
        let collapsed = MeetingRow(meeting: meeting, expanded: false, actions: actions, toggleAction: {})
        let expanded = MeetingRow(meeting: meeting, expanded: true, actions: actions, toggleAction: {})

        let collapsedHeight = fittingHeight(collapsed)
        let expandedHeight = fittingHeight(expanded)

        XCTAssertGreaterThan(expandedHeight, collapsedHeight + 100)
        XCTAssertEqual(meeting.participants.count, 2)
        XCTAssertNotNil(meeting.organizer)
        XCTAssertNotNil(meeting.location)
        XCTAssertNotNil(meeting.url)
        XCTAssertNotNil(meeting.notes)
    }

    func testSystemMeetingCopyWritesExactTextToRealNamedPasteboard() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("NoteIsland.MeetingsTests.\(UUID().uuidString)"))
        let actions = SystemMeetingActions(pasteboard: pasteboard, openURL: { _ in false })

        XCTAssertTrue(actions.copy("Детали события"))
        XCTAssertEqual(pasteboard.string(forType: .string), "Детали события")
    }

    private var fixedCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func sampleMeeting(title: String) -> MeetingItem {
        MeetingItem(
            id: title,
            title: title,
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_003_600),
            isAllDay: false,
            location: nil,
            calendarTitle: "Работа",
            calendarColor: .fallback
        )
    }

    private func detailedMeeting() -> MeetingItem {
        MeetingItem(
            id: "detailed-meeting",
            title: "Демонстрация продукта",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_003_600),
            isAllDay: false,
            location: "Переговорная 4, второй этаж",
            calendarTitle: "Работа",
            calendarColor: .fallback,
            url: URL(string: "https://meet.google.com/abc-defg-hij"),
            notes: "Обсудить запуск и следующие шаги.",
            organizer: MeetingParticipant(
                id: "organizer@example.com",
                name: "Анна",
                email: "organizer@example.com",
                status: .accepted,
                role: .organizer
            ),
            participants: [
                MeetingParticipant(
                    id: "one@example.com",
                    name: "Иван",
                    email: "one@example.com",
                    status: .accepted,
                    role: .required
                ),
                MeetingParticipant(
                    id: "two@example.com",
                    name: "Ольга",
                    email: "two@example.com",
                    status: .tentative,
                    role: .optional
                )
            ]
        )
    }

    private func fittingHeight<V: View>(_ view: V) -> CGFloat {
        let hostingView = NSHostingView(rootView: view.frame(width: 520))
        hostingView.layoutSubtreeIfNeeded()
        return hostingView.fittingSize.height
    }

    private func render<V: View>(_ view: V, size: NSSize) throws -> NSBitmapImageRep {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw NSError(domain: "MeetingsTests", code: 1)
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        return bitmap
    }

    private func brightPixelCount(in bitmap: NSBitmapImageRep) -> Int {
        var count = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent + color.greenComponent + color.blueComponent > 1.8 { count += 1 }
            }
        }
        return count
    }

    private func matchingPixelCount(in bitmap: NSBitmapImageRep, color: NSColor) -> Int {
        guard let target = color.usingColorSpace(.deviceRGB) else { return 0 }
        var count = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let sample = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let distance = abs(sample.redComponent - target.redComponent)
                    + abs(sample.greenComponent - target.greenComponent)
                    + abs(sample.blueComponent - target.blueComponent)
                if distance < 0.35, sample.alphaComponent > 0.5 { count += 1 }
            }
        }
        return count
    }
}

@MainActor
private final class TestMeetingActions: MeetingActionProviding {
    private(set) var copiedTexts: [String] = []
    private(set) var openedURLs: [URL] = []

    func copy(_ text: String) -> Bool {
        copiedTexts.append(text)
        return true
    }

    func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return true
    }
}

enum TestCalendarError: LocalizedError {
    case fetchFailed

    var errorDescription: String? { "Не удалось прочитать календарь" }
}

@MainActor
final class TestCalendarProvider: CalendarEventProviding {
    var accessState: CalendarAccessState = .authorized
    var requestResult: Result<Bool, Error> = .success(true)
    var eventsResult: Result<[MeetingItem], Error> = .success([])
    var completesRequestAutomatically = true
    private(set) var requestCount = 0
    private(set) var fetchCount = 0
    private(set) var lastStartDate: Date?
    private(set) var lastEndDate: Date?
    let referenceNow = Date()

    private var accessCompletion: ((Result<Bool, Error>) -> Void)?
    private var changeHandler: (() -> Void)?

    func requestFullAccess(completion: @escaping (Result<Bool, Error>) -> Void) {
        requestCount += 1
        accessCompletion = completion
        if completesRequestAutomatically {
            completeAccessRequest(requestResult)
        }
    }

    func completeAccessRequest(_ result: Result<Bool, Error>) {
        if case .success(true) = result { accessState = .authorized }
        accessCompletion?(result)
        accessCompletion = nil
    }

    func events(from startDate: Date, through endDate: Date) throws -> [MeetingItem] {
        fetchCount += 1
        lastStartDate = startDate
        lastEndDate = endDate
        return try eventsResult.get()
    }

    func observeChanges(_ handler: @escaping () -> Void) {
        changeHandler = handler
    }

    func sendCalendarChange() {
        changeHandler?()
    }
}
