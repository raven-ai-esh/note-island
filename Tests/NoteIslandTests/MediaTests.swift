import AppKit
import AVFoundation
import Foundation
@preconcurrency import ScreenCaptureKit
import SwiftUI
import XCTest
@testable import NoteIsland

@MainActor
final class RecordingsStoreTests: XCTestCase {
    func testAudioRecordingStartStopCreatesPlayableListItem() throws {
        let directory = temporaryDirectory()
        let capture = TestRecordingCapture()
        let store = RecordingsStore(capture: capture, directory: directory)

        store.start(.audio)
        XCTAssertEqual(store.state, .recording(.audio))
        XCTAssertEqual(capture.startedKinds, [.audio])
        XCTAssertEqual(capture.activeURL?.pathExtension, "m4a")

        store.stop()

        XCTAssertEqual(store.state, .idle)
        XCTAssertEqual(store.recordings.count, 1)
        XCTAssertEqual(store.selectedRecording?.kind, .audio)
        XCTAssertGreaterThan(try XCTUnwrap(store.selectedRecording).fileSize, 0)
    }

    func testScreenRecordingUsesMovieExtension() {
        let capture = TestRecordingCapture()
        let store = RecordingsStore(capture: capture, directory: temporaryDirectory())

        store.start(.screen)

        XCTAssertEqual(store.state, .recording(.screen))
        XCTAssertEqual(capture.activeURL?.pathExtension, "mov")
    }

    func testStartFailureShowsErrorAndCanBeCleared() {
        let capture = TestRecordingCapture()
        capture.startResult = .failure(TestMediaError.startFailed)
        let store = RecordingsStore(capture: capture, directory: temporaryDirectory())

        store.start(.audio)
        XCTAssertEqual(store.state, .failed("Не удалось начать тестовую запись"))

        store.clearError()
        XCTAssertEqual(store.state, .idle)
    }

    func testStopFailureDoesNotReportIdleSuccessOrLeavePartialFile() throws {
        let capture = TestRecordingCapture()
        capture.stopResult = .failure(TestMediaError.stopFailed)
        let directory = temporaryDirectory()
        let store = RecordingsStore(capture: capture, directory: directory)

        store.start(.audio)
        let partialURL = try XCTUnwrap(capture.activeURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: partialURL)
        store.stop()

        XCTAssertEqual(store.state, .failed("Не удалось сохранить тестовую запись"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partialURL.path))
    }

    func testBothRecordingKindsShowSavingProgressUntilFinalizationCompletes() throws {
        for kind in RecordingKind.allCases {
            let capture = TestRecordingCapture()
            capture.completesStopAutomatically = false
            let store = RecordingsStore(capture: capture, directory: temporaryDirectory())

            store.start(kind)
            store.stop()

            XCTAssertEqual(store.state, .stopping(kind))
            XCTAssertTrue(store.recordings.isEmpty, "A partial file must not appear before finalization")
            store.start(kind == .audio ? .screen : .audio)
            XCTAssertEqual(capture.startedKinds, [kind], "A second capture must stay blocked while saving")

            let savingBitmap = try renderMediaView(RecordingsView(recordings: store))
            let savingAccent = try XCTUnwrap(
                colorBounds(
                    in: savingBitmap,
                    matching: NSColor(srgbRed: 0.39, green: 0.91, blue: 0.72, alpha: 1)
                ),
                "The saving state must render a distinct progress accent"
            )
            XCTAssertGreaterThan(savingAccent.width, 5)
            XCTAssertGreaterThan(savingAccent.height, 5)

            capture.completePendingStop()

            XCTAssertEqual(store.state, .idle)
            XCTAssertEqual(store.recordings.count, 1)
            XCTAssertEqual(store.selectedRecording?.kind, kind)
        }
    }

    func testSavingFailureEndsProgressAndAllowsAnotherCapture() throws {
        let capture = TestRecordingCapture()
        capture.completesStopAutomatically = false
        capture.stopResult = .failure(TestMediaError.stopFailed)
        let directory = temporaryDirectory()
        let store = RecordingsStore(capture: capture, directory: directory)

        store.start(.audio)
        let partialURL = try XCTUnwrap(capture.activeURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: partialURL)
        store.stop()
        XCTAssertEqual(store.state, .stopping(.audio))

        capture.completePendingStop()

        XCTAssertEqual(store.state, .failed("Не удалось сохранить тестовую запись"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partialURL.path))
        capture.stopResult = .success(())
        store.start(.screen)
        XCTAssertEqual(store.state, .recording(.screen))
        XCTAssertEqual(capture.startedKinds, [.audio, .screen])
    }

    func testRepeatedStartWhileRecordingIsIgnored() {
        let capture = TestRecordingCapture()
        let store = RecordingsStore(capture: capture, directory: temporaryDirectory())

        store.start(.audio)
        store.start(.screen)

        XCTAssertEqual(capture.startedKinds, [.audio])
        XCTAssertEqual(store.state, .recording(.audio))
    }

    func testTwoSequentialRecordingsStartedInSameSecondKeepDistinctFiles() throws {
        let directory = temporaryDirectory()
        let capture = TestRecordingCapture()
        let store = RecordingsStore(capture: capture, directory: directory)

        store.start(.audio)
        let firstURL = try XCTUnwrap(capture.activeURL)
        store.stop()
        store.start(.audio)
        let secondURL = try XCTUnwrap(capture.activeURL)
        store.stop()

        XCTAssertNotEqual(firstURL, secondURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
        XCTAssertEqual(store.recordings.count, 2)
    }

    func testRuntimeFailureLeavesVisibleFailureStateAndRemovesPartialFile() throws {
        let capture = TestRecordingCapture()
        let directory = temporaryDirectory()
        let store = RecordingsStore(capture: capture, directory: directory)

        store.start(.screen)
        let partialURL = try XCTUnwrap(capture.activeURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: partialURL)
        capture.sendRuntimeFailure(TestMediaError.runtimeFailed)

        XCTAssertEqual(store.state, .failed("Тестовая запись неожиданно остановилась"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partialURL.path))
    }

    func testRecordingsViewRendersNativePlayerWithoutAVKitSwiftUICrash() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-a-real-media-file".utf8).write(to: directory.appendingPathComponent("audio-test.m4a"))
        let store = RecordingsStore(capture: TestRecordingCapture(), directory: directory)

        let bitmap = try renderMediaView(RecordingsView(recordings: store))

        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, 560)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, 330)
    }

    func testDirectoryChangesAppearAndDisappearWithoutManualReload() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = RecordingsStore(capture: TestRecordingCapture(), directory: directory)
        let externalFile = directory.appendingPathComponent("audio-external.m4a")

        try Data("external recording".utf8).write(to: externalFile)
        let appeared = await waitUntil {
            store.recordings.contains {
                $0.url.resolvingSymlinksInPath() == externalFile.resolvingSymlinksInPath()
            }
        }
        XCTAssertTrue(appeared, "An externally added recording should appear without calling reload")

        try FileManager.default.removeItem(at: externalFile)
        let disappeared = await waitUntil { store.recordings.isEmpty }
        XCTAssertTrue(disappeared, "An externally removed recording should disappear without calling reload")
    }

    func testTrashUsesRecoverableBoundaryAndSelectsRemainingRecording() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let firstURL = directory.appendingPathComponent("audio-first.m4a")
        let secondURL = directory.appendingPathComponent("audio-second.m4a")
        try Data("first".utf8).write(to: firstURL)
        try Data("second".utf8).write(to: secondURL)
        var trashedURLs: [URL] = []
        let store = RecordingsStore(
            capture: TestRecordingCapture(),
            directory: directory,
            trashFile: { url in
                trashedURLs.append(url)
                try FileManager.default.removeItem(at: url)
            }
        )
        store.selectedID = firstURL.standardizedFileURL.path
        let first = try XCTUnwrap(store.selectedRecording)

        store.trash(first)

        XCTAssertEqual(trashedURLs.map(\.lastPathComponent), [firstURL.lastPathComponent])
        XCTAssertFalse(store.recordings.contains { $0.url.lastPathComponent == firstURL.lastPathComponent })
        XCTAssertEqual(store.selectedRecording?.url.lastPathComponent, secondURL.lastPathComponent)
    }

    func testCopyUsesInjectedFilePasteboardBoundary() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("audio-copy.m4a")
        try Data("copy".utf8).write(to: file)
        var copiedURLs: [URL] = []
        let store = RecordingsStore(
            capture: TestRecordingCapture(),
            directory: directory,
            copyFile: { url in
                copiedURLs.append(url)
                return true
            }
        )

        store.copy(try XCTUnwrap(store.selectedRecording))

        XCTAssertEqual(copiedURLs.map(\.lastPathComponent), [file.lastPathComponent])
    }

    func testRepeatedPlaybackRequestForSelectedRecordingIsNotLost() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("audio-play.m4a")
        try Data("play".utf8).write(to: file)
        let store = RecordingsStore(capture: TestRecordingCapture(), directory: directory)
        let item = try XCTUnwrap(store.selectedRecording)

        store.play(item)
        store.play(item)

        XCTAssertEqual(store.selectedID, item.id)
        XCTAssertEqual(store.playbackRequestID, 2)
    }

    private func waitUntil(
        attempts: Int = 30,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

@MainActor
final class SystemRecordingControllerTests: XCTestCase {
    func testUserDeclinedCaptureErrorMapsToPermissionMessage() {
        let declined = NSError(
            domain: SCStreamErrorDomain,
            code: SCStreamError.Code.userDeclined.rawValue
        )

        let mapped = SystemRecordingController.mapCaptureStartError(declined)

        guard case .screenDenied = mapped as? MediaCaptureError else {
            return XCTFail("userDeclined must map to screenDenied")
        }
        XCTAssertEqual(mapped.localizedDescription, MediaCaptureError.screenDenied.localizedDescription)
    }

    func testNonPermissionCaptureErrorPassesThroughUnchanged() {
        let original = NSError(domain: "test.capture", code: 77, userInfo: [NSLocalizedDescriptionKey: "boom"])

        let mapped = SystemRecordingController.mapCaptureStartError(original) as NSError

        XCTAssertEqual(mapped.domain, original.domain)
        XCTAssertEqual(mapped.code, original.code)
        XCTAssertEqual(mapped.localizedDescription, original.localizedDescription)
    }
}

@MainActor
final class SystemAudioExporterTests: XCTestCase {
    func testAppBundleDeclaresLoadableApplicationIcon() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = packageRoot.appendingPathComponent("App/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
        let iconName = try XCTUnwrap(plist["CFBundleIconFile"] as? String)
        XCTAssertEqual(iconName, "NoteIsland.icns")

        let iconURL = packageRoot.appendingPathComponent("App/NoteIsland.icns")
        XCTAssertTrue(FileManager.default.fileExists(atPath: iconURL.path))
        let icon = try XCTUnwrap(NSImage(contentsOf: iconURL))
        XCTAssertGreaterThanOrEqual(icon.size.width, 512)
        XCTAssertGreaterThanOrEqual(icon.size.height, 512)
    }

    func testPrivacyDescriptionsDiscloseSystemAudioInBothRecordingModes() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = packageRoot.appendingPathComponent("App/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
        let disclosure = try XCTUnwrap(plist["NSAudioCaptureUsageDescription"] as? String)

        XCTAssertTrue(disclosure.contains("системный звук"))
        XCTAssertTrue(disclosure.contains("аудио- или экранной записи"))
    }

    func testAudioExporterProducesPlayableM4AAndWaitsForCompletion() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("source.caf")
        let destination = directory.appendingPathComponent("result.m4a")
        try makeTone(at: source)

        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            SystemAudioExporter().exportAudio(from: source, to: destination) {
                continuation.resume(returning: $0)
            }
        }
        try result.get()

        let asset = AVURLAsset(url: destination)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertGreaterThan(CMTimeGetSeconds(duration), 0.05)
        XCTAssertGreaterThan(try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, 0)
    }

    private func makeTone(at url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        buffer.frameLength = 4_800
        for channel in 0..<Int(format.channelCount) {
            guard let samples = buffer.floatChannelData?[channel] else { continue }
            for frame in 0..<Int(buffer.frameLength) {
                samples[frame] = sin(Float(frame) * 2 * .pi * 440 / 48_000) * 0.15
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

@MainActor
final class ScreenshotsStoreTests: XCTestCase {
    func testClipboardLibraryStoresImagesInPrivateHistoryAndDeduplicatesContent() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = SystemScreenshotLibrary(directory: directory)
        let data = try bluePNG()

        let first = try library.storePNG(data)
        let second = try library.storePNG(data)

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(try library.screenshots().count, 1)
        XCTAssertEqual(first.url.deletingLastPathComponent(), directory)
    }

    func testEditedItemDoesNotBlockReimportOfItsOriginalClipboardImage() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = SystemScreenshotLibrary(directory: directory)
        let original = try bluePNG()
        let first = try library.storePNG(original)
        try library.replace(first.url, withPNG: try makePNG(width: 8, height: 8, color: .systemRed))

        let reimported = try library.storePNG(original)

        XCTAssertNotEqual(first.id, reimported.id)
        XCTAssertEqual(try library.screenshots().count, 2)
    }

    func testClipboardChangeIsCapturedWithoutReadingDesktopFolder() throws {
        let library = TestScreenshotLibrary(directory: temporaryDirectory())
        let pasteboard = TestScreenshotPasteboard()
        let store = ScreenshotsStore(library: library, pasteboard: pasteboard)

        pasteboard.simulateNewImage(try bluePNG())
        store.captureClipboardIfChanged()

        XCTAssertEqual(library.storedPNGs.count, 1)
        XCTAssertEqual(store.screenshots.count, 1)
        XCTAssertEqual(store.selectedID, store.screenshots.first?.id)
    }

    func testDroppedImageFileIsImportedIntoPrivateHistory() throws {
        let sourceDirectory = temporaryDirectory()
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let source = sourceDirectory.appendingPathComponent("drop.png")
        try bluePNG().write(to: source)
        let library = TestScreenshotLibrary(directory: temporaryDirectory())
        let store = ScreenshotsStore(library: library, pasteboard: TestScreenshotPasteboard())

        XCTAssertTrue(store.importURLs([source]))
        XCTAssertEqual(library.storedPNGs.count, 1)
        XCTAssertEqual(store.screenshots.count, 1)
    }

    func testDroppedImageGroupImportsEveryFileFromTheDrag() throws {
        let sourceDirectory = temporaryDirectory()
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let urls = try (0..<3).map { index -> URL in
            let url = sourceDirectory.appendingPathComponent("drop-group-\(index).png")
            try makePNG(width: 20, height: 20, color: [.red, .green, .blue][index]).write(to: url)
            return url
        }
        let library = TestScreenshotLibrary(directory: temporaryDirectory())
        let store = ScreenshotsStore(library: library, pasteboard: TestScreenshotPasteboard())

        XCTAssertTrue(store.importURLs(urls))
        XCTAssertEqual(library.storedPNGs.count, urls.count)
        XCTAssertEqual(store.screenshots.count, urls.count)
    }

    func testReloadSelectsNewestAndHandlesEmptyState() {
        let library = TestScreenshotLibrary()
        library.items = [sampleScreenshot(name: "Screenshot one.png", time: 1)]
        let store = ScreenshotsStore(library: library, pasteboard: TestScreenshotPasteboard())

        XCTAssertEqual(store.selectedID, library.items[0].id)
        library.items = []
        store.reload()

        XCTAssertTrue(store.screenshots.isEmpty)
        XCTAssertNil(store.selectedID)
        XCTAssertTrue(store.selectedIDs.isEmpty)
    }

    func testShiftSelectionSelectsContiguousRangeInBothDirections() {
        let library = TestScreenshotLibrary()
        library.items = (0..<5).map {
            sampleScreenshot(name: "Screenshot \($0).png", time: TimeInterval(5 - $0))
        }
        let store = ScreenshotsStore(library: library, pasteboard: TestScreenshotPasteboard())

        store.select(library.items[1])
        store.select(library.items[4], extendingSelection: true)
        XCTAssertEqual(store.selectedIDs, Set(library.items[1...4].map(\.id)))
        XCTAssertEqual(store.selectedID, library.items[4].id)

        store.select(library.items[0], extendingSelection: true)
        XCTAssertEqual(store.selectedIDs, Set(library.items[0...1].map(\.id)))
        XCTAssertEqual(store.selectedID, library.items[0].id)
    }

    func testCommandToggleBuildsArbitrarySelectionAndCanRemoveLastItem() {
        let library = TestScreenshotLibrary()
        let items = (0..<5).map {
            sampleScreenshot(name: "Command \($0).png", time: TimeInterval(5 - $0))
        }
        library.items = items
        let store = ScreenshotsStore(library: library, pasteboard: TestScreenshotPasteboard())

        store.toggleSelection(items[2])
        store.toggleSelection(items[4])
        XCTAssertEqual(store.selectedIDs, [items[0].id, items[2].id, items[4].id])
        XCTAssertEqual(store.selectedID, items[4].id)
        XCTAssertEqual(
            store.actionItems(containing: items[0]).map(\.id),
            [items[0].id, items[2].id, items[4].id]
        )

        store.toggleSelection(items[2])
        XCTAssertEqual(store.selectedIDs, [items[0].id, items[4].id])
        XCTAssertEqual(store.selectedID, items[4].id)

        store.toggleSelection(items[4])
        XCTAssertEqual(store.selectedIDs, [items[0].id])
        XCTAssertEqual(store.selectedID, items[0].id)

        store.toggleSelection(items[0])
        XCTAssertTrue(store.selectedIDs.isEmpty)
        XCTAssertNil(store.selectedID)

        store.toggleSelection(items[3])
        XCTAssertEqual(store.selectedIDs, [items[3].id])
        XCTAssertEqual(store.selectedID, items[3].id)
    }

    func testOnlyShiftModifierRequestsRangeSelection() {
        XCTAssertTrue(ScreenshotSelectionIntent.extendsRange(for: [.shift]))
        XCTAssertTrue(ScreenshotSelectionIntent.extendsRange(for: [.shift, .capsLock]))
        XCTAssertFalse(ScreenshotSelectionIntent.extendsRange(for: []))
        XCTAssertFalse(ScreenshotSelectionIntent.extendsRange(for: [.command]))
    }

    func testOnlyCommandWithoutShiftRequestsIndependentToggleSelection() {
        XCTAssertTrue(ScreenshotSelectionIntent.togglesItem(for: [.command]))
        XCTAssertTrue(ScreenshotSelectionIntent.togglesItem(for: [.command, .capsLock]))
        XCTAssertFalse(ScreenshotSelectionIntent.togglesItem(for: []))
        XCTAssertFalse(ScreenshotSelectionIntent.togglesItem(for: [.shift]))
        XCTAssertFalse(ScreenshotSelectionIntent.togglesItem(for: [.command, .shift]))
    }

    func testAppKitThumbnailReceivesShiftMouseEventAndExtendsStoreRange() throws {
        let library = TestScreenshotLibrary()
        let items = (0..<4).map {
            sampleScreenshot(name: "Screenshot \($0).png", time: TimeInterval(4 - $0))
        }
        library.items = items
        let store = ScreenshotsStore(library: library, pasteboard: TestScreenshotPasteboard())
        store.select(items[1])
        let interaction = ScreenshotDragInteractionNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        interaction.selectAction = { extending in
            store.select(items[3], extendingSelection: extending)
        }

        interaction.mouseDown(with: try mouseEvent(type: .leftMouseDown, modifiers: [.shift]))
        interaction.mouseUp(with: try mouseEvent(type: .leftMouseUp, modifiers: [.shift]))

        XCTAssertEqual(store.selectedIDs, Set(items[1...3].map(\.id)))
        XCTAssertEqual(store.selectedID, items[3].id)
    }

    func testPlainClickOnSelectedGroupCollapsesOnlyOnMouseUpSoDragCanKeepGroup() throws {
        let library = TestScreenshotLibrary()
        let items = (0..<3).map {
            sampleScreenshot(name: "Screenshot \($0).png", time: TimeInterval(3 - $0))
        }
        library.items = items
        let store = ScreenshotsStore(library: library, pasteboard: TestScreenshotPasteboard())
        store.select(items[0])
        store.select(items[2], extendingSelection: true)
        let interaction = ScreenshotDragInteractionNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let clickCoordinator = ScreenshotClickCoordinator(delay: 60)
        interaction.clickCoordinator = clickCoordinator
        interaction.selected = true
        interaction.selectionCount = 3
        interaction.selectAction = { extending in
            store.select(items[1], extendingSelection: extending)
        }

        interaction.mouseDown(with: try mouseEvent(type: .leftMouseDown))
        XCTAssertEqual(store.selectedIDs.count, 3)
        interaction.mouseUp(with: try mouseEvent(type: .leftMouseUp))
        XCTAssertEqual(store.selectedIDs.count, 3, "The group must survive until the double-click window closes")
        clickCoordinator.performPendingSelection()
        XCTAssertEqual(store.selectedIDs, [items[1].id])
    }

    func testDoubleClickOpensClickedScreenshotWithoutContextMenu() throws {
        let library = TestScreenshotLibrary()
        let items = (0..<2).map {
            sampleScreenshot(name: "Screenshot \($0).png", time: TimeInterval(2 - $0))
        }
        library.items = items
        let presenter = TestScreenshotEditorPresenter()
        let store = ScreenshotsStore(
            library: library,
            pasteboard: TestScreenshotPasteboard(),
            editorPresenter: presenter
        )
        let interaction = ScreenshotDragInteractionNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        interaction.clickCoordinator = ScreenshotClickCoordinator(delay: 60)
        interaction.selected = false
        interaction.selectionCount = 1
        interaction.selectAction = { extending in store.select(items[1], extendingSelection: extending) }
        interaction.openAction = { store.openSelection(containing: items[1]) }

        interaction.mouseDown(with: try mouseEvent(type: .leftMouseDown, clickCount: 1))
        interaction.mouseUp(with: try mouseEvent(type: .leftMouseUp, clickCount: 1))
        interaction.selected = true
        interaction.mouseDown(with: try mouseEvent(type: .leftMouseDown, clickCount: 2))
        interaction.mouseUp(with: try mouseEvent(type: .leftMouseUp, clickCount: 2))

        XCTAssertEqual(store.selectedIDs, [items[1].id])
        XCTAssertEqual(presenter.openedURLs, [items[1].url])
    }

    func testDoubleClickOnSelectedRangeOpensEntireGroupWithoutCollapsingIt() throws {
        let library = TestScreenshotLibrary()
        let items = (0..<3).map {
            sampleScreenshot(name: "Screenshot \($0).png", time: TimeInterval(3 - $0))
        }
        library.items = items
        let presenter = TestScreenshotEditorPresenter()
        let store = ScreenshotsStore(
            library: library,
            pasteboard: TestScreenshotPasteboard(),
            editorPresenter: presenter
        )
        store.select(items[0])
        store.select(items[2], extendingSelection: true)
        let interaction = ScreenshotDragInteractionNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let clickCoordinator = ScreenshotClickCoordinator(delay: 60)
        interaction.clickCoordinator = clickCoordinator
        interaction.selected = true
        interaction.selectionCount = 3
        interaction.selectAction = { extending in store.select(items[1], extendingSelection: extending) }
        interaction.openAction = { store.openSelection(containing: items[1]) }

        interaction.mouseDown(with: try mouseEvent(type: .leftMouseDown, clickCount: 1))
        interaction.mouseUp(with: try mouseEvent(type: .leftMouseUp, clickCount: 1))
        interaction.mouseDown(with: try mouseEvent(type: .leftMouseDown, clickCount: 2))
        interaction.mouseUp(with: try mouseEvent(type: .leftMouseUp, clickCount: 2))

        XCTAssertEqual(store.selectedIDs, Set(items.map(\.id)))
        XCTAssertEqual(presenter.openedURLs, items.map(\.url))
        clickCoordinator.performPendingSelection()
        XCTAssertEqual(store.selectedIDs, Set(items.map(\.id)), "Cancelled single-click work must not fire later")
    }

    func testRightClickCancelsPendingSingleSelectionAndGroupActionStillTargetsRange() throws {
        let library = TestScreenshotLibrary()
        let items = (0..<3).map {
            sampleScreenshot(name: "Screenshot \($0).png", time: TimeInterval(3 - $0))
        }
        library.items = items
        let pasteboard = TestScreenshotPasteboard()
        let store = ScreenshotsStore(library: library, pasteboard: pasteboard)
        store.select(items[0])
        store.select(items[2], extendingSelection: true)
        let coordinator = ScreenshotClickCoordinator(delay: 60)
        let interaction = ScreenshotDragInteractionNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        interaction.clickCoordinator = coordinator
        interaction.selected = true
        interaction.selectionCount = 3
        interaction.selectAction = { extending in store.select(items[1], extendingSelection: extending) }
        interaction.prepareActions = { store.prepareActions(for: items[1]) }
        interaction.actionCount = { store.actionItems(containing: items[1]).count }
        interaction.copyAction = { store.copySelection(containing: items[1]) }

        interaction.mouseDown(with: try mouseEvent(type: .leftMouseDown))
        interaction.mouseUp(with: try mouseEvent(type: .leftMouseUp))
        let menu = try XCTUnwrap(interaction.menu(for: mouseEvent(type: .rightMouseDown)))
        let copyItem = try XCTUnwrap(menu.items.first { $0.title == "Скопировать (3)" })
        XCTAssertTrue(NSApp.sendAction(copyItem.action!, to: copyItem.target, from: copyItem))
        coordinator.performPendingSelection()

        XCTAssertEqual(store.selectedIDs, Set(items.map(\.id)))
        XCTAssertEqual(pasteboard.copiedURLs, items.map(\.url))
    }

    func testInlineMenuCancelsPendingSingleSelectionAndGroupActionStillTargetsRange() throws {
        let library = TestScreenshotLibrary()
        let items = (0..<3).map {
            sampleScreenshot(name: "Screenshot \($0).png", time: TimeInterval(3 - $0))
        }
        library.items = items
        let pasteboard = TestScreenshotPasteboard()
        let store = ScreenshotsStore(library: library, pasteboard: pasteboard)
        store.select(items[0])
        store.select(items[2], extendingSelection: true)
        let coordinator = ScreenshotClickCoordinator(delay: 60)
        let interaction = ScreenshotDragInteractionNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        interaction.clickCoordinator = coordinator
        interaction.selected = true
        interaction.selectionCount = 3
        interaction.selectAction = { extending in store.select(items[1], extendingSelection: extending) }
        interaction.mouseDown(with: try mouseEvent(type: .leftMouseDown))
        interaction.mouseUp(with: try mouseEvent(type: .leftMouseUp))

        let button = ScreenshotActionMenuNSButton()
        button.clickCoordinator = coordinator
        button.selectionCount = 3
        button.prepareActions = { store.prepareActions(for: items[1]) }
        button.actionCount = { store.actionItems(containing: items[1]).count }
        button.copyAction = { store.copySelection(containing: items[1]) }
        let menu = button.prepareAndBuildMenu()
        let copyItem = try XCTUnwrap(menu.items.first { $0.title == "Скопировать (3)" })
        XCTAssertTrue(NSApp.sendAction(copyItem.action!, to: copyItem.target, from: copyItem))
        coordinator.performPendingSelection()

        XCTAssertEqual(store.selectedIDs, Set(items.map(\.id)))
        XCTAssertEqual(pasteboard.copiedURLs, items.map(\.url))
    }

    func testMenuRecomputesCountIfPendingSingleSelectionAlreadyCompleted() throws {
        let library = TestScreenshotLibrary()
        let items = (0..<3).map {
            sampleScreenshot(name: "Screenshot \($0).png", time: TimeInterval(3 - $0))
        }
        library.items = items
        let pasteboard = TestScreenshotPasteboard()
        let store = ScreenshotsStore(library: library, pasteboard: pasteboard)
        store.select(items[0])
        store.select(items[2], extendingSelection: true)
        let button = ScreenshotActionMenuNSButton()
        button.selectionCount = 3
        button.prepareActions = { store.prepareActions(for: items[1]) }
        button.actionCount = { store.actionItems(containing: items[1]).count }
        button.copyAction = { store.copySelection(containing: items[1]) }

        store.select(items[1])
        let menu = button.prepareAndBuildMenu()

        XCTAssertNil(menu.items.first { $0.title == "Скопировать (3)" })
        let copyItem = try XCTUnwrap(menu.items.first { $0.title == "Скопировать" })
        XCTAssertTrue(NSApp.sendAction(copyItem.action!, to: copyItem.target, from: copyItem))
        XCTAssertEqual(pasteboard.copiedURLs, [items[1].url])
    }

    func testNativeContextMenuShowsGroupCountAndRoutesEveryActionClosure() throws {
        let interaction = ScreenshotDragInteractionNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        interaction.selected = true
        interaction.selectionCount = 3
        var invoked: [String] = []
        interaction.openAction = { invoked.append("open") }
        interaction.copyAction = { invoked.append("copy") }
        interaction.editAction = { invoked.append("edit") }
        interaction.revealAction = { invoked.append("reveal") }
        interaction.trashAction = { invoked.append("trash") }

        let menu = try XCTUnwrap(interaction.menu(for: mouseEvent(type: .rightMouseDown)))
        XCTAssertEqual(
            menu.items.filter { !$0.isSeparatorItem }.map(\.title),
            ["Открыть (3)", "Скопировать (3)", "Редактировать (3)", "Показать в Finder (3)", "Удалить (3)"]
        )
        for item in menu.items where !item.isSeparatorItem {
            XCTAssertTrue(NSApp.sendAction(item.action!, to: item.target, from: item))
        }
        XCTAssertEqual(invoked, ["open", "copy", "edit", "reveal", "trash"])
    }

    func testInlineActionMenuPreparesClickedItemBeforeBuildingAndRunningAction() throws {
        let library = TestScreenshotLibrary()
        let items = (0..<4).map {
            sampleScreenshot(name: "Screenshot \($0).png", time: TimeInterval(4 - $0))
        }
        library.items = items
        let pasteboard = TestScreenshotPasteboard()
        let store = ScreenshotsStore(library: library, pasteboard: pasteboard)
        store.select(items[0])
        store.select(items[2], extendingSelection: true)

        let button = ScreenshotActionMenuNSButton()
        button.selectionCount = 1
        button.prepareActions = { store.prepareActions(for: items[3]) }
        button.copyAction = { store.copySelection(containing: items[3]) }

        let menu = button.prepareAndBuildMenu()

        XCTAssertEqual(store.selectedIDs, [items[3].id])
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title), [
            "Открыть", "Скопировать", "Редактировать", "Показать в Finder", "Удалить"
        ])
        let copyItem = try XCTUnwrap(menu.items.first { $0.title == "Скопировать" })
        XCTAssertTrue(NSApp.sendAction(copyItem.action!, to: copyItem.target, from: copyItem))
        XCTAssertEqual(pasteboard.copiedURLs, [items[3].url])
    }

    func testPlainSelectionAfterShiftRangeReturnsToOneScreenshot() {
        let library = TestScreenshotLibrary()
        library.items = (0..<4).map {
            sampleScreenshot(name: "Screenshot \($0).png", time: TimeInterval(4 - $0))
        }
        let store = ScreenshotsStore(library: library, pasteboard: TestScreenshotPasteboard())

        store.select(library.items[0])
        store.select(library.items[3], extendingSelection: true)
        store.select(library.items[2])

        XCTAssertEqual(store.selectedIDs, [library.items[2].id])
        XCTAssertEqual(store.selectedID, library.items[2].id)
    }

    func testClickUsesStableIdentityWhenReloadChangesScreenshotMetadata() {
        let library = TestScreenshotLibrary()
        let first = sampleScreenshot(name: "First.png", time: 2)
        let staleSecond = sampleScreenshot(name: "Second.png", time: 1)
        library.items = [first, staleSecond]
        let store = ScreenshotsStore(library: library, pasteboard: TestScreenshotPasteboard())

        library.items = [
            first,
            ScreenshotItem(
                url: staleSecond.url,
                createdAt: staleSecond.createdAt,
                fileSize: staleSecond.fileSize + 500
            )
        ]
        store.reload()
        store.select(staleSecond)

        XCTAssertEqual(store.selectedIDs, [staleSecond.id])
        XCTAssertEqual(store.selectedID, staleSecond.id)

        store.select(first)
        store.select(staleSecond, extendingSelection: true)
        XCTAssertEqual(store.selectedIDs, Set([first.id, staleSecond.id]))
        XCTAssertEqual(store.selectedID, staleSecond.id)
    }

    func testContextActionsUseStableIdentityAfterMetadataReload() {
        let library = TestScreenshotLibrary()
        let first = sampleScreenshot(name: "First.png", time: 2)
        let staleSecond = sampleScreenshot(name: "Second.png", time: 1)
        library.items = [first, staleSecond]
        let pasteboard = TestScreenshotPasteboard()
        let presenter = TestScreenshotEditorPresenter()
        let revealer = TestScreenshotFileRevealer()
        let store = ScreenshotsStore(
            library: library,
            pasteboard: pasteboard,
            editorPresenter: presenter,
            fileRevealer: revealer
        )

        library.items = [
            first,
            ScreenshotItem(
                url: staleSecond.url,
                createdAt: staleSecond.createdAt,
                fileSize: staleSecond.fileSize + 500
            )
        ]
        store.reload()
        store.prepareActions(for: staleSecond)
        store.openSelection(containing: staleSecond)
        store.copySelection(containing: staleSecond)
        store.editSelection(containing: staleSecond)
        store.revealSelection(containing: staleSecond)

        XCTAssertEqual(store.selectedIDs, [staleSecond.id])
        XCTAssertEqual(presenter.openedURLs, [staleSecond.url])
        XCTAssertEqual(presenter.presentedURLs, [staleSecond.url])
        XCTAssertEqual(pasteboard.copiedURLs, [staleSecond.url])
        XCTAssertEqual(revealer.revealedURLs, [staleSecond.url])
    }

    func testReloadPreservesExistingMultiSelectionAndDropsMissingItems() {
        let library = TestScreenshotLibrary()
        library.items = (0..<4).map {
            sampleScreenshot(name: "Screenshot \($0).png", time: TimeInterval(4 - $0))
        }
        let store = ScreenshotsStore(library: library, pasteboard: TestScreenshotPasteboard())
        store.select(library.items[0])
        store.select(library.items[3], extendingSelection: true)

        let retained = [library.items[0], library.items[2], library.items[3]]
        library.items = retained
        store.reload()

        XCTAssertEqual(store.selectedIDs, Set(retained.map(\.id)))
        XCTAssertTrue(store.selectedIDs.contains(store.selectedID!))
    }

    func testReloadFailureClearsExistingMultiSelectionAndRetrySelectsFirstItem() {
        let library = TestScreenshotLibrary()
        library.items = (0..<4).map {
            sampleScreenshot(name: "Screenshot \($0).png", time: TimeInterval(4 - $0))
        }
        let store = ScreenshotsStore(library: library, pasteboard: TestScreenshotPasteboard())
        store.select(library.items[0])
        store.select(library.items[3], extendingSelection: true)
        XCTAssertEqual(store.selectedIDs.count, 4)

        library.error = TestMediaError.scanFailed
        store.reload()
        XCTAssertNil(store.selectedID)
        XCTAssertTrue(store.selectedIDs.isEmpty)

        library.error = nil
        store.reload()
        XCTAssertEqual(store.selectedID, library.items[0].id)
        XCTAssertEqual(store.selectedIDs, [library.items[0].id])
    }

    func testItemActionOutsideActiveMultiRangeTargetsOnlyClickedScreenshot() {
        let library = TestScreenshotLibrary()
        let items = (0..<4).map {
            sampleScreenshot(name: "Screenshot \($0).png", time: TimeInterval(4 - $0))
        }
        library.items = items
        let pasteboard = TestScreenshotPasteboard()
        let store = ScreenshotsStore(library: library, pasteboard: pasteboard)
        store.select(items[0])
        store.select(items[2], extendingSelection: true)

        store.prepareActions(for: items[3])
        store.copySelection(containing: items[3])
        store.trashSelection(containing: items[3])

        XCTAssertEqual(pasteboard.copiedURLs, [items[3].url])
        XCTAssertEqual(library.trashedURLs, [items[3].url])
        XCTAssertEqual(store.selectedIDs, [items[0].id])
        XCTAssertEqual(store.screenshots, Array(items[0...2]))
    }

    func testEveryActionFromSelectedCardTargetsEntireActiveRange() {
        let library = TestScreenshotLibrary()
        let items = (0..<4).map {
            sampleScreenshot(name: "Screenshot \($0).png", time: TimeInterval(4 - $0))
        }
        library.items = items
        let pasteboard = TestScreenshotPasteboard()
        let editor = TestScreenshotEditorPresenter()
        let revealer = TestScreenshotFileRevealer()
        let store = ScreenshotsStore(
            library: library,
            pasteboard: pasteboard,
            editorPresenter: editor,
            fileRevealer: revealer
        )
        store.select(items[0])
        store.select(items[2], extendingSelection: true)
        let selected = Array(items[0...2])

        store.openSelection(containing: items[1])
        store.copySelection(containing: items[1])
        store.editSelection(containing: items[1])
        store.revealSelection(containing: items[1])

        XCTAssertEqual(editor.openedURLs, selected.map(\.url))
        XCTAssertEqual(pasteboard.copiedURLs, selected.map(\.url))
        XCTAssertEqual(editor.presentedURLs, selected.map(\.url))
        XCTAssertEqual(revealer.revealedURLs, selected.map(\.url))
        XCTAssertEqual(store.dragURLs(containing: items[1]), selected.map(\.url))
        XCTAssertEqual(store.copiedIDs, Set(selected.map(\.id)))

        store.trashSelection(containing: items[1])

        XCTAssertEqual(library.trashedURLs, selected.map(\.url))
        XCTAssertEqual(store.screenshots, [items[3]])
        XCTAssertEqual(store.selectedID, items[3].id)
    }

    func testGroupCopyFailureIsVisibleAndRetryCopiesEverySelectedImage() {
        let library = TestScreenshotLibrary()
        let items = (0..<3).map {
            sampleScreenshot(name: "Screenshot \($0).png", time: TimeInterval(3 - $0))
        }
        library.items = items
        let pasteboard = TestScreenshotPasteboard()
        pasteboard.writeResult = false
        let store = ScreenshotsStore(library: library, pasteboard: pasteboard)
        store.select(items[0])
        store.select(items[2], extendingSelection: true)

        store.copySelection(containing: items[1])
        XCTAssertEqual(store.errorMessage, "Не удалось скопировать выбранные скриншоты.")
        XCTAssertTrue(pasteboard.copiedURLs.isEmpty)
        XCTAssertTrue(store.copiedIDs.isEmpty)

        pasteboard.writeResult = true
        store.copySelection(containing: items[1])
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(pasteboard.copiedURLs, items.map(\.url))
        XCTAssertEqual(store.copiedIDs, Set(items.map(\.id)))
    }

    func testGroupTrashContinuesAfterPartialFailureAndCanRetryFailedItem() {
        let library = TestScreenshotLibrary()
        let items = (0..<3).map {
            sampleScreenshot(name: "Screenshot \($0).png", time: TimeInterval(3 - $0))
        }
        library.items = items
        library.trashErrors[items[1].url] = TestMediaError.trashFailed
        let store = ScreenshotsStore(library: library, pasteboard: TestScreenshotPasteboard())
        store.select(items[0])
        store.select(items[2], extendingSelection: true)

        store.trashSelection(containing: items[1])

        XCTAssertEqual(library.trashedURLs, [items[0].url, items[2].url])
        XCTAssertEqual(store.screenshots, [items[1]])
        XCTAssertEqual(store.selectedID, items[1].id)
        XCTAssertEqual(store.errorMessage, "Не удалось переместить тестовый файл в Корзину")

        library.trashErrors = [:]
        store.trashSelection(containing: items[1])
        XCTAssertTrue(store.screenshots.isEmpty)
        XCTAssertNil(store.errorMessage)
    }

    func testPartialGroupFailureKeepsSelectedGridVisibleAndErrorCanBeDismissed() throws {
        let library = TestScreenshotLibrary()
        let items = (0..<3).map {
            sampleScreenshot(name: "Screenshot \($0).png", time: TimeInterval(3 - $0))
        }
        library.items = items
        let pasteboard = TestScreenshotPasteboard()
        pasteboard.writeResult = false
        let store = ScreenshotsStore(library: library, pasteboard: pasteboard)
        store.select(items[0])
        store.select(items[2], extendingSelection: true)

        let bitmap = try renderMediaView(
            ScreenshotsView(screenshots: store),
            afterInitialLayout: { store.copySelected() }
        )

        XCTAssertNotNil(store.errorMessage)
        XCTAssertGreaterThanOrEqual(
            horizontalColorClusterCount(in: bitmap, matching: NSColor(NoteColor.sky.color)),
            3,
            "The selected grid must remain actionable behind a non-blocking error banner"
        )
        XCTAssertNotNil(colorBounds(in: bitmap, matching: NSColor(NoteColor.peach.color)))

        store.dismissError()
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.selectedIDs, Set(items.map(\.id)))
    }

    func testSavingOneEditorFromGroupPreservesEntireSelection() throws {
        let library = TestScreenshotLibrary()
        let items = (0..<3).map {
            sampleScreenshot(name: "Screenshot \($0).png", time: TimeInterval(3 - $0))
        }
        library.items = items
        let presenter = TestScreenshotEditorPresenter()
        let store = ScreenshotsStore(
            library: library,
            pasteboard: TestScreenshotPasteboard(),
            editorPresenter: presenter
        )
        store.select(items[0])
        store.select(items[2], extendingSelection: true)

        store.editSelection(containing: items[1])
        presenter.save(Data("edited".utf8), for: items[1].url)

        XCTAssertEqual(library.replacements.map(\.0), [items[1].url])
        XCTAssertEqual(store.selectedIDs, Set(items.map(\.id)))
        XCTAssertEqual(store.selectedID, items[2].id)
    }

    func testMultiFileDragPayloadContainsOneFileURLItemPerSelectedScreenshot() {
        let urls = (0..<3).map {
            URL(fileURLWithPath: "/tmp/drag-screenshot-\($0).png")
        }

        let pasteboardItems = ScreenshotDragPayload.pasteboardItems(for: urls)
        let draggingItems = ScreenshotDragPayload.draggingItems(
            for: urls,
            frame: NSRect(x: 0, y: 0, width: 120, height: 80)
        )

        XCTAssertEqual(pasteboardItems.count, urls.count)
        XCTAssertEqual(draggingItems.count, urls.count)
        XCTAssertEqual(
            pasteboardItems.compactMap { $0.string(forType: .fileURL) },
            urls.map(\.absoluteString)
        )
    }

    func testGroupActionTitlesExposeSelectionCount() {
        XCTAssertEqual(ScreenshotActionPresentation.title("Удалить", count: 1), "Удалить")
        XCTAssertEqual(ScreenshotActionPresentation.title("Удалить", count: 3), "Удалить (3)")
    }

    func testCopyUsesInjectedClipboardWithoutTouchingUserPasteboard() {
        let library = TestScreenshotLibrary()
        let item = sampleScreenshot(name: "Screenshot copy.png", time: 2)
        library.items = [item]
        let pasteboard = TestScreenshotPasteboard()
        let store = ScreenshotsStore(library: library, pasteboard: pasteboard)

        store.copySelected()
        store.captureClipboardIfChanged()

        XCTAssertEqual(pasteboard.copiedURLs, [item.url])
        XCTAssertEqual(store.copiedID, item.id)
        XCTAssertTrue(library.storedPNGs.isEmpty, "Copying from Note Island must not re-import the same image")
    }

    func testTrashRemovesSelectedScreenshotAndSelectsRemainingItem() {
        let library = TestScreenshotLibrary()
        let first = sampleScreenshot(name: "Screenshot first.png", time: 2)
        let second = sampleScreenshot(name: "Screenshot second.png", time: 1)
        library.items = [first, second]
        let store = ScreenshotsStore(library: library, pasteboard: TestScreenshotPasteboard())

        store.trashSelected()

        XCTAssertEqual(library.trashedURLs, [first.url])
        XCTAssertEqual(store.selectedID, second.id)
        XCTAssertEqual(store.screenshots, [second])
    }

    func testItemScopedActionsTargetClickedScreenshotInsteadOfCurrentSelection() {
        let library = TestScreenshotLibrary()
        let selected = sampleScreenshot(name: "Screenshot selected.png", time: 2)
        let clicked = sampleScreenshot(name: "Screenshot clicked.png", time: 1)
        library.items = [selected, clicked]
        let pasteboard = TestScreenshotPasteboard()
        let store = ScreenshotsStore(library: library, pasteboard: pasteboard)

        XCTAssertEqual(store.selectedID, selected.id)
        store.copy(clicked)
        store.trash(clicked)

        XCTAssertEqual(pasteboard.copiedURLs, [clicked.url])
        XCTAssertEqual(library.trashedURLs, [clicked.url])
        XCTAssertEqual(store.screenshots, [selected])
    }

    func testOpenEditAndRevealTargetClickedScreenshotInsteadOfCurrentSelection() {
        let library = TestScreenshotLibrary()
        let selected = sampleScreenshot(name: "Screenshot selected.png", time: 2)
        let clicked = sampleScreenshot(name: "Screenshot clicked.png", time: 1)
        library.items = [selected, clicked]
        let editor = TestScreenshotEditorPresenter()
        let revealer = TestScreenshotFileRevealer()
        let store = ScreenshotsStore(
            library: library,
            pasteboard: TestScreenshotPasteboard(),
            editorPresenter: editor,
            fileRevealer: revealer
        )

        XCTAssertEqual(store.selectedID, selected.id)
        store.open(clicked)
        XCTAssertEqual(store.selectedID, clicked.id)
        XCTAssertEqual(editor.openedURLs, [clicked.url])

        store.selectedID = selected.id
        store.edit(clicked)
        store.reveal(clicked)

        XCTAssertEqual(store.selectedID, clicked.id)
        XCTAssertEqual(editor.presentedURLs, [clicked.url])
        XCTAssertEqual(revealer.revealedURLs, [clicked.url])
    }

    func testOpenPresentsScreenshotInInternalFullSizeWindow() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("preview.png")
        try makePNG(width: 1200, height: 500, color: .systemBlue).write(to: url)
        let controller = try XCTUnwrap(ScreenshotPreviewWindowController(imageURL: url))

        controller.showWindow()

        XCTAssertTrue(controller.window?.isVisible == true)
        XCTAssertEqual(controller.window?.title, "Скриншот — Note Island")
        XCTAssertNotNil(controller.window?.contentView)
        controller.close()
    }

    func testClosingPreviewReleasesPresentersStrongWindowReference() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("preview-lifetime.png")
        try makePNG(width: 120, height: 80, color: .systemGreen).write(to: url)
        let presenter = SystemScreenshotEditorPresenter()

        presenter.open(imageURL: url)
        let window = try XCTUnwrap(presenter.activePreviewWindow)
        XCTAssertTrue(window.isVisible)

        window.close()

        XCTAssertNil(presenter.activePreviewWindow)
    }

    func testGroupOpenAndEditRetainIndependentWindowsUntilEachCloses() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let urls = try (0..<2).map { index -> URL in
            let url = directory.appendingPathComponent("window-\(index).png")
            try makePNG(width: 120, height: 80, color: index == 0 ? .red : .green).write(to: url)
            return url
        }
        let presenter = SystemScreenshotEditorPresenter()

        urls.forEach { presenter.open(imageURL: $0) }
        XCTAssertEqual(presenter.activePreviewWindows.count, 2)
        presenter.activePreviewWindows[0].close()
        XCTAssertEqual(presenter.activePreviewWindows.count, 1)
        presenter.activePreviewWindows[0].close()
        XCTAssertTrue(presenter.activePreviewWindows.isEmpty)

        urls.forEach { url in
            presenter.present(imageURL: url, onSave: { _ in }, onCopy: { _ in })
        }
        XCTAssertEqual(presenter.activeEditorWindows.count, 2)
        presenter.activeEditorWindows.forEach { $0.close() }
        XCTAssertTrue(presenter.activeEditorWindows.isEmpty)
    }

    func testSystemPasteboardWritesOneImageItemPerSelectedScreenshot() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let urls = try (0..<2).map { index -> URL in
            let url = directory.appendingPathComponent("clipboard-group-\(index).png")
            try makePNG(width: 32, height: 24, color: index == 0 ? .red : .green).write(to: url)
            return url
        }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("NoteIslandTests-\(UUID().uuidString)"))
        defer { pasteboard.clearContents() }
        let systemPasteboard = SystemScreenshotPasteboard(pasteboard: pasteboard)

        XCTAssertTrue(systemPasteboard.writeImages(at: urls))
        XCTAssertEqual(pasteboard.pasteboardItems?.count, urls.count)
    }

    func testSystemLibraryDeleteUsesRecoverableTrashBoundary() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = SystemScreenshotLibrary(directory: directory)
        let item = try library.storePNG(try bluePNG())

        let trashedURL = try XCTUnwrap(library.trash(item.url))
        defer { try? FileManager.default.removeItem(at: trashedURL) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: item.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashedURL.path))
    }

    func testLibraryFailureIsVisibleAndRetryCanRecover() {
        let library = TestScreenshotLibrary()
        library.error = TestMediaError.scanFailed
        let store = ScreenshotsStore(library: library, pasteboard: TestScreenshotPasteboard())
        XCTAssertEqual(store.errorMessage, "Не удалось прочитать тестовую папку")

        library.error = nil
        library.items = [sampleScreenshot(name: "Screenshot recovered.png", time: 3)]
        store.reload()

        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.screenshots.count, 1)
    }

    func testScreenshotsViewRendersThumbnailAndPreviewOnInitialDisplayPass() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let screenshotURL = directory.appendingPathComponent("Screenshot preview.png")
        try writePNG(to: screenshotURL)
        let item = ScreenshotItem(
            url: screenshotURL,
            createdAt: Date(timeIntervalSince1970: 100),
            fileSize: 100
        )
        let filledLibrary = TestScreenshotLibrary(directory: directory)
        filledLibrary.items = [item]
        let filledStore = ScreenshotsStore(library: filledLibrary, pasteboard: TestScreenshotPasteboard())
        let emptyStore = ScreenshotsStore(library: TestScreenshotLibrary(), pasteboard: TestScreenshotPasteboard())

        let filled = try renderMediaView(ScreenshotsView(screenshots: filledStore))
        let empty = try renderMediaView(ScreenshotsView(screenshots: emptyStore))

        XCTAssertGreaterThan(changedPixelCount(filled, empty), 150)
    }

    func testDynamicallyInsertedScreenshotsRemainPhysicallyHitTestable() throws {
        let library = TestScreenshotLibrary()
        let original = (0..<3).map {
            sampleScreenshot(name: "original-\($0).png", time: TimeInterval((3 - $0) * 3_600))
        }
        library.items = original
        let store = ScreenshotsStore(library: library, pasteboard: TestScreenshotPasteboard())
        let hostingView = NSHostingView(
            rootView: ScreenshotsView(screenshots: store)
                .frame(width: 560, height: 330)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 560, height: 330)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.setContentSize(NSSize(width: 560, height: 330))
        hostingView.frame = NSRect(x: 0, y: 0, width: 560, height: 330)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let inserted = (0..<6).map {
            sampleScreenshot(name: "inserted-\($0).png", time: TimeInterval((20 - $0) * 3_600))
        }
        library.items = inserted + original
        store.reload()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        hostingView.layoutSubtreeIfNeeded()

        let interactions = descendantViews(of: hostingView)
            .compactMap { $0 as? ScreenshotGridInteractionNSView }
        let interaction = try XCTUnwrap(interactions.first)
        XCTAssertEqual(interactions.count, 1)
        XCTAssertEqual(interaction.items.map(\.id), store.screenshots.map(\.id))

        for (index, item) in interaction.items.enumerated() {
            let frame = ScreenshotGridLayout.cardFrame(index: index, containerWidth: interaction.bounds.width)
            let localCenter = NSPoint(x: frame.midX, y: frame.midY)
            let hostingCenter = hostingView.convert(localCenter, from: interaction)
            XCTAssertTrue(
                hostingView.hitTest(hostingCenter) === interaction,
                "Every visible card center must route to the single grid interaction view"
            )
            let windowPoint = interaction.convert(localCenter, to: nil)
            let down = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: windowPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: index * 2 + 1,
                clickCount: 1,
                pressure: 1
            ))
            let up = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: windowPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: index * 2 + 2,
                clickCount: 1,
                pressure: 0
            ))
            interaction.mouseDown(with: down)
            interaction.mouseUp(with: up)
            XCTAssertEqual(store.selectedID, item.id)
        }
    }

    func testGridInteractionRoutesShiftDoubleClickAndContextMenuByPhysicalCard() throws {
        let library = TestScreenshotLibrary()
        let items = (0..<8).map {
            sampleScreenshot(name: "grid-route-\($0).png", time: TimeInterval(100 - $0))
        }
        library.items = items
        let store = ScreenshotsStore(library: library, pasteboard: TestScreenshotPasteboard())
        let interaction = ScreenshotGridInteractionNSView(
            frame: NSRect(x: 0, y: 0, width: 536, height: 185)
        )
        interaction.items = store.screenshots
        interaction.isSelected = { store.selectedIDs.contains($0.id) }
        interaction.actionCount = { store.actionItems(containing: $0).count }
        interaction.isCopied = { store.copiedIDs.contains($0.id) }
        interaction.selectAction = { store.select($0, extendingSelection: $1) }
        interaction.toggleAction = { store.toggleSelection($0) }
        interaction.prepareActions = { store.prepareActions(for: $0) }
        interaction.dragURLs = { store.dragURLs(containing: $0) }
        var openedIDs: [String] = []
        interaction.openAction = { openedIDs = store.actionItems(containing: $0).map(\.id) }
        let window = NSWindow(
            contentRect: interaction.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = interaction

        func event(
            _ type: NSEvent.EventType,
            index: Int,
            modifiers: NSEvent.ModifierFlags = [],
            clickCount: Int = 1
        ) throws -> NSEvent {
            let frame = ScreenshotGridLayout.cardFrame(index: index, containerWidth: interaction.bounds.width)
            let localPoint = NSPoint(x: frame.midX, y: frame.midY)
            return try XCTUnwrap(NSEvent.mouseEvent(
                with: type,
                location: interaction.convert(localPoint, to: nil),
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: Int.random(in: 1...Int.max / 2),
                clickCount: clickCount,
                pressure: type == .leftMouseDown ? 1 : 0
            ))
        }

        interaction.mouseDown(with: try event(.leftMouseDown, index: 1))
        interaction.mouseUp(with: try event(.leftMouseUp, index: 1))
        interaction.mouseDown(with: try event(.leftMouseDown, index: 6, modifiers: [.command]))
        interaction.mouseUp(with: try event(.leftMouseUp, index: 6, modifiers: [.command]))
        interaction.mouseDown(with: try event(.leftMouseDown, index: 3, modifiers: [.command]))
        interaction.mouseUp(with: try event(.leftMouseUp, index: 3, modifiers: [.command]))
        XCTAssertEqual(store.selectedIDs, [items[1].id, items[3].id, items[6].id])
        interaction.mouseDown(with: try event(.leftMouseDown, index: 6, modifiers: [.command]))
        interaction.mouseUp(with: try event(.leftMouseUp, index: 6, modifiers: [.command]))
        XCTAssertEqual(store.selectedIDs, [items[1].id, items[3].id])

        store.select(items[1])
        interaction.mouseDown(with: try event(.leftMouseDown, index: 5, modifiers: [.shift]))
        interaction.mouseUp(with: try event(.leftMouseUp, index: 5, modifiers: [.shift]))
        XCTAssertEqual(store.selectedIDs, Set(store.screenshots[1...5].map(\.id)))
        XCTAssertEqual(store.selectedID, store.screenshots[5].id)

        interaction.mouseDown(with: try event(.leftMouseDown, index: 3))
        interaction.mouseUp(with: try event(.leftMouseUp, index: 3))
        interaction.mouseDown(with: try event(.leftMouseDown, index: 3, clickCount: 2))
        interaction.mouseUp(with: try event(.leftMouseUp, index: 3, clickCount: 2))
        XCTAssertEqual(openedIDs, store.screenshots[1...5].map(\.id))
        XCTAssertEqual(store.selectedIDs, Set(store.screenshots[1...5].map(\.id)))

        let groupedMenu = try XCTUnwrap(interaction.menu(for: try event(.rightMouseDown, index: 3)))
        XCTAssertEqual(groupedMenu.items.first?.title, "Открыть (5)")

        let singleMenu = try XCTUnwrap(interaction.menu(for: try event(.rightMouseDown, index: 7)))
        XCTAssertEqual(store.selectedIDs, [store.screenshots[7].id])
        XCTAssertEqual(singleMenu.items.first?.title, "Открыть")
    }

    func testMixedAspectRatioScreenshotsRenderAsEqualThumbnailCards() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixtures: [(String, CGFloat, CGFloat, NSColor)] = [
            ("wide.png", 1_200, 100, .red),
            ("portrait.png", 100, 1_200, .green),
            ("square.png", 400, 400, .blue),
            ("standard.png", 800, 600, .yellow)
        ]
        let library = TestScreenshotLibrary(directory: directory)
        for (index, fixture) in fixtures.enumerated() {
            let url = directory.appendingPathComponent(fixture.0)
            try makePNG(width: fixture.1, height: fixture.2, color: fixture.3).write(to: url)
            library.items.append(
                ScreenshotItem(
                    url: url,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(fixtures.count - index)),
                    fileSize: 100
                )
            )
        }
        let store = ScreenshotsStore(library: library, pasteboard: TestScreenshotPasteboard())

        let bitmap = try renderMediaView(ScreenshotsView(screenshots: store))
        let bounds = try fixtures.map { fixture in
            try XCTUnwrap(colorBounds(in: bitmap, matching: fixture.3), "Missing thumbnail color \(fixture.3)")
        }
        let widths = bounds.map(\.width)
        let heights = bounds.map(\.height)

        XCTAssertLessThanOrEqual((widths.max() ?? 0) - (widths.min() ?? 0), 10)
        XCTAssertLessThanOrEqual((heights.max() ?? 0) - (heights.min() ?? 0), 10)
    }

    func testShiftRangeRendersEverySelectedThumbnailWithSelectionBorder() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let colors: [NSColor] = [.systemRed, .systemGreen, .systemYellow, .systemPurple]
        let library = TestScreenshotLibrary(directory: directory)
        for (index, color) in colors.enumerated() {
            let url = directory.appendingPathComponent("selection-\(index).png")
            try makePNG(width: 120, height: 80, color: color).write(to: url)
            library.items.append(ScreenshotItem(
                url: url,
                createdAt: Date(timeIntervalSince1970: TimeInterval(colors.count - index)),
                fileSize: 100
            ))
        }
        let store = ScreenshotsStore(library: library, pasteboard: TestScreenshotPasteboard())
        store.select(library.items[0])
        store.select(library.items[2], extendingSelection: true)

        let bitmap = try renderMediaView(ScreenshotsView(screenshots: store))

        XCTAssertGreaterThanOrEqual(horizontalColorClusterCount(
            in: bitmap,
            matching: NSColor(NoteColor.sky.color)
        ), 3)
    }

    func testBuiltInEditorRotatesAndCropsWithoutLaunchingAnotherApp() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("editor.png")
        try makePNG(width: 20, height: 10).write(to: url)
        let model = try XCTUnwrap(ScreenshotEditorModel(url: url))
        let original = try XCTUnwrap(NSImage(data: try XCTUnwrap(model.renderedPNG())))

        model.rotate(clockwise: true)
        var edited = try XCTUnwrap(NSImage(data: try XCTUnwrap(model.renderedPNG())))
        XCTAssertEqual(Int(edited.size.width), Int(original.size.height))
        XCTAssertEqual(Int(edited.size.height), Int(original.size.width))
        let rotatedSize = edited.size

        model.setCropSelection(CGRect(x: 0, y: 0, width: 0.5, height: 1))
        model.applyCrop()
        edited = try XCTUnwrap(NSImage(data: try XCTUnwrap(model.renderedPNG())))
        XCTAssertEqual(Int(edited.size.width), Int(rotatedSize.width / 2))
        XCTAssertEqual(Int(edited.size.height), Int(rotatedSize.height))
    }

    func testEditorUndoRestoresDrawingAfterFlatteningTransform() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("undo.png")
        try makePNG(width: 40, height: 30).write(to: url)
        let model = try XCTUnwrap(ScreenshotEditorModel(url: url))
        model.beginStroke(at: CGPoint(x: 0.1, y: 0.2))
        model.appendStrokePoint(CGPoint(x: 0.9, y: 0.8))
        let beforeTransform = try XCTUnwrap(model.renderedPNG())

        model.rotate(clockwise: true)
        model.undo()

        XCTAssertEqual(model.strokes.count, 1)
        XCTAssertEqual(model.renderedPNG(), beforeTransform)
    }

    func testEditorEraserRemovesOnlyTouchedStrokeAndSupportsUndo() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("eraser.png")
        try makePNG(width: 80, height: 60).write(to: url)
        let model = try XCTUnwrap(ScreenshotEditorModel(url: url))
        model.beginStroke(at: CGPoint(x: 0.1, y: 0.1))
        model.appendStrokePoint(CGPoint(x: 0.3, y: 0.3))
        model.beginStroke(at: CGPoint(x: 0.7, y: 0.7))
        model.appendStrokePoint(CGPoint(x: 0.9, y: 0.9))

        model.mode = .erase
        model.beginErasing(at: CGPoint(x: 0.2, y: 0.2))

        XCTAssertEqual(model.strokes.count, 1)
        XCTAssertEqual(model.strokes.first?.points.first, CGPoint(x: 0.7, y: 0.7))

        model.undo()
        XCTAssertEqual(model.strokes.count, 2)
    }

    func testEditorExposesIconToolModesIncludingEraser() {
        XCTAssertEqual(ScreenshotEditorMode.allCases, [.draw, .erase, .crop])
    }

    private func sampleScreenshot(name: String, time: TimeInterval) -> ScreenshotItem {
        ScreenshotItem(
            url: temporaryDirectory().appendingPathComponent(name),
            createdAt: Date(timeIntervalSince1970: time),
            fileSize: 100
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func writePNG(to url: URL) throws {
        try bluePNG().write(to: url)
    }

    private func bluePNG() throws -> Data {
        try makePNG(width: 8, height: 8)
    }

    private func makePNG(width: CGFloat, height: CGFloat, color: NSColor = .systemBlue) throws -> Data {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        let data = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func mouseEvent(
        type: NSEvent.EventType,
        modifiers: NSEvent.ModifierFlags = [],
        clickCount: Int = 1
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: CGPoint(x: 20, y: 20),
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: Int.random(in: 1...Int.max / 2),
            clickCount: clickCount,
            pressure: type == .leftMouseDown ? 1 : 0
        ))
    }

}

@MainActor
private func renderMediaView<V: SwiftUI.View>(_ view: V) throws -> NSBitmapImageRep {
    try renderMediaView(view, afterInitialLayout: {})
}

@MainActor
private func renderMediaView<V: SwiftUI.View>(
    _ view: V,
    afterInitialLayout: () -> Void
) throws -> NSBitmapImageRep {
    let hostingView = NSHostingView(rootView: view)
    hostingView.frame = NSRect(x: 0, y: 0, width: 560, height: 330)
    hostingView.layoutSubtreeIfNeeded()
    afterInitialLayout()
    RunLoop.current.run(until: Date().addingTimeInterval(0.03))
    hostingView.layoutSubtreeIfNeeded()
    guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
        throw NSError(domain: "MediaTests", code: 20)
    }
    hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
    return bitmap
}

private func changedPixelCount(_ first: NSBitmapImageRep, _ second: NSBitmapImageRep) -> Int {
    var count = 0
    for x in 0..<min(first.pixelsWide, second.pixelsWide) {
        for y in 0..<min(first.pixelsHigh, second.pixelsHigh) {
            guard let a = first.colorAt(x: x, y: y), let b = second.colorAt(x: x, y: y) else { continue }
            let delta = abs(a.redComponent - b.redComponent)
                + abs(a.greenComponent - b.greenComponent)
                + abs(a.blueComponent - b.blueComponent)
            if delta > 0.15 { count += 1 }
        }
    }
    return count
}

@MainActor private func descendantViews(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendantViews(of: $0) }
}

private func colorBounds(in bitmap: NSBitmapImageRep, matching color: NSColor) -> CGRect? {
    guard let target = color.usingColorSpace(.deviceRGB) else { return nil }
    var minX = bitmap.pixelsWide
    var minY = bitmap.pixelsHigh
    var maxX = -1
    var maxY = -1
    for x in 0..<bitmap.pixelsWide {
        for y in 0..<bitmap.pixelsHigh {
            guard let sample = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            let distance = abs(sample.redComponent - target.redComponent)
                + abs(sample.greenComponent - target.greenComponent)
                + abs(sample.blueComponent - target.blueComponent)
            guard distance < 0.45, sample.alphaComponent > 0.8 else { continue }
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

private func horizontalColorClusterCount(in bitmap: NSBitmapImageRep, matching color: NSColor) -> Int {
    guard let target = color.usingColorSpace(.deviceRGB) else { return 0 }
    let matchingColumns = (0..<bitmap.pixelsWide).map { x in
        (0..<bitmap.pixelsHigh).contains { y in
            guard let sample = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            let distance = abs(sample.redComponent - target.redComponent)
                + abs(sample.greenComponent - target.greenComponent)
                + abs(sample.blueComponent - target.blueComponent)
            return distance < 0.3 && sample.alphaComponent > 0.8
        }
    }
    var clusters = 0
    var insideCluster = false
    for matches in matchingColumns {
        if matches && !insideCluster { clusters += 1 }
        insideCluster = matches
    }
    return clusters
}

enum TestMediaError: LocalizedError {
    case startFailed
    case stopFailed
    case runtimeFailed
    case scanFailed
    case trashFailed

    var errorDescription: String? {
        switch self {
        case .startFailed: "Не удалось начать тестовую запись"
        case .stopFailed: "Не удалось сохранить тестовую запись"
        case .runtimeFailed: "Тестовая запись неожиданно остановилась"
        case .scanFailed: "Не удалось прочитать тестовую папку"
        case .trashFailed: "Не удалось переместить тестовый файл в Корзину"
        }
    }
}

@MainActor
final class TestRecordingCapture: RecordingCapturing {
    var onFailure: (@MainActor @Sendable (Error) -> Void)?
    var startResult: Result<Void, Error> = .success(())
    var stopResult: Result<Void, Error> = .success(())
    var completesStopAutomatically = true
    private(set) var startedKinds: [RecordingKind] = []
    private(set) var activeURL: URL?
    private var pendingStopCompletion: (@MainActor @Sendable (Result<Void, Error>) -> Void)?

    func start(
        kind: RecordingKind,
        outputURL: URL,
        completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
    ) {
        startedKinds.append(kind)
        activeURL = outputURL
        completion(startResult)
    }

    func stop(completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void) {
        guard completesStopAutomatically else {
            pendingStopCompletion = completion
            return
        }
        finishStop(completion: completion)
    }

    func completePendingStop() {
        guard let completion = pendingStopCompletion else { return }
        pendingStopCompletion = nil
        finishStop(completion: completion)
    }

    private func finishStop(
        completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
    ) {
        if case .success = stopResult, let activeURL {
            try? FileManager.default.createDirectory(at: activeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("test recording".utf8).write(to: activeURL)
        }
        completion(stopResult)
    }

    func sendRuntimeFailure(_ error: Error) {
        onFailure?(error)
    }
}

@MainActor
final class TestScreenshotLibrary: ScreenshotLibraryProviding {
    let directory: URL
    var items: [ScreenshotItem] = []
    var error: Error?
    var trashErrors: [URL: Error] = [:]
    private(set) var trashedURLs: [URL] = []
    private(set) var storedPNGs: [Data] = []
    private(set) var replacements: [(URL, Data)] = []

    init(directory: URL = FileManager.default.temporaryDirectory) {
        self.directory = directory
    }

    func screenshots() throws -> [ScreenshotItem] {
        if let error { throw error }
        return items.sorted { $0.createdAt > $1.createdAt }
    }

    func storePNG(_ data: Data) throws -> ScreenshotItem {
        storedPNGs.append(data)
        let url = directory.appendingPathComponent("clipboard-\(storedPNGs.count).png")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url)
        let item = ScreenshotItem(url: url, createdAt: Date(), fileSize: Int64(data.count))
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        return item
    }

    func importImage(at url: URL) throws -> ScreenshotItem {
        try storePNG(Data(contentsOf: url))
    }

    func replace(_ url: URL, withPNG data: Data) throws {
        replacements.append((url, data))
    }

    func trash(_ url: URL) throws -> URL? {
        if let error = trashErrors[url] { throw error }
        trashedURLs.append(url)
        items.removeAll { $0.url == url }
        return nil
    }
}

@MainActor
final class TestScreenshotPasteboard: ScreenshotPasteboardProviding {
    var changeCount = 0
    var imagePNG: Data?
    var writeResult = true
    private(set) var copiedURLs: [URL] = []

    func readImagePNG() -> Data? { imagePNG }

    func writeImages(at urls: [URL]) -> Bool {
        guard writeResult else { return false }
        copiedURLs.append(contentsOf: urls)
        changeCount += 1
        return !urls.isEmpty
    }

    func simulateNewImage(_ data: Data) {
        imagePNG = data
        changeCount += 1
    }
}

@MainActor
final class TestScreenshotEditorPresenter: ScreenshotEditorPresenting {
    private(set) var presentedURLs: [URL] = []
    private(set) var openedURLs: [URL] = []
    private var saveActions: [URL: (Data) -> Void] = [:]
    private var copyActions: [URL: (Data) -> Void] = [:]

    func open(imageURL: URL) {
        openedURLs.append(imageURL)
    }

    func present(
        imageURL: URL,
        onSave: @escaping (Data) -> Void,
        onCopy: @escaping (Data) -> Void
    ) {
        presentedURLs.append(imageURL)
        saveActions[imageURL] = onSave
        copyActions[imageURL] = onCopy
    }

    func save(_ data: Data, for url: URL) {
        saveActions[url]?(data)
    }
}

@MainActor
final class TestScreenshotFileRevealer: ScreenshotFileRevealing {
    private(set) var revealedURLs: [URL] = []

    func reveal(_ urls: [URL]) {
        revealedURLs.append(contentsOf: urls)
    }
}
