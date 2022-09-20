// swift-tools-version:5.6
import PackageDescription

let package = Package(
    name: "shell-kit",
    platforms: [.macOS(.v10_15)],
    products: [
        .library(name: "ShellKit", targets: ["ShellKit"]),
    ],
    targets: [
        .target(name: "ShellKit", dependencies: []),
        .testTarget(name: "ShellKitTests", dependencies: ["ShellKit"]),
    ]
)
