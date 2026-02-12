// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "Canopy",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Canopy",
            path: "Sources/Canopy",
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/Canopy/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "CanopyTests",
            dependencies: ["Canopy"],
            path: "Tests/CanopyTests"
        ),
    ]
)
