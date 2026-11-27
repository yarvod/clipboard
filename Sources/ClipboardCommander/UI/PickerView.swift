import AppKit
import SwiftUI

struct PickerView: View {
    @ObservedObject var model: PickerModel
    @ObservedObject var store: HistoryStore
    @FocusState private var searchFocused: Bool

    var body: some View {
        let items = model.filtered
        let selected = model.selectedItem(in: items)

        VStack(spacing: 0) {
            SearchBar(
                query: $model.query,
                focused: $searchFocused,
                count: store.items.count,
                limit: AppInfo.maxItems
            )
            Divider()
            if items.isEmpty {
                EmptyState(isSearching: !model.query.isEmpty)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    ClipList(items: items, selectedID: selected?.id, model: model, store: store)
                        .frame(width: 320)
                    Divider()
                    if let selected {
                        DetailPane(item: selected, model: model, store: store)
                            .id(selected.id)
                    }
                }
            }
            Divider()
            FooterBar(autoPaste: model.autoPasteEnabled)
        }
        // Заголовок окна скрыт — не оставляем под него пустое место.
        .ignoresSafeArea()
        .onAppear { searchFocused = true }
        .onChange(of: model.focusRequest) { searchFocused = true }
    }
}

// MARK: - Поиск

private struct SearchBar: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    let count: Int
    let limit: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Поиск в истории буфера", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 20))
                .focused(focused)
            Text("\(count) из \(limit)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(.quaternary))
                .help("Хранится не больше \(limit) последних записей")
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
    }
}

// MARK: - Список

private struct ClipList: View {
    let items: [ClipItem]
    let selectedID: UUID?
    @ObservedObject var model: PickerModel
    let store: HistoryStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        ClipRow(item: item, index: index, isSelected: item.id == selectedID, store: store)
                            .id(item.id)
                            .onTapGesture(count: 2) { model.choose(item, paste: true) }
                            .simultaneousGesture(TapGesture().onEnded { model.selection = item.id })
                            .contextMenu { RowMenu(item: item, model: model) }
                    }
                }
                .padding(8)
            }
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
    }
}

private struct ClipRow: View {
    let item: ClipItem
    let index: Int
    let isSelected: Bool
    let store: HistoryStore

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            leading
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.78)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.7)) : AnyShapeStyle(.tertiary))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowFill)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    private var rowFill: Color {
        if isSelected { return .accentColor }
        return isHovering ? Color.primary.opacity(0.06) : .clear
    }

    private var subtitle: String {
        [item.sourceName, Formatters.relative(item.date)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    @ViewBuilder
    private var leading: some View {
        switch item.kind {
        case .image:
            AsyncImageView(
                url: store.thumbURL(item) ?? store.fileURL(item),
                maxPixel: 96,
                cacheKey: "\(item.id)-thumb",
                contentMode: .fill
            )
            .frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12))
            )
        case .text:
            if let icon = AppIcons.icon(for: item.sourceBundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 30, height: 30)
            } else {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isSelected ? AnyShapeStyle(Color.white.opacity(0.2)) : AnyShapeStyle(.quaternary))
                    )
            }
        }
    }
}

private struct RowMenu: View {
    let item: ClipItem
    let model: PickerModel

    var body: some View {
        Button("Вставить") { model.choose(item, paste: true) }
        Button("Скопировать") { model.choose(item, paste: false) }
        if item.kind == .image {
            Button("Показать в Finder") { model.reveal(item) }
        }
        Divider()
        Button("Удалить", role: .destructive) { model.delete(item) }
    }
}

// MARK: - Просмотр

private struct DetailPane: View {
    let item: ClipItem
    @ObservedObject var model: PickerModel
    let store: HistoryStore

    @State private var fullText: String?

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            infoBar
        }
        .task(id: item.id) {
            guard item.kind == .text else { return }
            let url = store.fileURL(item)
            fullText = await Task.detached(priority: .userInitiated) {
                try? String(contentsOf: url, encoding: .utf8)
            }.value
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text:
            ScrollView {
                Text(displayText)
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(16)
            }
        case .image:
            let url = store.fileURL(item)
            AsyncImageView(
                url: url,
                maxPixel: 1600,
                cacheKey: "\(item.id)-full",
                contentMode: .fit,
                showsPlaceholder: false
            )
            .frame(maxWidth: pointSize.width, maxHeight: pointSize.height)
            .aspectRatio(aspectRatio, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
            .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
            .padding(20)
            .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
            .help("Перетащите картинку в Finder или другое приложение — она сохранится файлом")
        }
    }

    private var aspectRatio: CGFloat {
        guard let width = item.pixelWidth, let height = item.pixelHeight, width > 0, height > 0 else { return 1 }
        return CGFloat(width) / CGFloat(height)
    }

    /// Не растягиваем маленькие картинки больше их размера на Retina-экране.
    private var pointSize: CGSize {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return CGSize(
            width: CGFloat(item.pixelWidth ?? 4000) / scale,
            height: CGFloat(item.pixelHeight ?? 4000) / scale
        )
    }

    private var displayText: String {
        let text = fullText ?? item.preview
        let limit = 40_000
        guard text.utf16.count > limit else { return text }
        return String(text.prefix(limit)) + "\n…"
    }

    private var infoBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(primaryInfo)
                    .font(.system(size: 11, weight: .medium))
                Text(secondaryInfo)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            if item.kind == .image {
                Button {
                    model.reveal(item)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Показать файл в Finder")
            }
            Button(model.autoPasteEnabled ? "Вставить" : "Скопировать") {
                model.choose(item, paste: true)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
    }

    private var primaryInfo: String {
        switch item.kind {
        case .text:
            let chars = Formatters.plural(item.charCount ?? item.preview.count, "символ", "символа", "символов")
            let lines = Formatters.plural(item.lineCount ?? 1, "строка", "строки", "строк")
            return "\(chars) · \(lines)"
        case .image:
            let size = "\(item.pixelWidth ?? 0) × \(item.pixelHeight ?? 0)"
            return "\(size) · \(Formatters.imageType(item.imageType)) · \(Formatters.bytes(item.byteCount))"
        }
    }

    private var secondaryInfo: String {
        [item.sourceName, Formatters.dateTime(item.date)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

// MARK: - Пустое состояние и подвал

private struct EmptyState: View {
    let isSearching: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: isSearching ? "magnifyingglass" : "list.clipboard")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text(isSearching ? "Ничего не найдено" : "История пуста")
                .font(.system(size: 15, weight: .semibold))
            Text(isSearching ? "Попробуйте другой запрос" : "Скопируйте текст или картинку — они появятся здесь")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }
}

private struct FooterBar: View {
    let autoPaste: Bool

    var body: some View {
        HStack(spacing: 14) {
            KeyHint(key: "↩", label: autoPaste ? "Вставить" : "Скопировать")
            if autoPaste {
                KeyHint(key: "⌘↩", label: "Скопировать")
            }
            KeyHint(key: "⌘1–9", label: "Выбрать")
            KeyHint(key: "⌘⌫", label: "Удалить")
            KeyHint(key: "esc", label: "Закрыть")
            Spacer()
            if !autoPaste {
                Button("Включить автовставку…") { Paster.requestAccessibility() }
                    .buttonStyle(.link)
                    .help("Чтобы вставлять по ↩ сразу в программу, разрешите доступ в «Универсальном доступе»")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 30)
    }
}

private struct KeyHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10.5, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.quaternary)
                )
            Text(label)
        }
    }
}
