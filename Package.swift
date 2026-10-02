// swift-tools-version: 6.0

import PackageDescription

// The core and scripted transport tests run offline on Linux. Live HID and the
// SwiftUI application remain macOS-only.
#if os(macOS)
let hardwareTargets: [Target] = [
    .target(name: "CHIDBridge", publicHeadersPath: "include", linkerSettings: [
        .linkedFramework("CoreFoundation"), .linkedFramework("IOKit"),
    ]),
    .executableTarget(name: "KeyboardStudio", dependencies: ["KeyboardCore"], linkerSettings: [
        .linkedFramework("AppKit"), .linkedFramework("AppIntents"),
        .linkedFramework("Carbon"), .linkedFramework("UserNotifications"),
    ]),
    .executableTarget(name: "SayoProbe", dependencies: ["KeyboardCore"]),
]
let hardwareProducts: [Product] = [
    .executable(name: "KeyboardStudio", targets: ["KeyboardStudio"]),
    .executable(name: "sayo-probe", targets: ["SayoProbe"]),
]
let coreDependencies: [Target.Dependency] = ["CHIDBridge"]
#else
let hardwareTargets: [Target] = []
let hardwareProducts: [Product] = []
let coreDependencies: [Target.Dependency] = []
#endif

let package = Package(
    name: "KeyboardStudio",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "KeyboardCore", targets: ["KeyboardCore"]),
        .executable(name: "protocol-check", targets: ["ProtocolCheck"]),
    ] + hardwareProducts,
    targets: [
        .target(name: "KeyboardCore", dependencies: coreDependencies),
        .executableTarget(name: "ProtocolCheck", dependencies: ["KeyboardCore"]),
        .testTarget(name: "KeyboardCoreTests", dependencies: ["KeyboardCore"]),
    ] + hardwareTargets
)
