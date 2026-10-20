// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Screenshotter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Screenshotter",
            path: "Sources/Screenshotter",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
