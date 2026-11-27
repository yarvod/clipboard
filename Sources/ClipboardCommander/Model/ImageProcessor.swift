import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum Digest {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Готовая к сохранению картинка: файлы уже записаны на диск.
struct ProcessedImage: Sendable {
    let file: String
    let thumbFile: String?
    let hash: String
    let byteCount: Int
    let width: Int
    let height: Int
    let uti: String
}

/// Работает в фоне: декодирует картинку из буфера, сохраняет её файлом и делает превью.
enum ImageProcessor {
    static let thumbnailMaxPixel = 256

    static func process(_ raw: Data, uti: String) -> ProcessedImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(raw as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0
        else { return nil }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0 else { return nil }

        // PNG и JPEG храним как есть, остальное (TIFF, HEIC…) переводим в PNG.
        var data = raw
        var type = UTType(uti) ?? .png
        if !(type.conforms(to: .png) || type.conforms(to: .jpeg)) {
            guard let png = encode(source: source, as: .png) else { return nil }
            data = png
            type = .png
        }
        let ext = type.conforms(to: .jpeg) ? "jpg" : "png"

        let file = uniqueFileName(base: niceBaseName(), ext: ext, in: AppInfo.itemsDir)
        do {
            try data.write(to: AppInfo.itemsDir.appendingPathComponent(file), options: .atomic)
        } catch {
            return nil
        }

        var thumbFile: String?
        if let thumb = thumbnailPNG(source: source) {
            let name = "\(UUID().uuidString).png"
            if (try? thumb.write(to: AppInfo.thumbsDir.appendingPathComponent(name), options: .atomic)) != nil {
                thumbFile = name
            }
        }

        return ProcessedImage(
            file: file,
            thumbFile: thumbFile,
            hash: Digest.sha256(data),
            byteCount: data.count,
            width: width,
            height: height,
            uti: type.identifier
        )
    }

    private static func encode(source: CGImageSource, as type: UTType) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func thumbnailPNG(source: CGImageSource) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func niceBaseName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "yyyy-MM-dd 'в' HH.mm.ss"
        return "Изображение \(formatter.string(from: Date()))"
    }

    private static func uniqueFileName(base: String, ext: String, in dir: URL) -> String {
        let fm = FileManager.default
        var name = "\(base).\(ext)"
        var counter = 2
        while fm.fileExists(atPath: dir.appendingPathComponent(name).path) {
            name = "\(base) (\(counter)).\(ext)"
            counter += 1
        }
        return name
    }
}
