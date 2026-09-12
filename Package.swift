// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DiskSteward",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "DiskSteward",
            targets: ["DiskStewardCore", "DiskStewardEndpoint"]
        ),
        .library(
            name: "DiskStewardCore",
            targets: ["DiskStewardCore"]
        ),
        .executable(
            name: "DiskStewardApp",
            targets: ["DiskStewardApp"]
        ),
        .executable(
            name: "disk-witness-mcp",
            targets: ["DiskStewardMCP"]
        ),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/DiskStewardCore/EvidenceStore/CSQLite"
        ),
        .target(
            name: "DiskStewardCore",
            dependencies: ["CSQLite"],
            exclude: ["EvidenceStore/CSQLite"]
        ),
        .executableTarget(
            name: "DiskStewardApp",
            dependencies: ["DiskStewardCore"]
        ),
        .executableTarget(
            name: "DiskStewardMCP",
            dependencies: ["DiskStewardCore"]
        ),
        .target(
            name: "DiskStewardEndpoint",
            dependencies: ["DiskStewardCore"],
            path: "Extensions/DiskStewardEndpoint",
            exclude: ["Info.plist"],
            linkerSettings: [.linkedLibrary("EndpointSecurity")]
        ),
        .testTarget(
            name: "FoundationTests",
            dependencies: ["DiskStewardCore"],
            path: "Tests/Support"
        ),
        .testTarget(
            name: "ContractTests",
            dependencies: ["DiskStewardCore"],
            path: "Tests/ContractTests"
        ),
        .testTarget(
            name: "DiskStewardCoreTests",
            dependencies: ["DiskStewardCore"],
            path: "Tests/DiskStewardCoreTests"
        ),
        .testTarget(
            name: "DiskStewardAppTests",
            dependencies: ["DiskStewardApp", "DiskStewardCore"],
            path: "Tests/DiskStewardAppTests"
        ),
        .testTarget(
            name: "DiskStewardMCPTests",
            dependencies: ["DiskStewardMCP", "DiskStewardCore"],
            path: "Tests/DiskStewardMCPTests"
        ),
        .testTarget(
            name: "IncrementTests",
            dependencies: ["DiskStewardApp", "DiskStewardCore"],
            path: "Tests/IncrementTests"
        ),
        .testTarget(
            name: "IntegrationInstallTests",
            dependencies: ["DiskStewardMCP", "DiskStewardCore"],
            path: "Tests/IntegrationInstallTests"
        ),
        .testTarget(
            name: "DiskStewardEndpointTests",
            dependencies: ["DiskStewardEndpoint", "DiskStewardCore"],
            path: "Tests/DiskStewardEndpointTests"
        ),
        .testTarget(
            name: "SafetyTests",
            dependencies: ["DiskStewardApp", "DiskStewardCore", "DiskStewardEndpoint"],
            path: "Tests/SafetyTests"
        ),
        .testTarget(
            name: "PerformanceTests",
            dependencies: ["DiskStewardCore", "DiskStewardEndpoint"],
            path: "Tests/PerformanceTests"
        ),
    ]
)
