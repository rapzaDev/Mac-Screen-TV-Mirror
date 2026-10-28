// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "MacMirror", platforms: [.macOS(.v14)], products: [
    .library(name: "MirrorCore", targets: ["MirrorCore"]),
    .executable(name: "MacMirrorProbe", targets: ["MacMirrorProbe"])
], targets: [
    .target(name: "MirrorCore", path: "macos/Core", swiftSettings: [.swiftLanguageMode(.v5)]),
    .executableTarget(name: "MacMirrorProbe", dependencies: ["MirrorCore"], path: "macos/Probe", swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "MirrorCoreTests", dependencies: ["MirrorCore"], path: "macos/Tests", swiftSettings: [.swiftLanguageMode(.v5)])
])
