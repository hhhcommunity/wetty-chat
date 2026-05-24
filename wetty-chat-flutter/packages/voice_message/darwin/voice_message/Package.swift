// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "voice_message",
    platforms: [
        .iOS("13.0"),
        .macOS("10.15"),
    ],
    products: [
        .library(name: "voice-message", targets: ["voice_message"]),
    ],
    targets: [
        .target(
            name: "voice_message",
            dependencies: [
                "COpusOggBridge",
                "libopus",
                "ogg",
            ],
            linkerSettings: [
                .linkedFramework("AVFAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
        .target(
            name: "COpusOggBridge",
            dependencies: [
                "ogg",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
            ]
        ),
        .target(
            name: "libopus",
            publicHeadersPath: "include",
            cSettings: [
                .define("HAVE_CONFIG_H", to: "1"),
                .define("FLOATING_POINT"),
                .headerSearchPath("include"),
                .headerSearchPath("src"),
                .headerSearchPath("silk"),
                .headerSearchPath("silk/float"),
                .headerSearchPath("celt"),
                .headerSearchPath("celt/x86"),
                .unsafeFlags(["-w", "-O3"]),
            ]
        ),
        .target(
            name: "ogg",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .unsafeFlags(["-O3", "-Wno-shorten-64-to-32"]),
            ]
        ),
    ]
)
