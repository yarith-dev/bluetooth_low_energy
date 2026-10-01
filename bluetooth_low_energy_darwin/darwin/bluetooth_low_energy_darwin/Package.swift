// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "bluetooth_low_energy_darwin",
    platforms: [
        // If your plugin only supports iOS, remove `.macOS(...)`.
        // If your plugin only supports macOS, remove `.iOS(...)`.
        .iOS("13.0"),
        .macOS("10.15")
    ],
    products: [
        // If the plugin name contains "_", replace with "-" for the library name.
        .library(name: "bluetooth-low-energy-darwin", targets: ["bluetooth_low_energy_darwin"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "bluetooth_low_energy_darwin",
            dependencies: [],
            resources: [
                .process("PrivacyInfo.xcprivacy"),
            ]
        )
    ]
)
