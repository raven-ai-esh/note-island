import AppKit
import AVFoundation
import Combine
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

enum RecordingKind: String, CaseIterable, Sendable {
    case audio
    case screen

    var title: String {
        switch self {
        case .audio: "Звук"
        case .screen: "Экран + звук"
        }
    }

    var symbol: String {
        switch self {
        case .audio: "waveform"
        case .screen: "rectangle.inset.filled.and.person.filled"
        }
    }

    var fileExtension: String {
        switch self {
        case .audio: "m4a"
        case .screen: "mov"
        }
    }
}

struct RecordingItem: Identifiable, Equatable, Sendable {
    var id: String { url.standardizedFileURL.path }
    let url: URL
    let kind: RecordingKind
    let createdAt: Date
    let fileSize: Int64
}

enum RecorderViewState: Equatable {
    case idle
    case starting(RecordingKind)
    case recording(RecordingKind)
    case stopping(RecordingKind)
    case failed(String)
}

@MainActor
protocol RecordingCapturing: AnyObject {
    var onFailure: (@MainActor @Sendable (Error) -> Void)? { get set }
    func start(kind: RecordingKind, outputURL: URL, completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void)
    func stop(completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void)
}

enum MediaCaptureError: LocalizedError {
    case microphoneDenied
    case screenDenied
    case unavailable
    case failedToStart
    case noActiveRecording
    case unexpectedStop

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Нет доступа к микрофону. Разрешите его в системных настройках."
        case .screenDenied:
            "Нет доступа к записи экрана и системного звука. Разрешите его в системных настройках и перезапустите Note Island."
        case .unavailable:
            "Запись системного звука и экрана доступна на macOS 15 и новее."
        case .failedToStart:
            "Не удалось начать запись."
        case .noActiveRecording:
            "Активная запись не найдена."
        case .unexpectedStop:
            "Запись неожиданно остановилась."
        }
    }
}

@MainActor
final class SystemRecordingController: RecordingCapturing {
    var onFailure: (@MainActor @Sendable (Error) -> Void)?
    private var captureSession: AnyObject?
    private var activeKind: RecordingKind?

    func start(kind: RecordingKind, outputURL: URL, completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void) {
        guard activeKind == nil else {
            completion(.failure(MediaCaptureError.failedToStart))
            return
        }
        Task { @MainActor in
            await startScreenCaptureRecording(kind: kind, outputURL: outputURL, completion: completion)
        }
    }

    func stop(completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void) {
        guard activeKind != nil else {
            completion(.failure(MediaCaptureError.noActiveRecording))
            return
        }
        if #available(macOS 15.0, *), let session = captureSession as? ScreenCaptureRecordingSession {
            session.stop { [weak self] result in
                self?.captureSession = nil
                self?.activeKind = nil
                completion(result)
            }
        } else {
            captureSession = nil
            self.activeKind = nil
            completion(.failure(MediaCaptureError.noActiveRecording))
        }
    }

    private func startScreenCaptureRecording(
        kind: RecordingKind,
        outputURL: URL,
        completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
    ) async {
        guard #available(macOS 15.0, *) else {
            completion(.failure(MediaCaptureError.unavailable))
            return
        }
        guard await microphoneAccessGranted() else {
            completion(.failure(MediaCaptureError.microphoneDenied))
            return
        }
        let session = ScreenCaptureRecordingSession(kind: kind)
        captureSession = session
        session.onRuntimeFailure = { [weak self] error in
            self?.captureSession = nil
            self?.activeKind = nil
            self?.onFailure?(error)
        }
        session.start(outputURL: outputURL, includeMicrophone: true) { [weak self] result in
            switch result {
            case .success:
                self?.activeKind = kind
            case .failure:
                self?.captureSession = nil
            }
            completion(result)
        }
    }

    private func microphoneAccessGranted() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            true
        case .notDetermined:
            await AVCaptureDevice.requestAccess(for: .audio)
        default:
            false
        }
    }

    static func mapCaptureStartError(_ error: Error) -> Error {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain,
           nsError.code == SCStreamError.Code.userDeclined.rawValue {
            return MediaCaptureError.screenDenied
        }
        return error
    }
}

@MainActor
protocol AudioExporting: AnyObject {
    func exportAudio(
        from movieURL: URL,
        to outputURL: URL,
        completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
    )
}

@MainActor
final class SystemAudioExporter: AudioExporting {
    func exportAudio(
        from movieURL: URL,
        to outputURL: URL,
        completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
    ) {
        Task { @MainActor in
            do {
                let asset = AVURLAsset(url: movieURL)
                let sourceTracks = try await asset.loadTracks(withMediaType: .audio)
                guard !sourceTracks.isEmpty else { throw MediaCaptureError.unexpectedStop }

                let composition = AVMutableComposition()
                var parameters: [AVMutableAudioMixInputParameters] = []
                for sourceTrack in sourceTracks {
                    let timeRange = try await sourceTrack.load(.timeRange)
                    guard let track = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    ) else { throw MediaCaptureError.unexpectedStop }
                    try track.insertTimeRange(timeRange, of: sourceTrack, at: .zero)
                    let input = AVMutableAudioMixInputParameters(track: track)
                    input.setVolume(1, at: .zero)
                    parameters.append(input)
                }

                guard let exporter = AVAssetExportSession(
                    asset: composition,
                    presetName: AVAssetExportPresetAppleM4A
                ) else { throw MediaCaptureError.unexpectedStop }
                let mix = AVMutableAudioMix()
                mix.inputParameters = parameters
                exporter.audioMix = mix
                try? FileManager.default.removeItem(at: outputURL)
                exporter.outputURL = outputURL
                exporter.outputFileType = .m4a
                await exporter.export()
                if let error = exporter.error { throw error }
                guard exporter.status == .completed else { throw MediaCaptureError.unexpectedStop }
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }
}

@available(macOS 15.0, *)
private final class ScreenCaptureRecordingSession: NSObject, SCStreamOutput, SCStreamDelegate, SCRecordingOutputDelegate, @unchecked Sendable {
    var onRuntimeFailure: (@MainActor (Error) -> Void)?
    private let kind: RecordingKind
    private let audioExporter: AudioExporting
    private var startCompletion: (@MainActor (Result<Void, Error>) -> Void)?
    private var stopCompletion: (@MainActor (Result<Void, Error>) -> Void)?
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var finalOutputURL: URL?
    private var captureOutputURL: URL?
    private let sampleQueue = DispatchQueue(label: "dev.raven.note-island.screen-samples")

    @MainActor
    init(kind: RecordingKind, audioExporter: AudioExporting = SystemAudioExporter()) {
        self.kind = kind
        self.audioExporter = audioExporter
        super.init()
    }

    @MainActor
    func start(
        outputURL: URL,
        includeMicrophone: Bool,
        completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
    ) {
        startCompletion = completion
        finalOutputURL = outputURL
        captureOutputURL = kind == .audio
            ? outputURL.deletingLastPathComponent().appendingPathComponent(".audio-capture-\(UUID().uuidString).mov")
            : outputURL
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                    ?? content.displays.first else { throw MediaCaptureError.failedToStart }
                let ownApps = content.applications.filter {
                    $0.processID == ProcessInfo.processInfo.processIdentifier
                }
                let filter = SCContentFilter(
                    display: display,
                    excludingApplications: ownApps,
                    exceptingWindows: []
                )
                let configuration = SCStreamConfiguration()
                configuration.width = kind == .audio ? 2 : display.width
                configuration.height = kind == .audio ? 2 : display.height
                configuration.minimumFrameInterval = kind == .audio
                    ? CMTime(value: 1, timescale: 1)
                    : CMTime(value: 1, timescale: 30)
                configuration.queueDepth = kind == .audio ? 3 : 6
                configuration.showsCursor = kind == .screen
                configuration.capturesAudio = true
                configuration.excludesCurrentProcessAudio = true
                configuration.sampleRate = 48_000
                configuration.channelCount = 2
                configuration.captureMicrophone = includeMicrophone
                if includeMicrophone {
                    configuration.microphoneCaptureDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID
                }

                let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
                if includeMicrophone {
                    try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue)
                }
                let recordingConfiguration = SCRecordingOutputConfiguration()
                guard let captureOutputURL else { throw MediaCaptureError.failedToStart }
                recordingConfiguration.outputURL = captureOutputURL
                recordingConfiguration.outputFileType = .mov
                let recordingOutput = SCRecordingOutput(
                    configuration: recordingConfiguration,
                    delegate: self
                )
                try stream.addRecordingOutput(recordingOutput)
                self.stream = stream
                self.recordingOutput = recordingOutput
                try await stream.startCapture()
            } catch {
                cleanupTemporaryCapture()
                finishStart(.failure(SystemRecordingController.mapCaptureStartError(error)))
            }
        }
    }

    @MainActor
    func stop(completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void) {
        guard let stream else {
            completion(.failure(MediaCaptureError.noActiveRecording))
            return
        }
        stopCompletion = completion
        Task {
            do {
                try await stream.stopCapture()
            } catch {
                finishStop(.failure(error))
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        _ = stream
        _ = sampleBuffer
        _ = outputType
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.startCompletion != nil {
                self.finishStart(.failure(error))
            } else if self.stopCompletion != nil {
                self.finishStop(.failure(error))
            } else {
                self.finishRuntimeFailure(error)
            }
        }
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in self?.finishStart(.success(())) }
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.startCompletion != nil {
                self.finishStart(.failure(error))
            } else if self.stopCompletion != nil {
                self.finishStop(.failure(error))
            } else {
                self.finishRuntimeFailure(error)
            }
        }
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.stopCompletion != nil else {
                self.finishRuntimeFailure(MediaCaptureError.unexpectedStop)
                return
            }
            if self.kind == .audio,
               let captureOutputURL = self.captureOutputURL,
               let finalOutputURL = self.finalOutputURL {
                self.audioExporter.exportAudio(from: captureOutputURL, to: finalOutputURL) { [weak self] result in
                    self?.cleanupTemporaryCapture()
                    self?.finishStop(result)
                }
            } else {
                self.finishStop(.success(()))
            }
        }
    }

    @MainActor
    private func finishStart(_ result: Result<Void, Error>) {
        guard let completion = startCompletion else { return }
        startCompletion = nil
        completion(result)
    }

    @MainActor
    private func finishStop(_ result: Result<Void, Error>) {
        guard let completion = stopCompletion else { return }
        stopCompletion = nil
        stream = nil
        recordingOutput = nil
        if case .failure = result { cleanupTemporaryCapture() }
        completion(result)
    }

    @MainActor
    private func cleanupTemporaryCapture() {
        guard kind == .audio, let captureOutputURL else { return }
        try? FileManager.default.removeItem(at: captureOutputURL)
        self.captureOutputURL = nil
    }

    @MainActor
    private func finishRuntimeFailure(_ error: Error) {
        stream = nil
        recordingOutput = nil
        cleanupTemporaryCapture()
        onRuntimeFailure?(error)
    }
}

@MainActor
final class RecordingsStore: ObservableObject {
    @Published private(set) var state: RecorderViewState = .idle
    @Published private(set) var recordings: [RecordingItem] = []
    @Published var selectedID: String?
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var playbackRequestID = 0

    private let capture: RecordingCapturing
    private let directory: URL
    private let trashFile: @MainActor (URL) throws -> Void
    private let copyFile: @MainActor (URL) -> Bool
    private var currentOutputURL: URL?
    private var timer: AnyCancellable?
    private var directoryMonitor: AnyCancellable?

    init(
        capture: RecordingCapturing = SystemRecordingController(),
        directory: URL? = nil,
        trashFile: @escaping @MainActor (URL) throws -> Void = RecordingsStore.moveToTrash,
        copyFile: @escaping @MainActor (URL) -> Bool = RecordingsStore.writeFileToPasteboard
    ) {
        self.capture = capture
        self.directory = directory ?? Self.defaultDirectory
        self.trashFile = trashFile
        self.copyFile = copyFile
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        capture.onFailure = { [weak self] error in
            self?.discardCurrentOutput()
            self?.timer = nil
            self?.state = .failed(error.localizedDescription)
            self?.reload()
        }
        reload()
        startDirectoryMonitoring()
    }

    var selectedRecording: RecordingItem? {
        recordings.first(where: { $0.id == selectedID })
    }

    func start(_ kind: RecordingKind) {
        guard state == .idle || isFailureState else { return }
        let outputURL = nextOutputURL(for: kind)
        currentOutputURL = outputURL
        elapsedSeconds = 0
        state = .starting(kind)
        capture.start(kind: kind, outputURL: outputURL) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.state = .recording(kind)
                self.startTimer()
            case .failure(let error):
                try? FileManager.default.removeItem(at: outputURL)
                self.currentOutputURL = nil
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func stop() {
        guard case .recording(let kind) = state else { return }
        state = .stopping(kind)
        timer = nil
        capture.stop { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                let completedURL = self.currentOutputURL
                self.currentOutputURL = nil
                self.state = .idle
                self.reload()
                if let completedURL { self.selectedID = completedURL.standardizedFileURL.path }
            case .failure(let error):
                self.discardCurrentOutput()
                self.state = .failed(error.localizedDescription)
                self.reload()
            }
        }
    }

    func clearError() {
        if isFailureState { state = .idle }
    }

    func reload() {
        let keys: Set<URLResourceKey> = [.creationDateKey, .fileSizeKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []
        recordings = urls.compactMap { url in
            guard ["m4a", "mov", "mp4"].contains(url.pathExtension.lowercased()) else { return nil }
            guard url.standardizedFileURL != currentOutputURL?.standardizedFileURL else { return nil }
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true else { return nil }
            let kind: RecordingKind = url.lastPathComponent.hasPrefix("screen-") ? .screen : .audio
            return RecordingItem(
                url: url,
                kind: kind,
                createdAt: values?.creationDate ?? .distantPast,
                fileSize: Int64(values?.fileSize ?? 0)
            )
        }
        .sorted { $0.createdAt > $1.createdAt }
        if let selectedID, !recordings.contains(where: { $0.id == selectedID }) {
            self.selectedID = recordings.first?.id
        } else if selectedID == nil {
            selectedID = recordings.first?.id
        }
    }

    func reveal(_ item: RecordingItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func play(_ item: RecordingItem) {
        selectedID = item.id
        playbackRequestID &+= 1
    }

    func copy(_ item: RecordingItem) {
        _ = copyFile(item.url)
    }

    func trash(_ item: RecordingItem) {
        guard item.url.standardizedFileURL != currentOutputURL?.standardizedFileURL else { return }
        do {
            try trashFile(item.url)
            reload()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private var isFailureState: Bool {
        if case .failed = state { return true }
        return false
    }

    private func startTimer() {
        timer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.elapsedSeconds += 1 }
    }

    private func discardCurrentOutput() {
        guard let currentOutputURL else { return }
        try? FileManager.default.removeItem(at: currentOutputURL)
        self.currentOutputURL = nil
    }

    private func startDirectoryMonitoring() {
        directoryMonitor = Timer.publish(every: 0.35, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.reload() }
    }

    private func nextOutputURL(for kind: RecordingKind) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return directory.appendingPathComponent(
            "\(kind.rawValue)-\(formatter.string(from: Date()))-\(UUID().uuidString).\(kind.fileExtension)"
        )
    }

    private static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("NoteIsland/Recordings", isDirectory: true)
    }

    private static func moveToTrash(_ url: URL) throws {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
    }

    private static func writeFileToPasteboard(_ url: URL) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([url as NSURL])
    }
}
