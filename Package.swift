// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Rdc",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "Rdc", targets: ["RdcApp"]),
        .library(name: "RdcCore", targets: ["RdcCore"])
    ],
    targets: [
        .systemLibrary(
            name: "CFreeRDP",
            path: "Sources/CFreeRDP",
            pkgConfig: "freerdp3"
        ),
        .target(
            name: "RdcFreeRDPBridge",
            dependencies: ["CFreeRDP"],
            path: "Sources/RdcFreeRDPBridge",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedLibrary("freerdp-client3"),
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../vendor/freerdp-prefix/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../../../vendor/freerdp-prefix/lib"
                ])
            ]
        ),
        .target(
            name: "RdcCore",
            dependencies: ["RdcFreeRDPBridge"],
            path: "Sources/RdcCore",
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "RdcApp",
            dependencies: ["RdcCore"],
            path: "Sources/RdcApp"
        ),
        .testTarget(
            name: "RdcCoreTests",
            dependencies: ["RdcCore", "RdcFreeRDPBridge"],
            path: "Tests/RdcCoreTests",
            resources: [
                .copy("Fixtures")
            ]
        ),
        .testTarget(
            name: "RdcFreeRDPIntegrationTests",
            dependencies: ["RdcCore"],
            path: "Tests/RdcFreeRDPIntegrationTests"
        ),
        .testTarget(
            name: "RdcAppTests",
            dependencies: ["RdcApp", "RdcCore"],
            path: "Tests/RdcAppTests"
        )
    ]
)
