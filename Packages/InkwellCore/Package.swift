// swift-tools-version: 6.2
import PackageDescription

// Everything that doesn't need UIKit or AppKit: the note file format, storage, the search
// index and the Markdown logic. `swift test` runs its tests on the Mac without a simulator.
let package = Package(
    name: "InkwellCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "InkwellCore", targets: ["InkwellCore"]),
    ],
    targets: [
        .target(name: "InkwellCore"),
        .testTarget(name: "InkwellCoreTests", dependencies: ["InkwellCore"]),
    ],
    swiftLanguageModes: [.v5]
)
