// swift-tools-version: 6.2
// Core logic: recognition, word bands, annotation, storage, iCloud sync of words and level, and the import queue. Nonisolated by
// default; `swift test` runs on a macOS host.
import PackageDescription

let package = Package(
    name: "ReadStairCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "ReadStairCore", targets: ["ReadStairCore"]),
    ],
    targets: [
        .target(
            name: "ReadStairCore",
            resources: [.copy("Resources/lexicon")],
            swiftSettings: [.defaultIsolation(nil)]
        ),
        .testTarget(
            name: "ReadStairCoreTests",
            dependencies: ["ReadStairCore"],
            // Symlinks to the repository's Fixtures/ and Data/: bundled because a device cannot read the Mac's file system.
            resources: [.copy("Resources/Fixtures"), .copy("Resources/Data")],
            swiftSettings: [.defaultIsolation(nil)]
        ),
    ],
    swiftLanguageModes: [.v6]
)
