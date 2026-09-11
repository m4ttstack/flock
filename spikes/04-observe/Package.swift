// swift-tools-version: 6.3
import PackageDescription

// Language mode pinned to v5: same rationale as spike 02, this probe hand-rolls
// process/pipe plumbing and concurrent state that the Swift 6 strict
// concurrency checker cannot verify and which is throwaway anyway.
let package = Package(
    name: "PaddockObserveSpike",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0")
    ],
    targets: [
        .executableTarget(
            name: "PaddockObserveSpike",
            dependencies: ["SwiftTerm"],
            path: "Sources",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
