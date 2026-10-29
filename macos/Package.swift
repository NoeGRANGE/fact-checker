// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Margin",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "Margin", path: "Sources/Margin")]
)
