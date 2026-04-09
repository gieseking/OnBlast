// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OnBlast",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "OnBlast",
            targets: ["OnBlast"]
        ),
        .executable(
            name: "VirtualMicSelfTestHelper",
            targets: ["VirtualMicSelfTestHelper"]
        ),
        .executable(
            name: "VirtualMicCaptureHelper",
            targets: ["VirtualMicCaptureHelper"]
        )
    ],
    targets: [
        .target(
            name: "OBTransportShared",
            path: "VirtualAudioDevice/Shared",
            publicHeadersPath: "."
        ),
        .executableTarget(
            name: "OnBlast",
            dependencies: ["OBTransportShared"],
            path: "Sources/OnBlast",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreMedia")
            ]
        ),
        .executableTarget(
            name: "VirtualMicSelfTestHelper",
            path: "Sources/VirtualMicSelfTestHelper",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio")
            ]
        ),
        .executableTarget(
            name: "VirtualMicCaptureHelper",
            dependencies: ["OBTransportShared"],
            path: "Sources/VirtualMicCaptureHelper",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio")
            ]
        )
    ]
)
