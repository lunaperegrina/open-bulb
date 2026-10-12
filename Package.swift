// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "open-bulb",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "TuyaLocal"),
        .target(name: "TuyaCloud"),
        .executableTarget(name: "openbulb-cli", dependencies: ["TuyaLocal", "TuyaCloud"]),
        .executableTarget(name: "OpenBulb", dependencies: ["TuyaLocal", "TuyaCloud"]),
        .testTarget(name: "TuyaLocalTests", dependencies: ["TuyaLocal"]),
    ]
)
