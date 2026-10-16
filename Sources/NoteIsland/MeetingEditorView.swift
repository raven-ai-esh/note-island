import SwiftUI

struct MeetingEditorView: View {
    @ObservedObject var meetings: MeetingsStore
    @State private var draft: MeetingDraft
    @State private var calendars: [MeetingCalendar] = []
    @State private var loadingError: String?
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    init(draft: MeetingDraft, meetings: MeetingsStore) {
        _draft = State(initialValue: draft)
        self.meetings = meetings
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(draft.original == nil ? "Новая встреча" : "Изменить встречу", systemImage: "calendar")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Spacer()
            }
            .padding(20)
            Divider().overlay(Color.white.opacity(0.08))

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    field("Название") {
                        TextField("Название встречи", text: $draft.title)
                            .accessibilityLabel("Название встречи")
                    }
                    field("Календарь") {
                        Picker("Календарь", selection: $draft.calendarID) {
                            ForEach(calendars) { calendar in
                                Text(calendar.title).tag(calendar.id)
                            }
                        }
                        .labelsHidden()
                        .accessibilityLabel("Календарь встречи")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Toggle("Весь день", isOn: Binding(
                        get: { draft.isAllDay },
                        set: { draft.setAllDay($0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    dateFields
                    field("Место") {
                        TextField("Место или видеоконференция", text: $draft.location)
                            .accessibilityLabel("Место встречи")
                    }
                    field("Ссылка") {
                        TextField("https://…", text: $draft.urlText)
                            .accessibilityLabel("Ссылка встречи")
                    }
                    field("Описание") {
                        TextEditor(text: $draft.notes)
                            .font(.system(size: 12))
                            .scrollContentBackground(.hidden)
                            .frame(height: 66)
                            .accessibilityLabel("Описание встречи")
                    }
                    if draft.original?.isRecurring == true {
                        Label("Изменится только выбранное событие повторения.", systemImage: "repeat")
                            .font(.system(size: 11))
                            .foregroundStyle(IslandTheme.secondary)
                    }
                }
                .textFieldStyle(.plain)
                .padding(20)
            }
            if let error = loadingError ?? meetings.mutationError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(NoteColor.peach.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .accessibilityLabel("Ошибка сохранения: \(error)")
            }
            Divider().overlay(Color.white.opacity(0.08))
            HStack {
                Button("Отмена") {
                    meetings.dismissMutationError()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)
                Spacer()
                if isSaving { ProgressView().controlSize(.small) }
                Button(draft.original == nil ? "Создать" : "Сохранить") {
                    guard !isSaving else { return }
                    isSaving = true
                    Task { @MainActor in
                        await Task.yield()
                        if meetings.saveMeeting(draft) { dismiss() }
                        isSaving = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(NoteColor.mint.color)
                .foregroundStyle(.black.opacity(0.85))
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || calendars.isEmpty || loadingError != nil)
            }
            .padding(16)
        }
        .frame(width: 460, height: 550)
        .background(IslandTheme.background)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .onAppear {
            do { calendars = try meetings.editableCalendars() }
            catch { loadingError = error.localizedDescription }
        }
    }

    private var dateFields: some View {
        VStack(spacing: 10) {
            DatePicker("Начало", selection: $draft.startDate,
                       displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                .accessibilityLabel("Начало встречи")
            if draft.isAllDay {
                DatePicker("Последний день", selection: Binding(
                    get: { Calendar.current.date(byAdding: .day, value: -1, to: draft.endDate) ?? draft.startDate },
                    set: { draft.endDate = Calendar.current.date(byAdding: .day, value: 1, to: $0) ?? $0 }
                ), displayedComponents: [.date])
                .accessibilityLabel("Последний день встречи")
            } else {
                DatePicker("Окончание", selection: $draft.endDate, displayedComponents: [.date, .hourAndMinute])
                    .accessibilityLabel("Окончание встречи")
            }
        }
        .datePickerStyle(.field)
        .font(.system(size: 12))
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(IslandTheme.secondary)
            content()
                .font(.system(size: 12))
                .padding(9)
                .background(IslandTheme.surface, in: RoundedRectangle(cornerRadius: 9))
        }
    }
}
