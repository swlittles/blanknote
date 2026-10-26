// swift-tools-version: 6.2
import PackageDescription

// Everything that doesn't need UIKit or AppKit: the note file format, storage, the search
// index and the Markdown logic. `swift test` runs its tests on the Mac without a simulator.
let package = Package(
    name: "BlankNoteCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "BlankNoteCore", targets: ["BlankNoteCore"]),
    ],
    targets: [
        .target(name: "BlankNoteCore"),
        .testTarget(name: "BlankNoteCoreTests", dependencies: ["BlankNoteCore"]),
    ],
    swiftLanguageModes: [.v5]
)
