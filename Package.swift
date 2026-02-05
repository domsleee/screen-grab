// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ScreenGrab",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ScreenGrab", targets: ["ScreenGrab"])
    ],
    dependencies: [
        .package(url: "https://github.com/soffes/HotKey", from: "0.2.0")
    ],
    targets: [
        .executableTarget(
            name: "ScreenGrab",
            dependencies: ["HotKey"],
            path: "ScreenGrab",
            exclude: ["Resources/Info.plist", "Resources/ScreenGrab.entitlements"]
        ),
        .testTarget(
            name: "ScreenGrabTests",
            dependencies: ["ScreenGrab"],
            path: "Tests/ScreenGrabTests"
        )
    ]
)
