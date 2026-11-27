// Рисует иконку приложения по сетке иконок macOS и собирает assets/app.icns.
//
// Запуск из корня репозитория:
//   swift scripts/make_icon.swift
import AppKit

let canvas = 1024
let assets = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("assets")
let pngURL = assets.appendingPathComponent("icon.png")
let iconsetURL = assets.appendingPathComponent("icon.iconset")
let icnsURL = assets.appendingPathComponent("app.icns")

func renderIcon() -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: canvas,
        pixelsHigh: canvas,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("не удалось создать холст")
    }
    rep.size = NSSize(width: canvas, height: canvas)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }

    // Квадрат со скруглением 824×824 по центру — как у системных иконок Big Sur и новее.
    let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
    let platePath = NSBezierPath(roundedRect: plate, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let dropShadow = NSShadow()
    dropShadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    dropShadow.shadowOffset = NSSize(width: 0, height: -12)
    dropShadow.shadowBlurRadius = 28
    dropShadow.set()
    NSColor.white.setFill()
    platePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    platePath.addClip()
    NSGradient(colors: [
        NSColor(srgbRed: 0.40, green: 0.66, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.20, green: 0.36, blue: 0.95, alpha: 1),
    ])?.draw(in: plate, angle: -90)
    NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.20),
        NSColor.white.withAlphaComponent(0),
    ])?.draw(in: NSRect(x: plate.minX, y: plate.midY, width: plate.width, height: plate.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    let symbolConfig = NSImage.SymbolConfiguration(pointSize: 420, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [
            NSColor(srgbRed: 0.24, green: 0.42, blue: 0.96, alpha: 1),
            .white,
        ]))
    if let symbol = NSImage(systemSymbolName: "list.clipboard.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(symbolConfig)
    {
        let size = symbol.size
        let target = NSRect(
            x: (CGFloat(canvas) - size.width) / 2,
            y: (CGFloat(canvas) - size.height) / 2 - 6,
            width: size.width,
            height: size.height
        )
        NSGraphicsContext.saveGraphicsState()
        let symbolShadow = NSShadow()
        symbolShadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        symbolShadow.shadowOffset = NSSize(width: 0, height: -8)
        symbolShadow.shadowBlurRadius = 18
        symbolShadow.set()
        symbol.draw(in: target)
        NSGraphicsContext.restoreGraphicsState()
    }
    return rep
}

func run(_ tool: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
}

let fm = FileManager.default
try? fm.createDirectory(at: assets, withIntermediateDirectories: true)
guard let png = renderIcon().representation(using: .png, properties: [:]) else { fatalError("PNG") }
try png.write(to: pngURL)
print("[icon] \(pngURL.path)")

try? fm.removeItem(at: iconsetURL)
try fm.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        run("/usr/bin/sips", ["-z", "\(pixels)", "\(pixels)", pngURL.path, "--out", iconsetURL.appendingPathComponent(name).path])
    }
}
run("/usr/bin/iconutil", ["-c", "icns", iconsetURL.path, "-o", icnsURL.path])
print("[icon] \(icnsURL.path)")
