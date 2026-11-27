import AppKit

/// История буфера: не больше `AppInfo.maxItems` записей.
///
/// В памяти лежат только метаданные (`index.json`), содержимое — в файлах `items/`.
/// Файлы вытесненных и удалённых записей удаляются сразу, «сироты» — при запуске.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var items: [ClipItem] = []

    private let fm = FileManager.default
    private let io = DispatchQueue(
        label: "com.yarvod.clipboardcommander.io",
        qos: .utility,
        autoreleaseFrequency: .workItem
    )

    init() {
        try? fm.createDirectory(at: AppInfo.itemsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: AppInfo.thumbsDir, withIntermediateDirectories: true)
        load()
        importLegacyIfNeeded()
        removeOrphanFiles()
    }

    // MARK: - Доступ к содержимому

    func fileURL(_ item: ClipItem) -> URL {
        AppInfo.itemsDir.appendingPathComponent(item.file)
    }

    func thumbURL(_ item: ClipItem) -> URL? {
        item.thumbFile.map { AppInfo.thumbsDir.appendingPathComponent($0) }
    }

    func fullText(_ item: ClipItem) -> String? {
        guard item.kind == .text else { return nil }
        return try? String(contentsOf: fileURL(item), encoding: .utf8)
    }

    // MARK: - Добавление

    func addText(_ text: String, source: SourceApp?) {
        let data = Data(text.utf8)
        let hash = Digest.sha256(data)
        if moveToTop(where: { $0.hash == hash }) { return }
        guard let item = makeTextItem(text, data: data, hash: hash, date: Date(), source: source) else { return }
        insert(item)
    }

    /// Картинка обрабатывается в фоне, чтобы не подвешивать интерфейс на больших скриншотах.
    func addImage(data: Data, uti: String, source: SourceApp?) {
        io.async { [weak self] in
            guard let processed = ImageProcessor.process(data, uti: uti) else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.finishImage(processed, source: source)
                }
            }
        }
    }

    private func finishImage(_ processed: ProcessedImage, source: SourceApp?) {
        let url = AppInfo.itemsDir.appendingPathComponent(processed.file)
        guard fm.fileExists(atPath: url.path) else { return }
        if moveToTop(where: { $0.hash == processed.hash }) {
            try? fm.removeItem(at: url)
            if let thumb = processed.thumbFile {
                try? fm.removeItem(at: AppInfo.thumbsDir.appendingPathComponent(thumb))
            }
            return
        }
        insert(makeImageItem(processed, date: Date(), source: source))
    }

    // MARK: - Изменение

    /// Поднимает запись наверх (например, после выбора в окне истории).
    func touch(_ id: UUID) {
        _ = moveToTop(where: { $0.id == id })
    }

    func remove(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: index)
        deleteFiles(of: item)
        save()
    }

    func clear() {
        items.forEach(deleteFiles)
        items.removeAll()
        save()
        removeOrphanFiles()
    }

    // MARK: - Внутреннее

    private func insert(_ item: ClipItem) {
        items.insert(item, at: 0)
        trimToLimit()
        save()
    }

    private func moveToTop(where predicate: (ClipItem) -> Bool) -> Bool {
        guard let index = items.firstIndex(where: predicate) else { return false }
        var item = items.remove(at: index)
        item.date = Date()
        items.insert(item, at: 0)
        save()
        return true
    }

    @discardableResult
    private func trimToLimit() -> Bool {
        let limit = AppInfo.maxItems
        guard items.count > limit else { return false }
        let removed = items[limit...]
        items.removeSubrange(limit...)
        removed.forEach(deleteFiles)
        return true
    }

    private func deleteFiles(of item: ClipItem) {
        try? fm.removeItem(at: fileURL(item))
        if let thumb = thumbURL(item) {
            try? fm.removeItem(at: thumb)
        }
        ImageLoader.shared.forget(item.id)
    }

    private func makeTextItem(_ text: String, data: Data, hash: String, date: Date, source: SourceApp?) -> ClipItem? {
        let id = UUID()
        let file = "\(id.uuidString).txt"
        do {
            try data.write(to: AppInfo.itemsDir.appendingPathComponent(file), options: .atomic)
        } catch {
            return nil
        }
        var item = ClipItem(id: id, kind: .text, date: date, file: file, hash: hash, byteCount: data.count)
        item.preview = String(text.prefix(2000))
        item.charCount = text.count
        item.lineCount = data.reduce(into: 1) { count, byte in if byte == 0x0A { count += 1 } }
        item.sourceName = source?.name
        item.sourceBundleID = source?.bundleID
        return item
    }

    private func makeImageItem(_ processed: ProcessedImage, date: Date, source: SourceApp?) -> ClipItem {
        var item = ClipItem(
            id: UUID(),
            kind: .image,
            date: date,
            file: processed.file,
            hash: processed.hash,
            byteCount: processed.byteCount
        )
        item.pixelWidth = processed.width
        item.pixelHeight = processed.height
        item.imageType = processed.uti
        item.thumbFile = processed.thumbFile
        item.sourceName = source?.name
        item.sourceBundleID = source?.bundleID
        return item
    }

    // MARK: - Диск

    private struct Index: Codable {
        var version: Int
        var items: [ClipItem]
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Index(version: 2, items: items)) else { return }
        try? data.write(to: AppInfo.indexURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: AppInfo.indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let index = try? decoder.decode(Index.self, from: data) else { return }
        let loaded = index.items.filter { fm.fileExists(atPath: fileURL($0).path) }
        items = loaded
        if trimToLimit() || loaded.count != index.items.count {
            save()
        }
    }

    /// Удаляет файлы, на которые не ссылается ни одна запись.
    private func removeOrphanFiles() {
        let keep: [(URL, Set<String>)] = [
            (AppInfo.itemsDir, Set(items.map(\.file))),
            (AppInfo.thumbsDir, Set(items.compactMap(\.thumbFile))),
        ]
        for (dir, names) in keep {
            let existing = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in existing where !names.contains(name) {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    /// Один раз переносит историю из старой версии на Python.
    private func importLegacyIfNeeded() {
        guard items.isEmpty,
              !fm.fileExists(atPath: AppInfo.indexURL.path),
              let data = try? Data(contentsOf: AppInfo.legacyIndexURL),
              let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return }

        var imported: [ClipItem] = []
        var seen = Set<String>()
        for entry in entries where imported.count < AppInfo.maxItems {
            let timestamp = (entry["ts"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970
            let date = Date(timeIntervalSince1970: timestamp)
            if (entry["kind"] as? String ?? "text") == "image" {
                guard let path = entry["img"] as? String,
                      let raw = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      let processed = ImageProcessor.process(raw, uti: "public.png"),
                      seen.insert(processed.hash).inserted
                else { continue }
                imported.append(makeImageItem(processed, date: date, source: nil))
            } else {
                guard let text = entry["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { continue }
                let textData = Data(text.utf8)
                let hash = Digest.sha256(textData)
                guard seen.insert(hash).inserted,
                      let item = makeTextItem(text, data: textData, hash: hash, date: date, source: nil)
                else { continue }
                imported.append(item)
            }
        }
        items = imported
        save()
        try? fm.moveItem(at: AppInfo.legacyIndexURL, to: AppInfo.supportDir.appendingPathComponent("history.legacy.json"))
    }
}
