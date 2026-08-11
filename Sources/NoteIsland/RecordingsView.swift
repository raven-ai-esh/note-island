import AVFoundation
import AVKit
import SwiftUI

struct RecordingsView: View {
    @ObservedObject var recordings: RecordingsStore
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 0) {
                recordingsList
                    .frame(width: 190)
                Divider().overlay(Color.white.opacity(0.08))
                playerArea
            }
            recordingControls
                .padding(12)
        }
        .onAppear {
            recordings.reload()
            loadSelectedPlayer()
        }
        .onChange(of: recordings.selectedID) { _, _ in loadSelectedPlayer() }
        .onChange(of: recordings.playbackRequestID) { _, _ in
            loadSelectedPlayer()
            player?.play()
        }
        .onDisappear { player?.pause() }
    }

    private var recordingControls: some View {
        HStack(spacing: 7) {
            switch recordings.state {
            case .recording:
                Button {
                    recordings.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(Color.red.opacity(0.88), in: Circle())
                .accessibilityLabel("Остановить запись")
                .help("Остановить запись · \(formattedElapsed)")
            case .stopping(let kind):
                HStack(spacing: 8) {
                    SavingProgressIndicator(size: 18, controlSize: .small)
                    Text(kind.savingTitle)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .frame(height: 34)
                .background(IslandTheme.surface, in: Capsule())
                .accessibilityElement(children: .combine)
                .accessibilityLabel(kind.savingAccessibilityLabel)
            case .starting:
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 34, height: 34)
                    .background(IslandTheme.surface, in: Circle())
            default:
                captureButton(kind: .audio)
                captureButton(kind: .screen)
            }
        }
    }

    private func captureButton(kind: RecordingKind) -> some View {
        Button {
            player?.pause()
            recordings.clearError()
            recordings.start(kind)
        } label: {
            Image(systemName: kind.symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(IslandTheme.surface, in: Circle())
        .disabled(isBusy)
        .accessibilityLabel("Начать запись: \(kind.title)")
        .help(kind.title)
    }

    private var recordingsList: some View {
        VStack(spacing: 0) {
            if recordings.recordings.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 24))
                        .foregroundStyle(IslandTheme.secondary)
                    Text("Записей пока нет")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(IslandTheme.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(recordings.recordings) { item in
                            RecordingRow(
                                item: item,
                                selected: recordings.selectedID == item.id,
                                selectAction: { recordings.selectedID = item.id },
                                playAction: { recordings.play(item) },
                                revealAction: { recordings.reveal(item) },
                                copyAction: { recordings.copy(item) },
                                trashAction: {
                                    player?.pause()
                                    recordings.trash(item)
                                }
                            )
                        }
                    }
                    .padding(9)
                }
            }
        }
    }

    @ViewBuilder
    private var playerArea: some View {
        if case .stopping(let kind) = recordings.state {
            VStack(spacing: 11) {
                SavingProgressIndicator(size: 28, controlSize: .regular)
                Text(kind.savingTitle)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                Text("Финализируем файл — это может занять немного времени")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(IslandTheme.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(kind.savingAccessibilityLabel)
        } else if case .failed(let message) = recordings.state {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(NoteColor.peach.color)
                Text(message)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(IslandTheme.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                Button("Закрыть") { recordings.clearError() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(IslandTheme.surface, in: Capsule())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let selected = recordings.selectedRecording {
            VStack(spacing: 9) {
                NativePlayerView(player: player)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selected.kind.title)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                        Text(selected.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(IslandTheme.secondary)
                    }
                    Spacer()
                    Button {
                        recordings.reveal(selected)
                    } label: {
                        Label("В Finder", systemImage: "folder")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 27)
                    .background(IslandTheme.surface, in: Capsule())
                }
            }
            .padding(12)
        } else {
            VStack(spacing: 9) {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 28))
                    .foregroundStyle(IslandTheme.secondary)
                Text("Выберите запись для воспроизведения")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(IslandTheme.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var isBusy: Bool {
        switch recordings.state {
        case .starting, .recording, .stopping: true
        default: false
        }
    }

    private var formattedElapsed: String {
        String(format: "%02d:%02d", recordings.elapsedSeconds / 60, recordings.elapsedSeconds % 60)
    }

    private func loadSelectedPlayer() {
        player?.pause()
        if let url = recordings.selectedRecording?.url {
            player = AVPlayer(url: url)
        } else {
            player = nil
        }
    }
}

private struct SavingProgressIndicator: View {
    let size: CGFloat
    let controlSize: ControlSize

    var body: some View {
        ZStack {
            Circle()
                .stroke(NoteColor.mint.color, lineWidth: 1.5)
            ProgressView()
                .controlSize(controlSize)
                .tint(NoteColor.mint.color)
                .scaleEffect(size <= 18 ? 0.65 : 0.9)
        }
        .frame(width: size, height: size)
    }
}

private extension RecordingKind {
    var savingTitle: String {
        switch self {
        case .audio: "Сохраняем аудио…"
        case .screen: "Сохраняем запись экрана…"
        }
    }

    var savingAccessibilityLabel: String {
        switch self {
        case .audio: "Сохраняем аудиозапись"
        case .screen: "Сохраняем запись экрана со звуком"
        }
    }
}

private struct NativePlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

private struct RecordingRow: View {
    let item: RecordingItem
    let selected: Bool
    let selectAction: () -> Void
    let playAction: () -> Void
    let revealAction: () -> Void
    let copyAction: () -> Void
    let trashAction: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: selectAction) {
                HStack(spacing: 9) {
                    Image(systemName: item.kind.symbol)
                        .foregroundStyle(item.kind == .audio ? NoteColor.mint.color : NoteColor.sky.color)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.createdAt.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                        Text(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(IslandTheme.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(item.kind.title), \(item.createdAt.formatted())")

            Menu {
                recordingActions
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 32)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel("Действия с записью")
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(height: 48)
        .background(
            selected ? Color.white.opacity(0.1) : IslandTheme.surface.opacity(0.72),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .contextMenu {
            recordingActions
        }
    }

    @ViewBuilder
    private var recordingActions: some View {
        Button(action: playAction) {
            Label("Воспроизвести", systemImage: "play.fill")
        }
        Button(action: revealAction) {
            Label("Показать в Finder", systemImage: "folder")
        }
        Button(action: copyAction) {
            Label("Скопировать файл", systemImage: "doc.on.doc")
        }
        Divider()
        Button(role: .destructive, action: trashAction) {
            Label("Удалить", systemImage: "trash")
        }
    }
}
