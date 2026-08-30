// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "KeyboardStudio",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "KeyboardCore", targets: ["KeyboardCore"]),
        .executable(name: "KeyboardStudio", targets: ["KeyboardStudio"]),
        .executable(name: "sayo-probe", targets: ["SayoProbe"]),
        .executable(name: "protocol-check", targets: ["ProtocolCheck"]),
    ],
    targets: [
        .target(
            name: "CHIDBridge",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOKit"),
            ]
        ),
        .target(
            name: "KeyboardCore",
            dependencies: ["CHIDBridge"]
        ),
        .executableTarget(
            name: "KeyboardStudio",
            dependencies: ["KeyboardCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AppIntents"),
                .linkedFramework("Carbon"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .executableTarget(
            name: "SayoProbe",
            dependencies: ["KeyboardCore"]
        ),
        .executableTarget(
            name: "ProtocolCheck",
            dependencies: ["KeyboardCore"]
        ),
    ]
)
