// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SSDLinkBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SSDLinkBar",
            path: "Sources/SSDLinkBar"
        )
    ]
)
