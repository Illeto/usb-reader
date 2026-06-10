// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "usbcable",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "usbcable",
            path: "Sources/usbcable"
        )
    ]
)
