import AppKit

@MainActor
final class IslandOutsideClickMonitor {
    private weak var panel: NSWindow?
    private let shouldCollapse: () -> Bool
    private let collapse: () -> Void
    private var localMonitor: Any?
    private var globalMonitor: Any?

    init(panel: NSWindow, shouldCollapse: @escaping () -> Bool, collapse: @escaping () -> Void) {
        self.panel = panel
        self.shouldCollapse = shouldCollapse
        self.collapse = collapse
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
                self?.handleClick(at: point, eventWindow: event.window)
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleClick(at: NSEvent.mouseLocation, eventWindow: nil) }
        }
    }

    func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    func handleClick(at point: NSPoint, eventWindow: NSWindow?) {
        guard let panel, panel.isVisible, shouldCollapse(),
              Self.isOutside(panel, point: point, eventWindow: eventWindow) else { return }
        collapse()
    }

    static func isOutside(_ panel: NSWindow, point: NSPoint, eventWindow: NSWindow?) -> Bool {
        // A sheet owns the interaction until Save/Cancel. Its native date pickers and
        // context menus may extend past the panel's frame.
        guard panel.attachedSheet == nil, NSApp.modalWindow == nil else { return false }
        if eventWindow === panel || panel.frame.contains(point) { return false }
        if let eventWindow, eventWindow.level >= .popUpMenu { return false }
        var ancestor = eventWindow?.parent
        while let window = ancestor {
            if window === panel { return false }
            ancestor = window.parent
        }
        return true
    }
}
