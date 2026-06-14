// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Docmost",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure, UI-independent logic (models + persistence) — unit-tested.
        .target(name: "DocmostCore", path: "Sources/DocmostCore"),
        // The macOS app (AppKit/WebKit UI) — a thin layer over DocmostCore.
        .executableTarget(
            name: "Docmost",
            dependencies: ["DocmostCore"],
            path: "Sources/Docmost"
        ),
        .testTarget(
            name: "DocmostCoreTests",
            dependencies: ["DocmostCore"],
            path: "Tests/DocmostCoreTests"
        ),
    ]
)
