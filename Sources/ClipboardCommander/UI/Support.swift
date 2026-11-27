import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Загружает уменьшенные копии картинок в фоне и держит их в ограниченном кэше.
/// Полноразмерные картинки в память не попадают никогда.
final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 60
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    func cached(_ key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func forget(_ id: UUID) {
        cache.removeObject(forKey: "\(id)-thumb" as NSString)
        cache.removeObject(forKey: "\(id)-full" as NSString)
    }

    @MainActor
    func load(url: URL, maxPixel: Int, key: String) async -> NSImage? {
        if let image = cached(key) { return image }
        let cgImage = await Task.detached(priority: .userInitiated) {
            ImageLoader.downsample(url: url, maxPixel: maxPixel)
        }.value
        guard let cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: key as NSString, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }

    private static func downsample(url: URL, maxPixel: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

struct AsyncImageView: View {
    let url: URL
    let maxPixel: Int
    let cacheKey: String
    var contentMode: ContentMode = .fit
    var showsPlaceholder = true

    @State private var image: NSImage?

    init(url: URL, maxPixel: Int, cacheKey: String, contentMode: ContentMode = .fit, showsPlaceholder: Bool = true) {
        self.url = url
        self.maxPixel = maxPixel
        self.cacheKey = cacheKey
        self.contentMode = contentMode
        self.showsPlaceholder = showsPlaceholder
        _image = State(initialValue: ImageLoader.shared.cached(cacheKey))
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: contentMode)
            } else if showsPlaceholder {
                Rectangle().fill(.quaternary)
            } else {
                Color.clear
            }
        }
        .task(id: cacheKey) {
            if image == nil {
                image = await ImageLoader.shared.load(url: url, maxPixel: maxPixel, key: cacheKey)
            }
        }
    }
}

@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let icon = cache[bundleID] { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 64, height: 64)
        cache[bundleID] = icon
        return icon
    }

    static func menuIcon(for item: ClipItem) -> NSImage? {
        let base: NSImage?
        switch item.kind {
        case .image:
            base = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        case .text:
            base = icon(for: item.sourceBundleID) ?? NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
        }
        guard let copy = base?.copy() as? NSImage else { return nil }
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }
}

@MainActor
enum Formatters {
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.unitsStyle = .short
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func relative(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 45 { return "только что" }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    static func dateTime(_ date: Date) -> String {
        dateTimeFormatter.string(from: date)
    }

    static func bytes(_ count: Int) -> String {
        byteFormatter.string(fromByteCount: Int64(count))
    }

    static func imageType(_ uti: String?) -> String {
        guard let uti, let type = UTType(uti) else { return "PNG" }
        if type.conforms(to: .jpeg) { return "JPEG" }
        return type.preferredFilenameExtension?.uppercased() ?? "PNG"
    }

    /// Русские формы множественного числа: 1 строка, 2 строки, 5 строк.
    static func plural(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        let mod10 = count % 10
        let mod100 = count % 100
        let word: String
        if mod10 == 1 && mod100 != 11 {
            word = one
        } else if (2...4).contains(mod10) && !(12...14).contains(mod100) {
            word = few
        } else {
            word = many
        }
        return "\(count.formatted()) \(word)"
    }
}
