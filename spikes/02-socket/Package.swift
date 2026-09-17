// swift-tools-version: 6.3
import PackageDescription

// Language mode pinned to v5: this probe hand-rolls socket synchronization
// with NSLock/DispatchSemaphore across GCD queues, which the Swift 6 strict
// concurrency checker cannot verify and which is throwaway anyway.
let package = Package(
    name: "FlockSocketSpike",
    targets: [
        .executableTarget(
            name: "FlockSocketSpike",
            path: "Sources",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
