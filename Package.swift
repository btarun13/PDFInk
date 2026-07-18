// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PDFInk",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "PDFInkCore"),
        .executableTarget(name: "PDFInk", dependencies: ["PDFInkCore"]),
        .testTarget(name: "PDFInkCoreTests", dependencies: ["PDFInkCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
