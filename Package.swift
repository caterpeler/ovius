// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ovius",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Ovius", targets: ["Ovius"]),
    ],
    targets: [
        .executableTarget(
            name: "Ovius",
            resources: [
                .process("Assets.xcassets"),
            ]
        ),
        .testTarget(
            name: "OviusTests",
            dependencies: ["Ovius"]
        ),
    ]
)
