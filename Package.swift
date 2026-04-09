// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MediaButtonInterceptor",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "MediaButtonInterceptor",
            targets: ["MediaButtonInterceptor"]
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
            name: "MBITransportShared",
            path: "VirtualAudioDevice/Shared",
            publicHeadersPath: "."
        ),
        .executableTarget(
            name: "MediaButtonInterceptor",
            dependencies: ["MBITransportShared"],
            path: "Sources/MediaButtonInterceptor",
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
            dependencies: ["MBITransportShared"],
            path: "Sources/VirtualMicCaptureHelper",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio")
            ]
        )
    ]
)
