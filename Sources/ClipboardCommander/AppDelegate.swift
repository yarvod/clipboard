import AppKit
import Carbon
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store: HistoryStore
    private let monitor: ClipboardMonitor
    private let picker: PickerController
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?

    override init() {
        store = HistoryStore()
        monitor = ClipboardMonitor(store: store)
        picker = PickerController(store: store)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMainMenu()
        setUpStatusItem()
        monitor.start()
        hotKey = HotKey(keyCode: kVK_ANSI_V, modifiers: cmdKey | shiftKey) { [weak self] in
            self?.picker.toggle()
        }
        if hotKey == nil {
            NSLog("ClipboardCommander: не удалось занять ⌘⇧V — сочетание использует другая программа")
        }
    }

    /// Повторный запуск (двойной клик по программе) открывает историю.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        picker.show()
        return false
    }

    /// `clipboardcommander://open` — открыть историю из Shortcuts, Raycast, скриптов.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "clipboardcommander" {
            picker.show()
        }
    }

    // MARK: - Строка меню

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: AppInfo.name)
            image?.isTemplate = true
            button.image = image
            button.toolTip = "\(AppInfo.name) — ⌘⇧V"
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let open = NSMenuItem(title: "Открыть историю", action: #selector(openPicker), keyEquivalent: "v")
        open.keyEquivalentModifierMask = [.command, .shift]
        open.target = self
        menu.addItem(open)

        let recent = store.items.prefix(5)
        if !recent.isEmpty {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem.sectionHeader(title: "Недавние"))
            for clip in recent {
                let title = clip.title.count > 48 ? String(clip.title.prefix(47)) + "…" : clip.title
                let entry = NSMenuItem(title: title, action: #selector(copyRecent(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = clip.id
                entry.image = AppIcons.menuIcon(for: clip)
                entry.toolTip = "Скопировать в буфер"
                menu.addItem(entry)
            }
        }

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Открывать при входе в систему", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        if !Paster.canAutoPaste {
            let access = NSMenuItem(title: "Разрешить автовставку…", action: #selector(requestAccessibility), keyEquivalent: "")
            access.target = self
            menu.addItem(access)
        }

        let folder = NSMenuItem(title: "Показать папку истории", action: #selector(showHistoryFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)

        let clear = NSMenuItem(title: "Очистить историю…", action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !store.items.isEmpty
        menu.addItem(clear)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "О программе \(AppInfo.name)", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    // MARK: - Команды

    @objc private func openPicker() {
        picker.show()
    }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let clip = store.items.first(where: { $0.id == id }),
              Paster.copy(clip, store: store)
        else { return }
        store.touch(id)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSApp.activate()
            let alert = NSAlert(error: error)
            alert.messageText = "Не удалось изменить автозапуск"
            alert.runModal()
        }
    }

    @objc private func requestAccessibility() {
        Paster.requestAccessibility()
    }

    @objc private func showHistoryFolder() {
        NSWorkspace.shared.open(AppInfo.supportDir)
    }

    @objc private func clearHistory() {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Очистить историю?"
        alert.informativeText = "Будут удалены все записи (\(store.items.count)) и сохранённые картинки. Отменить это нельзя."
        alert.addButton(withTitle: "Очистить")
        alert.addButton(withTitle: "Отмена")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn {
            store.clear()
        }
    }

    @objc private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    // MARK: - Главное меню

    /// Меню не видно (программа живёт в строке меню), но без него в поле поиска
    /// не работают ⌘C, ⌘V, ⌘A, ⌘Z.
    private static func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        appItem.submenu = NSMenu(title: AppInfo.name)
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Правка")
        edit.addItem(withTitle: "Отменить", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Повторить", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Скопировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Выбрать все", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        mainMenu.addItem(editItem)

        return mainMenu
    }
}
