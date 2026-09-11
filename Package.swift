// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Nozzle",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Nozzle", targets: ["Nozzle"]),
        .library(name: "NozzleCore", targets: ["NozzleCore"]),
        .executable(name: "nozzle-cli", targets: ["NozzleCLI"]),
    ],
    targets: [
        // Everything that talks to the printer. No SwiftUI here on purpose:
        // this target must be testable without a Mac window or a real printer.
        .target(name: "NozzleCore"),

        // The macOS app. Only this target imports SwiftUI.
        .executableTarget(name: "Nozzle", dependencies: ["NozzleCore"]),

        .target(name: "NozzleCLIKit", dependencies: ["NozzleCore"]),
        .executableTarget(name: "NozzleCLI", dependencies: ["NozzleCLIKit"]),
        .testTarget(name: "NozzleCLITests", dependencies: ["NozzleCLIKit"]),
        .testTarget(name: "NozzleCoreTests", dependencies: ["NozzleCore"]),
    ]
)
