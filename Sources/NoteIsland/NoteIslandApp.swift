import AppKit
import SwiftUI
@preconcurrency import UserNotifications

@main
struct NoteIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var islandController: IslandPanelController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self

        let controller = IslandPanelController()
        islandController = controller
        configureStatusItem(controller: controller)
        controller.show(expanded: false)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        islandController?.refreshMeetingNotificationAuthorization()
    }

    private func configureStatusItem(controller: IslandPanelController) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Note Island")
        item.button?.toolTip = "Note Island — ⌘⇧N / ⌘⇧T / ⌘⇧M / ⌘⇧R / ⌘⇧S"

        let menu = NSMenu()
        menu.addItem(withTitle: "Показать Note Island", action: #selector(showIsland), keyEquivalent: "")
        addModeItem(to: menu, title: "Заметки", action: #selector(showNotes), key: "n")
        addModeItem(to: menu, title: "Переводчик", action: #selector(showTranslator), key: "t")
        addModeItem(to: menu, title: "Встречи сегодня", action: #selector(showMeetings), key: "m")
        addModeItem(to: menu, title: "Записи", action: #selector(showRecordings), key: "r")
        addModeItem(to: menu, title: "Скриншоты", action: #selector(showScreenshots), key: "s")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Завершить Note Island", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func showIsland() {
        islandController?.show()
    }

    private func addModeItem(to menu: NSMenu, title: String, action: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = [.command, .shift] }
        item.target = self
        menu.addItem(item)
    }

    @objc private func showNotes() {
        islandController?.show(mode: .notes)
    }

    @objc private func showTranslator() {
        islandController?.show(mode: .translator)
    }

    @objc private func showMeetings() {
        islandController?.show(mode: .meetings)
    }

    @objc private func showRecordings() {
        islandController?.show(mode: .recordings)
    }

    @objc private func showScreenshots() {
        islandController?.show(mode: .screenshots)
    }
}

extension AppDelegate: @preconcurrency UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run {
            islandController?.show(mode: .meetings)
        }
    }
}
