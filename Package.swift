// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TaskManager",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TaskManager",
            path: "Sources/TaskManager",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Installed setuid-root by the app so it can read stats for processes it does
        // not own. Ships inside the bundle; see PrivilegedHelper.swift.
        .executableTarget(
            name: "tmhelper",
            path: "Sources/tmhelper",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
