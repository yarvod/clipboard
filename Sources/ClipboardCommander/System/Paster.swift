import AppKit
import ApplicationServices
import UniformTypeIdentifiers

/// Кладёт запись в системный буфер и при наличии доступа нажимает ⌘V в активном приложении.
enum Paster {
    /// Держим ссылку, пока буфер может попросить TIFF.
    @MainActor private static var tiffProvider: TIFFProvider?

    @MainActor
    @discardableResult
    static func copy(_ item: ClipItem, store: HistoryStore) -> Bool {
        let pasteboardItem = NSPasteboardItem()
        switch item.kind {
        case .text:
            guard let text = store.fullText(item) else { return false }
            pasteboardItem.setString(text, forType: .string)
        case .image:
            guard let data = try? Data(contentsOf: store.fileURL(item), options: .mappedIfSafe) else { return false }
            let type = NSPasteboard.PasteboardType(item.imageType ?? UTType.png.identifier)
            pasteboardItem.setData(data, forType: type)
            // Старым программам нужен TIFF: отдаём его лениво, только если попросят.
            let provider = TIFFProvider(imageData: data)
            pasteboardItem.setDataProvider(provider, forTypes: [.tiff])
            tiffProvider = provider
        }
        pasteboardItem.setData(Data(), forType: ClipboardMonitor.ownType)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([pasteboardItem])
    }

    /// Нужен «Универсальный доступ», чтобы отправить ⌘V в другое приложение.
    static var canAutoPaste: Bool {
        AXIsProcessTrusted()
    }

    /// Показывает системный запрос доступа (и добавляет программу в список в настройках).
    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func sendPasteShortcut() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09 // физическая клавиша V, работает при любой раскладке
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

private final class TIFFProvider: NSObject, NSPasteboardItemDataProvider {
    private let imageData: Data

    init(imageData: Data) {
        self.imageData = imageData
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .tiff,
              let rep = NSBitmapImageRep(data: imageData),
              let tiff = rep.tiffRepresentation
        else { return }
        item.setData(tiff, forType: .tiff)
    }
}
