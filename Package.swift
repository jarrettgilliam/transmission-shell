// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "TransmissionShell",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "TransmissionKit", targets: ["TransmissionKit"]),
        .executable(name: "TransmissionShell", targets: ["TransmissionShell"])
    ],
    targets: [
        .target(
            name: "TransmissionKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "TransmissionShell",
            dependencies: ["TransmissionKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TransmissionKitTests",
            dependencies: ["TransmissionKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
