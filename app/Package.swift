// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MoleLite",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MoleLite", targets: ["MoleLite"])
    ],
    targets: [
        .executableTarget(
            name: "MoleLite",
            path: "Sources/MoleLite"
        ),
        .testTarget(
            name: "MoleLiteTests",
            dependencies: ["MoleLite"],
            path: "Tests/MoleLiteTests",
            resources: [
                // 整个目录原样拷进测试 bundle，测试里用 Bundle.module 取。
                .copy("Fixtures")
            ]
        )
    ]
)
