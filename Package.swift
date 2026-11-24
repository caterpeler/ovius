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
            ],
            linkerSettings: [
                // SwiftUI's VideoPlayer (_AVKit_SwiftUI) subclasses AVKit's player view, but the app names no AVKit
                // symbol itself, so the linker drops AVKit and VideoPlayer aborts the app when it first appears.
                .linkedFramework("AVKit"),
            ]
        ),
        .testTarget(
            name: "OviusTests",
            dependencies: ["Ovius"],
            resources: [
                // Box-track Parquet files and pyarrow's reading of them (scripts/make-parquet-fixtures.py).
                .copy("Fixtures"),
            ]
        ),
    ]
)
