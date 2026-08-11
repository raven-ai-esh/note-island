import AppKit
import Combine
@preconcurrency import EventKit
import Foundation
import SwiftUI

enum CalendarAccessState: Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted
    case writeOnly
}

struct MeetingColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    static let fallback = MeetingColor(red: 0.42, green: 0.78, blue: 1)

    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue)
    }
}

struct MeetingItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let location: String?
    let calendarTitle: String
    let calendarColor: MeetingColor
    let url: URL?
    let notes: String?
    let organizer: MeetingParticipant?
    let participants: [MeetingParticipant]

    init(
        id: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        location: String?,
        calendarTitle: String,
        calendarColor: MeetingColor,
        url: URL? = nil,
        notes: String? = nil,
        organizer: MeetingParticipant? = nil,
        participants: [MeetingParticipant] = []
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.location = location
        self.calendarTitle = calendarTitle
        self.calendarColor = calendarColor
        self.url = url
        self.notes = notes
        self.organizer = organizer
        self.participants = participants
    }

    var hasExtendedDetails: Bool {
        location != nil || url != nil || notes != nil || organizer != nil || !participants.isEmpty
    }
}

enum MeetingTemporalState: Equatable, Sendable {
    case past
    case current
    case upcoming

    static func resolve(startDate: Date, endDate: Date, now: Date) -> MeetingTemporalState {
        if endDate <= now { return .past }
        if startDate <= now { return .current }
        return .upcoming
    }

    static func resolve(_ meeting: MeetingItem, now: Date) -> MeetingTemporalState {
        resolve(startDate: meeting.startDate, endDate: meeting.endDate, now: now)
    }
}

enum MeetingParticipantStatus: String, Equatable, Sendable {
    case accepted
    case declined
    case tentative
    case pending
    case unknown
}

enum MeetingParticipantRole: String, Equatable, Sendable {
    case organizer
    case required
    case optional
    case informational
    case unknown
}

struct MeetingParticipant: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let email: String?
    let status: MeetingParticipantStatus
    let role: MeetingParticipantRole
}

enum MeetingLinkExtractor {
    static func firstWebURL(explicitURL: URL?, notes: String?, location: String?) -> URL? {
        let embeddedURLs = [notes, location]
            .compactMap { $0 }
            .flatMap(webURLs(in:))
        let candidates = [explicitURL].compactMap { $0 } + embeddedURLs
        if let conferenceURL = candidates.first(where: isConferenceURL) { return conferenceURL }
        if let explicitURL, isWebURL(explicitURL) { return explicitURL }
        return embeddedURLs.first
    }

    private static func webURLs(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, range: range)
            .compactMap(\.url)
            .filter(isWebURL)
    }

    private static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }

    private static func isConferenceURL(_ url: URL) -> Bool {
        guard isWebURL(url), let host = url.host?.lowercased() else { return false }
        let conferenceHosts = [
            "meet.google.com", "zoom.us", "teams.microsoft.com", "meet.jit.si",
            "whereby.com", "around.co", "telemost.yandex.ru", "trueconf.com"
        ]
        return conferenceHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
            || host.contains("webex.com")
    }
}

enum MeetingsViewState: Equatable {
    case idle
    case requestingAccess
    case loading
    case ready
    case denied
    case restricted
    case failed(String)
}

@MainActor
protocol CalendarEventProviding: AnyObject {
    var accessState: CalendarAccessState { get }
    func requestFullAccess(completion: @escaping (Result<Bool, Error>) -> Void)
    func events(from startDate: Date, through endDate: Date) throws -> [MeetingItem]
    func observeChanges(_ handler: @escaping () -> Void)
}

@MainActor
final class EventKitCalendarProvider: NSObject, CalendarEventProviding {
    private let eventStore: EKEventStore
    private var changeHandler: (() -> Void)?

    override init() {
        eventStore = EKEventStore()
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(eventStoreDidChange),
            name: .EKEventStoreChanged,
            object: eventStore
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var accessState: CalendarAccessState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized:
            .authorized
        case .denied:
            .denied
        case .restricted:
            .restricted
        case .writeOnly:
            .writeOnly
        case .notDetermined:
            .notDetermined
        @unknown default:
            .restricted
        }
    }

    func requestFullAccess(completion: @escaping (Result<Bool, Error>) -> Void) {
        Task { @MainActor in
            do {
                completion(.success(try await eventStore.requestFullAccessToEvents()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func events(from startDate: Date, through endDate: Date) throws -> [MeetingItem] {
        let predicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: nil
        )
        return eventStore.events(matching: predicate)
            .map(Self.meetingItem)
            .sorted {
                if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
                if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
    }

    func observeChanges(_ handler: @escaping () -> Void) {
        changeHandler = handler
    }

    @objc private func eventStoreDidChange() {
        changeHandler?()
    }

    static func meetingItem(from event: EKEvent) -> MeetingItem {
        let color: MeetingColor
        if let converted = NSColor(cgColor: event.calendar.cgColor)?.usingColorSpace(.deviceRGB) {
            color = MeetingColor(
                red: Double(converted.redComponent),
                green: Double(converted.greenComponent),
                blue: Double(converted.blueComponent)
            )
        } else {
            color = .fallback
        }
        let occurrenceID = "\(event.calendarItemIdentifier)-\(event.startDate.timeIntervalSinceReferenceDate)"
        let notes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let organizer = event.organizer.map { participantItem(from: $0, index: -1, role: .organizer) }
        let participants: [MeetingParticipant] = (event.attendees ?? []).enumerated().compactMap {
            index, participant -> MeetingParticipant? in
            let mapped = participantItem(from: participant, index: index, role: role(from: participant.participantRole))
            guard mapped.id != organizer?.id else { return nil }
            return mapped
        }
        return MeetingItem(
            id: occurrenceID,
            title: event.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Без названия",
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay,
            location: location,
            calendarTitle: event.calendar.title,
            calendarColor: color,
            url: MeetingLinkExtractor.firstWebURL(explicitURL: event.url, notes: notes, location: location),
            notes: notes,
            organizer: organizer,
            participants: participants
        )
    }

    private static func participantItem(
        from participant: EKParticipant,
        index: Int,
        role: MeetingParticipantRole
    ) -> MeetingParticipant {
        let email = participant.url.scheme?.lowercased() == "mailto"
            ? participant.url.path.removingPercentEncoding
            : nil
        let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? email?.nonEmpty
            ?? "Участник"
        return MeetingParticipant(
            id: participant.url.absoluteString.nonEmpty ?? "participant-\(index)-\(name)",
            name: name,
            email: email,
            status: status(from: participant.participantStatus),
            role: role
        )
    }

    private static func status(from status: EKParticipantStatus) -> MeetingParticipantStatus {
        switch status {
        case .accepted, .completed: .accepted
        case .declined: .declined
        case .tentative: .tentative
        case .pending, .delegated, .inProcess: .pending
        case .unknown: .unknown
        @unknown default: .unknown
        }
    }

    private static func role(from role: EKParticipantRole) -> MeetingParticipantRole {
        switch role {
        case .chair: .organizer
        case .required: .required
        case .optional: .optional
        case .nonParticipant: .informational
        case .unknown: .unknown
        @unknown default: .unknown
        }
    }
}

@MainActor
final class MeetingsStore: ObservableObject {
    @Published private(set) var state: MeetingsViewState = .idle
    @Published private(set) var meetings: [MeetingItem] = []
    @Published private(set) var lastUpdated: Date?

    private let provider: CalendarEventProviding
    private let calendar: Calendar
    private var isActive = false
    private var isLoading = false

    init(provider: CalendarEventProviding = EventKitCalendarProvider(), calendar: Calendar = .autoupdatingCurrent) {
        self.provider = provider
        self.calendar = calendar
        provider.observeChanges { [weak self] in
            guard let self, self.isActive else { return }
            self.refresh()
        }
    }

    func activate() {
        isActive = true
        load(requestAccessIfNeeded: false)
    }

    func deactivate() {
        isActive = false
    }

    func retry() {
        load(requestAccessIfNeeded: true)
    }

    func requestAuthorization() {
        guard provider.accessState == .notDetermined else {
            load(requestAccessIfNeeded: false)
            return
        }
        requestAccess()
    }

    func refresh() {
        load(requestAccessIfNeeded: false)
    }

    private func load(requestAccessIfNeeded: Bool) {
        guard !isLoading else { return }
        switch provider.accessState {
        case .authorized:
            fetchToday()
        case .notDetermined where requestAccessIfNeeded:
            requestAccess()
        case .notDetermined:
            state = .idle
        case .denied, .writeOnly:
            meetings = []
            state = .denied
        case .restricted:
            meetings = []
            state = .restricted
        }
    }

    private func requestAccess() {
        isLoading = true
        state = .requestingAccess
        provider.requestFullAccess { [weak self] result in
            guard let self else { return }
            self.isLoading = false
            switch result {
            case .success(true):
                self.load(requestAccessIfNeeded: false)
            case .success(false):
                self.meetings = []
                self.state = .denied
            case .failure(let error):
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    private func fetchToday(now: Date = Date()) {
        guard !isLoading else { return }
        isLoading = true
        state = .loading
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            isLoading = false
            state = .failed("Не удалось определить границы сегодняшнего дня")
            return
        }
        do {
            meetings = try provider.events(from: start, through: end)
            lastUpdated = now
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
        isLoading = false
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
