// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Chelka",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Chelka", targets: ["Chelka"]),
        .library(name: "ChelkaCore", targets: ["ChelkaCore"]),
    ],
    targets: [
        // Ядро: никакого AppKit, полная строгая конкурентность Swift 6,
        // всё тестируется без экрана и без запуска приложения.
        .target(
            name: "ChelkaCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // UI-слой: AppKit/SwiftUI, режим Swift 5 — иначе строгая конкурентность
        // ломается о неаннотированные места системных фреймворков.
        .executableTarget(
            name: "Chelka",
            dependencies: ["ChelkaCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ChelkaCoreTests",
            dependencies: ["ChelkaCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
