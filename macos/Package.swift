// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Proofmark",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "Proofmark", path: "Sources/Proofmark")]
)
