// swift-tools-version:5.6
import PackageDescription

let package = Package(
    name: "shell-kit",
    platforms: [.macOS(.v10_15)],
    products: [
        .library(name: "ShellKit", targets: ["ShellKit"]),
    ],
    dependencies: [
        .package(url: "git@github.com:andyj-at-aspin/NSTry.git", exact: "0.0.3")
    ],
    targets: [
        .target(name: "ShellKit", dependencies: [
            .product(name: "NSTry", package: "NSTry")
        ]),
        .testTarget(name: "ShellKitTests", dependencies: ["ShellKit"]),
    ]
)
