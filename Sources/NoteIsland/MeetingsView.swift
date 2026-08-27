import AppKit
import SwiftUI

@MainActor
protocol MeetingActionProviding: AnyObject {
    @discardableResult func copy(_ text: String) -> Bool
    @discardableResult func open(_ url: URL) -> Bool
}

@MainActor
final class SystemMeetingActions: MeetingActionProviding {
    private let pasteboard: NSPasteboard
    private let openURL: (URL) -> Bool

    init(
        pasteboard: NSPasteboard = .general,
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.pasteboard = pasteboard
        self.openURL = openURL
    }

    func copy(_ text: String) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    func open(_ url: URL) -> Bool {
        openURL(url)
    }
}

enum MeetingMenuAction: String, CaseIterable, Identifiable {
    case toggleDetails
    case openLink
    case copyTitle
    case copyLink
    case copyLocation
    case copyDetails

    var id: String { rawValue }

    static func available(for meeting: MeetingItem) -> [MeetingMenuAction] {
        var result: [MeetingMenuAction] = meeting.hasExtendedDetails ? [.toggleDetails] : []
        if meeting.url != nil { result.append(.openLink) }
        result.append(.copyTitle)
        if meeting.url != nil { result.append(.copyLink) }
        if meeting.location != nil { result.append(.copyLocation) }
        result.append(.copyDetails)
        return result
    }

    func title(expanded: Bool) -> String {
        switch self {
        case .toggleDetails: expanded ? "Свернуть" : "Подробнее"
        case .openLink: "Открыть ссылку"
        case .copyTitle: "Скопировать название"
        case .copyLink: "Скопировать ссылку"
        case .copyLocation: "Скопировать место"
        case .copyDetails: "Скопировать сведения"
        }
    }

    var symbol: String {
        switch self {
        case .toggleDetails: "info.circle"
        case .openLink: "arrow.up.right.square"
        case .copyTitle: "textformat"
        case .copyLink: "link"
        case .copyLocation: "location"
        case .copyDetails: "doc.on.doc"
        }
    }
}

enum MeetingActionContent {
    static func details(for meeting: MeetingItem) -> String {
        var lines = [meeting.title, timeTitle(for: meeting), "Календарь: \(meeting.calendarTitle)"]
        if let location = meeting.location { lines.append("Место: \(location)") }
        if let organizer = meeting.organizer { lines.append("Организатор: \(participantTitle(organizer))") }
        if !meeting.participants.isEmpty {
            lines.append("Участники: \(meeting.participants.map(participantTitle).joined(separator: ", "))")
        }
        if let url = meeting.url { lines.append("Ссылка: \(url.absoluteString)") }
        if let notes = meeting.notes { lines.append("Заметки: \(notes)") }
        return lines.joined(separator: "\n")
    }

    static func timeTitle(for meeting: MeetingItem) -> String {
        if meeting.isAllDay { return "Весь день" }
        return "\(meeting.startDate.formatted(date: .omitted, time: .shortened))–\(meeting.endDate.formatted(date: .omitted, time: .shortened))"
    }

    static func participantTitle(_ participant: MeetingParticipant) -> String {
        guard let email = participant.email, email != participant.name else { return participant.name }
        return "\(participant.name) <\(email)>"
    }
}

struct MeetingsView: View {
    @ObservedObject var meetings: MeetingsStore
    @State private var expandedMeetingIDs: Set<String>
    private let actions: any MeetingActionProviding

    init(
        meetings: MeetingsStore,
        actions: any MeetingActionProviding = SystemMeetingActions(),
        initiallyExpandedMeetingIDs: Set<String> = []
    ) {
        self.meetings = meetings
        self.actions = actions
        _expandedMeetingIDs = State(initialValue: initiallyExpandedMeetingIDs)
    }

    var body: some View {
        VStack(spacing: 0) {
            meetingsHeader
            Divider().overlay(Color.white.opacity(0.08))
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            meetings.activate()
        }
        .onDisappear { meetings.deactivate() }
        .foregroundStyle(.white)
    }

    private var meetingsHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Сегодня")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(IslandTheme.secondary)
            }
            Spacer()
            if meetings.state == .ready {
                Text(meetingCountTitle)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(IslandTheme.secondary)
            }
            Button {
                if meetings.notificationState == .denied {
                    meetings.refreshNotificationAuthorization(
                        onStillDenied: openNotificationPrivacySettings
                    )
                } else {
                    meetings.toggleNotifications()
                }
            } label: {
                if meetings.notificationState == .enabling {
                    ProgressView().controlSize(.small)
                        .frame(width: 26, height: 26)
                } else {
                    Image(systemName: MeetingNotificationControl.symbolName(
                        enabled: meetings.notificationsEnabled
                    ))
                    .frame(width: 26, height: 26)
                }
            }
            .buttonStyle(IslandIconButtonStyle())
            .foregroundStyle(notificationControlColor)
            .accessibilityLabel(notificationControlLabel)
            .help(notificationControlHelp)
            Button {
                meetings.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(IslandIconButtonStyle())
            .disabled(meetings.state == .loading || meetings.state == .requestingAccess)
            .accessibilityLabel("Обновить встречи")
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
    }

    private var notificationControlColor: Color {
        switch meetings.notificationState {
        case .enabled: NoteColor.mint.color
        case .denied, .failed: NoteColor.peach.color
        default: IslandTheme.secondary
        }
    }

    private var notificationControlLabel: String {
        if meetings.notificationsEnabled { return "Выключить уведомления о встречах" }
        if meetings.notificationState == .denied { return "Открыть настройки уведомлений" }
        return "Включить уведомления о встречах"
    }

    private var notificationControlHelp: String {
        switch meetings.notificationState {
        case .enabled: "Уведомления за 10 минут до встречи включены"
        case .enabling: "Включаем уведомления…"
        case .denied: "Уведомления запрещены в настройках macOS"
        case .failed(let message): message
        case .disabled: "Уведомления о встречах выключены"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch meetings.state {
        case .idle, .requestingAccess:
            permissionState
        case .loading:
            statusState(icon: nil, title: "Обновляем календарь…", message: nil, loading: true)
        case .ready where meetings.meetings.isEmpty:
            statusState(
                icon: "checkmark.circle.fill",
                title: "Сегодня свободно",
                message: "В Apple Calendar нет событий на сегодня."
            )
        case .ready:
            meetingList
        case .denied:
            accessDeniedState
        case .restricted:
            statusState(
                icon: "lock.fill",
                title: "Календарь недоступен",
                message: "Доступ ограничен настройками этого Mac."
            )
        case .failed(let message):
            statusState(
                icon: "exclamationmark.triangle.fill",
                title: "Не удалось загрузить встречи",
                message: message,
                actionTitle: "Повторить",
                action: meetings.retry
            )
        }
    }

    @ViewBuilder
    private var permissionState: some View {
        if meetings.state == .requestingAccess {
            statusState(
                icon: "calendar.badge.clock",
                title: "Доступ к Apple Calendar",
                message: "Для чтения встреч EventKit требует Full Access. Note Island только показывает события и никогда их не изменяет.",
                loading: true
            )
        } else {
            statusState(
                icon: "calendar.badge.clock",
                title: "Доступ к Apple Calendar",
                message: "Для чтения встреч EventKit требует Full Access. Note Island только показывает события и никогда их не изменяет.",
                actionTitle: "Разрешить",
                action: { meetings.requestAuthorization() }
            )
        }
    }

    private var accessDeniedState: some View {
        statusState(
            icon: "calendar.badge.exclamationmark",
            title: "Нет доступа к календарю",
            message: "Разрешите доступ для Note Island в системных настройках.",
            actionTitle: "Открыть настройки",
            action: openCalendarPrivacySettings
        )
    }

    private var meetingList: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(meetings.meetings) { meeting in
                        MeetingRow(
                            meeting: meeting,
                            expanded: expandedMeetingIDs.contains(meeting.id),
                            actions: actions,
                            now: context.date,
                            toggleAction: { toggleDetails(for: meeting.id) }
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    private func statusState(
        icon: String?,
        title: String,
        message: String?,
        loading: Bool = false,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 10) {
            if loading {
                ProgressView().controlSize(.small)
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(NoteColor.mint.color)
            }
            Text(title)
                .font(.system(size: 14, weight: .bold, design: .rounded))
            if let message {
                Text(message)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(IslandTheme.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.black.opacity(0.82))
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(NoteColor.mint.color, in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var meetingCountTitle: String {
        let count = meetings.meetings.count
        return "\(count) \(count == 1 ? "событие" : "событий")"
    }

    private func openCalendarPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openNotificationPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    private func toggleDetails(for id: String) {
        if expandedMeetingIDs.contains(id) {
            expandedMeetingIDs.remove(id)
        } else {
            expandedMeetingIDs.insert(id)
        }
    }
}

struct MeetingRow: View {
    let meeting: MeetingItem
    let expanded: Bool
    let actions: any MeetingActionProviding
    let now: Date
    let toggleAction: () -> Void

    init(
        meeting: MeetingItem,
        expanded: Bool,
        actions: any MeetingActionProviding,
        now: Date = Date(),
        toggleAction: @escaping () -> Void
    ) {
        self.meeting = meeting
        self.expanded = expanded
        self.actions = actions
        self.now = now
        self.toggleAction = toggleAction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button(action: { if meeting.hasExtendedDetails { toggleAction() } }) {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(meeting.calendarColor.swiftUIColor)
                            .frame(width: 4)
                            .shadow(color: meeting.calendarColor.swiftUIColor.opacity(0.55), radius: 4)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(meeting.title)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .lineLimit(1)
                            HStack(spacing: 7) {
                                Text(MeetingActionContent.timeTitle(for: meeting))
                                if let location = meeting.location {
                                    Text("•")
                                    Label(location, systemImage: "location.fill")
                                        .lineLimit(1)
                                }
                            }
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(IslandTheme.secondary)
                        }
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu { contextActions }

                Text(meeting.calendarTitle)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(meeting.calendarColor.swiftUIColor)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(meeting.calendarColor.swiftUIColor.opacity(0.1), in: Capsule())

                if temporalState == .current {
                    Text("Сейчас")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(.black.opacity(0.82))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(meeting.calendarColor.swiftUIColor, in: Capsule())
                        .accessibilityLabel("Событие идет сейчас")
                }

                if meeting.hasExtendedDetails {
                    Button(action: toggleAction) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(IslandTheme.secondary)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                            .frame(width: 24, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expanded ? "Свернуть событие" : "Раскрыть событие")
                }

                Menu { contextActions } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 32)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .accessibilityLabel("Действия с событием")
            }
            .frame(minHeight: 54)

            if expanded {
                Divider()
                    .overlay(Color.white.opacity(0.08))
                    .padding(.leading, 16)
                meetingDetails
                    .padding(.top, 11)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(
                    temporalState == .current
                        ? meeting.calendarColor.swiftUIColor.opacity(0.14)
                        : IslandTheme.surface
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(
                            temporalState == .current
                                ? meeting.calendarColor.swiftUIColor.opacity(0.9)
                                : Color.clear,
                            lineWidth: 1.5
                        )
                }
        }
        .shadow(
            color: temporalState == .current
                ? meeting.calendarColor.swiftUIColor.opacity(0.18)
                : .clear,
            radius: 8
        )
        .opacity(temporalState == .past ? 0.48 : 1)
        .saturation(temporalState == .past ? 0.45 : 1)
        .contextMenu { contextActions }
        .animation(.easeOut(duration: 0.16), value: expanded)
        .animation(.easeOut(duration: 0.2), value: temporalState)
    }

    @ViewBuilder
    private var meetingDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let location = meeting.location {
                detailLine(symbol: "location.fill", title: "Место", value: location)
            }
            if let url = meeting.url {
                Button { _ = actions.open(url) } label: {
                    detailLine(symbol: "video.fill", title: "Ссылка", value: url.absoluteString)
                }
                .buttonStyle(.plain)
            }
            if let organizer = meeting.organizer {
                participantLine(organizer, title: "Организатор")
            }
            if !meeting.participants.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Участники · \(meeting.participants.count)", systemImage: "person.2.fill")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(IslandTheme.secondary)
                    ForEach(meeting.participants) { participant in
                        participantLine(participant, title: nil)
                    }
                }
            }
            if let notes = visibleNotes {
                detailLine(symbol: "text.alignleft", title: "Заметки", value: notes)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.bottom, 7)
    }

    private func detailLine(symbol: String, title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(meeting.calendarColor.swiftUIColor)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(IslandTheme.secondary)
                Text(value)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func participantLine(_ participant: MeetingParticipant, title: String?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: participantStatusSymbol(participant.status))
                .foregroundStyle(participantStatusColor(participant.status))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                if let title {
                    Text(title)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(IslandTheme.secondary)
                }
                Text(MeetingActionContent.participantTitle(participant))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if let role = participantRoleTitle(participant.role) {
                Text(role)
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(IslandTheme.secondary)
            }
        }
    }

    @ViewBuilder
    private var contextActions: some View {
        ForEach(MeetingMenuAction.available(for: meeting)) { action in
            Button { perform(action) } label: {
                Label(action.title(expanded: expanded), systemImage: action.symbol)
            }
            if action == .toggleDetails || action == .openLink {
                Divider()
            }
        }
    }

    func perform(_ action: MeetingMenuAction) {
        switch action {
        case .toggleDetails:
            toggleAction()
        case .openLink:
            if let url = meeting.url { _ = actions.open(url) }
        case .copyTitle:
            _ = actions.copy(meeting.title)
        case .copyLink:
            if let url = meeting.url { _ = actions.copy(url.absoluteString) }
        case .copyLocation:
            if let location = meeting.location { _ = actions.copy(location) }
        case .copyDetails:
            _ = actions.copy(MeetingActionContent.details(for: meeting))
        }
    }

    private func participantStatusSymbol(_ status: MeetingParticipantStatus) -> String {
        switch status {
        case .accepted: "checkmark.circle.fill"
        case .declined: "xmark.circle.fill"
        case .tentative: "questionmark.circle.fill"
        case .pending: "clock.fill"
        case .unknown: "person.crop.circle"
        }
    }

    private func participantStatusColor(_ status: MeetingParticipantStatus) -> Color {
        switch status {
        case .accepted: NoteColor.mint.color
        case .declined: .red
        case .tentative: NoteColor.peach.color
        case .pending, .unknown: IslandTheme.secondary
        }
    }

    private func participantRoleTitle(_ role: MeetingParticipantRole) -> String? {
        switch role {
        case .organizer: "организатор"
        case .required: nil
        case .optional: "необязательно"
        case .informational: "информация"
        case .unknown: nil
        }
    }

    private var visibleNotes: String? {
        guard let notes = meeting.notes else { return nil }
        return notes == meeting.url?.absoluteString ? nil : notes
    }

    private var temporalState: MeetingTemporalState {
        MeetingTemporalState.resolve(meeting, now: now)
    }
}
