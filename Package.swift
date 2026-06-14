// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Docmost",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Docmost", path: "Sources/Docmost")
    ]
)
