import AppKit
import Carbon
import SwiftUI

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

enum IslandScreenGeometry {
    static let minimumCompactWidth: CGFloat = 244

    static func compactWidth(notchWidth: CGFloat?) -> CGFloat {
        guard let notchWidth else { return minimumCompactWidth }
        return max(minimumCompactWidth, notchWidth + 60)
    }

    static func frame(screenFrame: NSRect, size: NSSize) -> NSRect {
        NSRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }
}

@MainActor
final class IslandPresentationState: ObservableObject {
    @Published var isExpanded = false
    @Published var isWindowExpanded = false
    @Published var editorOpacity: Double = 0
    @Published var topInset: CGFloat = 0
    @Published var compactWidth: CGFloat = IslandScreenGeometry.minimumCompactWidth
    @Published var bodyFocusRequestID = 0
    @Published var mode: IslandMode

    init() {
        mode = IslandMode(rawValue: UserDefaults.standard.string(forKey: "island.mode") ?? "notes") ?? .notes
    }

    func selectMode(_ newMode: IslandMode) {
        guard mode != newMode else { return }
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: "island.mode")
        bodyFocusRequestID &+= 1
    }
}

@MainActor
final class IslandPanelController: NSObject {
    private let store: NoteStore
    private let translator: TranslatorStore
    private let meetings: MeetingsStore
    private let recordings: RecordingsStore
    private let screenshots: ScreenshotsStore
    private let presentation: IslandPresentationState
    private let panel: NSPanel
    private var hostingView: NSHostingView<IslandView>!
    private var currentScreen: NSScreen?
    private var lastExternalApplication: NSRunningApplication?
    private var expanded = false
    private var isTransitioning = false
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var hotKeyHandler: EventHandlerRef?
    private var activationObserver: NSObjectProtocol?
    private var screenChangeObserver: NSObjectProtocol?
    var onVisibilityChanged: ((Bool) -> Void)?

    override init() {
        store = NoteStore()
        translator = TranslatorStore()
        meetings = MeetingsStore()
        recordings = RecordingsStore()
        screenshots = ScreenshotsStore()
        presentation = IslandPresentationState()
        panel = IslandPanel(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
        observePanelScreenChanges()
        configureContent()
        observeExternalApplications()
        registerHotKey()
    }

    func show(expanded: Bool? = nil) {
        rememberFrontmostExternalApplication()
        if let expanded { self.expanded = expanded }
        presentation.isExpanded = self.expanded
        presentation.isWindowExpanded = self.expanded
        presentation.editorOpacity = self.expanded ? 1 : 0
        updateScreenContext()
        resize(animated: false)
        presentPanel()
        if self.expanded {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.expanded else { return }
                self.presentation.bodyFocusRequestID &+= 1
            }
        }
        onVisibilityChanged?(true)
    }

    func hide() {
        panel.orderOut(nil)
        releaseKeyboardFocus()
        onVisibilityChanged?(false)
    }

    func show(mode: IslandMode) {
        presentation.selectMode(mode)
        if panel.isVisible {
            if expanded {
                presentPanel()
                presentation.bodyFocusRequestID &+= 1
            } else {
                setExpanded(true)
            }
        } else {
            show(expanded: true)
        }
    }

    func toggleModeFromShortcut(_ mode: IslandMode) {
        if panel.isVisible, expanded, presentation.mode == mode {
            setExpanded(false)
        } else {
            show(mode: mode)
        }
    }

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
    }

    private func configureContent() {
        updateScreenContext()
        let root = IslandView(
            store: store,
            translator: translator,
            meetings: meetings,
            recordings: recordings,
            screenshots: screenshots,
            presentation: presentation,
            setExpanded: { [weak self] in self?.setExpanded($0) },
            dismiss: { [weak self] in self?.hide() }
        )
        hostingView = NSHostingView(rootView: root)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.isOpaque = false
        panel.contentView = hostingView
        hostingView.autoresizingMask = [.width, .height]
    }

    private func setExpanded(_ newValue: Bool) {
        guard expanded != newValue, !isTransitioning else { return }
        expanded = newValue
        isTransitioning = true
        updateScreenContext()
        presentation.isWindowExpanded = newValue

        if newValue {
            rememberFrontmostExternalApplication()
            presentation.isExpanded = true
            presentation.editorOpacity = 0
            resize(animated: true) { [weak self] in
                self?.isTransitioning = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                guard let self, self.expanded else { return }
                self.presentation.editorOpacity = 1
            }
        } else {
            presentation.editorOpacity = 0
            presentation.isExpanded = false
            resize(animated: true) { [weak self] in
                self?.isTransitioning = false
            }
        }
        presentPanel()
        if newValue {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.expanded else { return }
                self.presentation.bodyFocusRequestID &+= 1
            }
        } else {
            releaseKeyboardFocus()
        }
    }

    private func resize(animated: Bool, completion: (@MainActor @Sendable () -> Void)? = nil) {
        let compactHeight = presentation.topInset > 0 ? presentation.topInset : 32
        let height = expanded ? 388 : compactHeight
        let size = NSSize(
            width: expanded ? 560 : presentation.compactWidth,
            height: height
        )
        let frame = targetFrame(for: size)
        hostingView.frame = NSRect(origin: .zero, size: size)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
                panel.animator().setFrame(frame, display: true)
            } completionHandler: {
                DispatchQueue.main.async {
                    completion?()
                }
            }
        } else {
            panel.setFrame(frame, display: true)
            completion?()
        }
    }

    private func targetFrame(for size: NSSize) -> NSRect {
        let screen = currentScreen ?? NSScreen.screens.first ?? NSScreen.main!
        return IslandScreenGeometry.frame(screenFrame: screen.frame, size: size)
    }

    private func updateScreenContext(preferredScreen: NSScreen? = nil) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = preferredScreen
            ?? NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? panel.screen
            ?? NSScreen.screens.first
            ?? NSScreen.main!
        currentScreen = screen
        if let leftArea = screen.auxiliaryTopLeftArea, let rightArea = screen.auxiliaryTopRightArea {
            let notchWidth = max(0, rightArea.minX - leftArea.maxX)
            presentation.topInset = screen.safeAreaInsets.top
            presentation.compactWidth = IslandScreenGeometry.compactWidth(notchWidth: notchWidth)
        } else {
            presentation.topInset = 0
            presentation.compactWidth = IslandScreenGeometry.compactWidth(notchWidth: nil)
        }
    }

    private func observePanelScreenChanges() {
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let screen = self.panel.screen else { return }
                self.updateScreenContext(preferredScreen: screen)
                self.resize(animated: false)
            }
        }
    }

    private func presentPanel() {
        if expanded {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    private func rememberFrontmostExternalApplication() {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        lastExternalApplication = application
    }

    private func observeExternalApplications() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in
                guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                self?.lastExternalApplication = application
            }
        }
    }

    private func releaseKeyboardFocus() {
        panel.makeFirstResponder(nil)
        panel.resignKey()
        guard let current = NSWorkspace.shared.frontmostApplication,
              current.processIdentifier == ProcessInfo.processInfo.processIdentifier else { return }
        lastExternalApplication?.activate(options: [.activateAllWindows])
    }

    private func registerHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        let controllerPointer = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                let controller = Unmanaged<IslandPanelController>.fromOpaque(userData).takeUnretainedValue()
                var keyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &keyID
                )
                guard status == noErr, let mode = IslandMode(hotKeyID: keyID.id) else { return noErr }
                Task { @MainActor in controller.toggleModeFromShortcut(mode) }
                return noErr
            },
            1,
            &eventType,
            controllerPointer,
            &hotKeyHandler
        )
        let registrations: [(IslandMode, Int)] = [
            (.notes, kVK_ANSI_N),
            (.translator, kVK_ANSI_T),
            (.meetings, kVK_ANSI_M),
            (.recordings, kVK_ANSI_R),
            (.screenshots, kVK_ANSI_S)
        ]
        var registrationFailures: [String] = []
        for (mode, keyCode) in registrations {
            var hotKeyRef: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(keyCode),
                UInt32(cmdKey | shiftKey),
                EventHotKeyID(signature: OSType(0x4E49534C), id: mode.hotKeyID),
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )
            if status == noErr, let hotKeyRef {
                hotKeyRefs.append(hotKeyRef)
            } else {
                registrationFailures.append("\(mode.shortcutTitle): \(status)")
            }
        }
        if handlerStatus != noErr || !registrationFailures.isEmpty {
            NSLog(
                "NoteIsland hotkey registration failed (handler: %d, keys: %@). The menu bar remains available.",
                handlerStatus,
                registrationFailures.joined(separator: ", ")
            )
        }
    }
}

extension IslandMode {
    var hotKeyID: UInt32 {
        switch self {
        case .notes: 1
        case .translator: 2
        case .meetings: 3
        case .recordings: 4
        case .screenshots: 5
        }
    }

    init?(hotKeyID: UInt32) {
        switch hotKeyID {
        case 1: self = .notes
        case 2: self = .translator
        case 3: self = .meetings
        case 4: self = .recordings
        case 5: self = .screenshots
        default: return nil
        }
    }
}
