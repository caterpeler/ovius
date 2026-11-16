// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ovius",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Ovius", targets: ["Ovius"]),
    ],
    targets: [
        // Everything but the windows: the library on disk, bundles, Python, runs and the figures.
        .target(
            name: "OviusCore",
            exclude: ["metrics.py", "pipeline"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "Ovius", dependencies: ["OviusCore"]),
        // The fixture is read where it is (the team's sheet, by scripts/sheet-fixture.py).
        .testTarget(name: "OviusCoreTests", dependencies: ["OviusCore"], exclude: ["Fixtures"]),
    ]
)
