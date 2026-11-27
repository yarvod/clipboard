import Foundation

enum AppInfo {
    static let name = "ClipboardCommander"
    static let defaultMaxItems = 20

    /// Сколько записей хранить. Можно поменять без пересборки:
    /// `defaults write com.yarvod.clipboardcommander MaxItems -int 30`
    static var maxItems: Int {
        let custom = UserDefaults.standard.integer(forKey: "MaxItems")
        return custom > 0 ? min(custom, 200) : defaultMaxItems
    }

    /// `~/Library/Application Support/ClipboardCommander`.
    /// Для разработки можно подменить: `CLIPBOARD_COMMANDER_DATA_DIR=/tmp/cc ./ClipboardCommander`.
    static let supportDir: URL = {
        if let custom = ProcessInfo.processInfo.environment["CLIPBOARD_COMMANDER_DATA_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
    }()
    /// Содержимое записей: текст в `.txt`, картинки в `.png` / `.jpg`.
    static let itemsDir = supportDir.appendingPathComponent("items", isDirectory: true)
    /// Маленькие превью картинок для списка.
    static let thumbsDir = supportDir.appendingPathComponent("thumbs", isDirectory: true)
    static let indexURL = supportDir.appendingPathComponent("index.json")
    /// История старой версии на Python (PySide6).
    static let legacyIndexURL = supportDir.appendingPathComponent("history.json")
}

struct SourceApp: Sendable, Equatable {
    var name: String?
    var bundleID: String?
}

struct ClipItem: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case text
        case image
    }

    let id: UUID
    let kind: Kind
    var date: Date
    /// Имя файла с содержимым в `items/`.
    let file: String
    /// SHA-256 содержимого: по нему находим повторы.
    let hash: String
    let byteCount: Int
    /// Начало текста: для списка и поиска (сам текст лежит в файле).
    var preview: String = ""
    var charCount: Int?
    var lineCount: Int?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var imageType: String?
    var thumbFile: String?
    var sourceName: String?
    var sourceBundleID: String?

    var title: String {
        switch kind {
        case .text:
            let firstLine = preview
                .split(whereSeparator: \.isNewline)
                .lazy
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
            return firstLine.map { String($0.prefix(300)) } ?? "Пробелы"
        case .image:
            guard let width = pixelWidth, let height = pixelHeight else { return "Изображение" }
            return "Изображение \(width) × \(height)"
        }
    }

    var source: SourceApp {
        SourceApp(name: sourceName, bundleID: sourceBundleID)
    }
}
