import AppKit
import Carbon
import SwiftUI

/// Плавающая панель в стиле Spotlight.
///
/// `.nonactivatingPanel` даёт печатать в поле поиска, не забирая фокус у программы,
/// в которой работал пользователь, — поэтому ⌘V после выбора попадает именно туда.
final class PickerPanel: NSPanel {
    var onResignKey: (() -> Void)?

    init(size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .utilityWindow
        minSize = NSSize(width: 620, height: 380)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

@MainActor
final class PickerModel: ObservableObject {
    @Published var query = "" {
        didSet {
            if query != oldValue { selection = filtered.first?.id }
        }
    }
    @Published var selection: UUID?
    @Published private(set) var focusRequest = 0
    @Published private(set) var autoPasteEnabled = Paster.canAutoPaste

    let store: HistoryStore
    var onChoose: ((ClipItem, Bool) -> Void)?
    var onReveal: ((ClipItem) -> Void)?

    init(store: HistoryStore) {
        self.store = store
    }

    var filtered: [ClipItem] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return store.items }
        return store.items.filter { item in
            if item.preview.localizedCaseInsensitiveContains(needle) { return true }
            if item.sourceName?.localizedCaseInsensitiveContains(needle) == true { return true }
            if item.kind == .image {
                let words = "изображение картинка скриншот снимок image picture screenshot \(item.title)"
                return words.localizedCaseInsensitiveContains(needle)
            }
            return false
        }
    }

    func selectedItem(in items: [ClipItem]) -> ClipItem? {
        items.first { $0.id == selection } ?? items.first
    }

    func prepareForShow() {
        query = ""
        selection = store.items.first?.id
        autoPasteEnabled = Paster.canAutoPaste
    }

    func requestFocus() {
        focusRequest &+= 1
    }

    func move(by delta: Int) {
        let items = filtered
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selectedItem(in: items)?.id } ?? 0
        let next = min(max(current + delta, 0), items.count - 1)
        selection = items[next].id
    }

    func chooseSelected(paste: Bool) {
        guard let item = selectedItem(in: filtered) else {
            NSSound.beep()
            return
        }
        choose(item, paste: paste)
    }

    func choose(index: Int, paste: Bool) {
        let items = filtered
        guard items.indices.contains(index) else {
            NSSound.beep()
            return
        }
        choose(items[index], paste: paste)
    }

    func choose(_ item: ClipItem, paste: Bool) {
        onChoose?(item, paste)
    }

    func reveal(_ item: ClipItem) {
        onReveal?(item)
    }

    func deleteSelected() {
        guard let item = selectedItem(in: filtered) else { return }
        delete(item)
    }

    func delete(_ item: ClipItem) {
        let before = filtered
        let index = before.firstIndex(of: item) ?? 0
        store.remove(item.id)
        let after = filtered
        selection = after.isEmpty ? nil : after[min(index, after.count - 1)].id
    }
}

@MainActor
final class PickerController {
    let model: PickerModel
    private let store: HistoryStore
    private lazy var panel: PickerPanel = makePanel()
    private var keyMonitor: Any?
    private var isHiding = false
    private var askedForAccessibility = false

    private static let digitKeys: [Int: Int] = [
        kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4, kVK_ANSI_5: 5,
        kVK_ANSI_6: 6, kVK_ANSI_7: 7, kVK_ANSI_8: 8, kVK_ANSI_9: 9,
    ]

    init(store: HistoryStore) {
        self.store = store
        model = PickerModel(store: store)
        model.onChoose = { [weak self] item, paste in self?.choose(item, paste: paste) }
        model.onReveal = { [weak self] item in self?.reveal(item) }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        model.prepareForShow()
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        model.requestFocus()
    }

    func hide() {
        guard panel.isVisible, !isHiding else { return }
        isHiding = true
        removeKeyMonitor()
        panel.orderOut(nil)
        isHiding = false
    }

    // MARK: - Действия

    private func choose(_ item: ClipItem, paste: Bool) {
        guard Paster.copy(item, store: store) else {
            NSSound.beep()
            return
        }
        store.touch(item.id)
        hide()
        guard paste else { return }
        if Paster.canAutoPaste {
            // Даём панели исчезнуть, затем жмём ⌘V в программе, где был курсор.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                Paster.sendPasteShortcut()
            }
        } else if !askedForAccessibility {
            askedForAccessibility = true
            Paster.requestAccessibility()
        }
    }

    private func reveal(_ item: ClipItem) {
        hide()
        NSWorkspace.shared.activateFileViewerSelecting([store.fileURL(item)])
    }

    // MARK: - Окно

    private func makePanel() -> PickerPanel {
        let panel = PickerPanel(size: NSSize(width: 780, height: 480))
        panel.onResignKey = { [weak self] in self?.hide() }

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active

        let hosting = NSHostingView(rootView: PickerView(model: model, store: store))
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: background.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        return panel
    }

    /// По центру экрана, где сейчас курсор, чуть выше середины — как Spotlight.
    private func positionPanel() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let x = frame.midX - size.width / 2
        let y = max(frame.minY, frame.maxY - size.height - frame.height * 0.16)
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }

    // MARK: - Клавиатура

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = Int(event.keyCode)
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.panel.isKeyWindow else { return false }
                return self.handleKey(keyCode: keyCode, command: flags.contains(.command))
            }
            return handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    /// Возвращает `true`, если нажатие обработано и дальше в поле поиска не идёт.
    private func handleKey(keyCode: Int, command: Bool) -> Bool {
        switch keyCode {
        case kVK_DownArrow:
            model.move(by: 1)
        case kVK_UpArrow:
            model.move(by: -1)
        case kVK_PageDown:
            model.move(by: 6)
        case kVK_PageUp:
            model.move(by: -6)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            model.chooseSelected(paste: !command)
        case kVK_Escape:
            if model.query.isEmpty { hide() } else { model.query = "" }
        case kVK_Delete where command:
            model.deleteSelected()
        case kVK_ANSI_W where command:
            hide()
        default:
            guard command, let digit = Self.digitKeys[keyCode] else { return false }
            model.choose(index: digit - 1, paste: true)
        }
        return true
    }
}
