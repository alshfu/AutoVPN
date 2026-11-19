// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AutoVPN",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "AutoVPN", path: "Sources/AutoVPN")
    ]
)
