// swift-tools-version:5.10
// Манифест нужен для Xcode / VS Code (SourceKit-LSP).
// Приложение собирается скриптом ./build.sh напрямую через swiftc — так сборка
// не зависит от SwiftPM и работает даже с одними Command Line Tools.
import PackageDescription

let package = Package(
    name: "ClipboardCommander",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClipboardCommander",
            path: "Sources/ClipboardCommander",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
