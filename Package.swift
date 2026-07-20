// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NTFSMount",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "NTFSMount", targets: ["NTFSMount"]),
        .executable(name: "NTFSMountHelper", targets: ["NTFSMountHelper"])
    ],
    targets: [
        .target(name: "NTFSMountShared"),
        .executableTarget(
            name: "NTFSMount",
            dependencies: ["NTFSMountShared"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreServices"),
                .linkedFramework("DiskArbitration"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "NTFSMountHelper",
            dependencies: ["NTFSMountShared"],
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "NTFSMountValidation",
            dependencies: ["NTFSMountShared"],
            path: "Tests/Validation"
        )
    ],
    swiftLanguageModes: [.v5]
)
