// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NoteIsland",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NoteIsland", targets: ["NoteIsland"])
    ],
    targets: [
        .executableTarget(
            name: "NoteIsland",
            path: "Sources/NoteIsland"
        ),
        .testTarget(
            name: "NoteIslandTests",
            dependencies: ["NoteIsland"],
            path: "Tests/NoteIslandTests"
        )
    ]
)
