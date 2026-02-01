// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ShareXMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ShareXMac", targets: ["ShareXMac"])
    ],
    dependencies: [
        .package(url: "https://github.com/soffes/HotKey", from: "0.2.0")
    ],
    targets: [
        .executableTarget(
            name: "ShareXMac",
            dependencies: ["HotKey"],
            path: "ShareXMac",
            exclude: ["Resources/Info.plist", "Resources/ShareXMac.entitlements"]
        )
    ]
)
