// swift-tools-version:5.8
import PackageDescription

let package = Package(
    name: "JiraMacTool",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "JiraMacTool", targets: ["JiraMacTool"])
    ],
    dependencies: [
        .package(url: "https://github.com/MaxDesiatov/XMLCoder", from: "0.17.0")
    ],
    targets: [
        .executableTarget(
            name: "JiraMacTool",
            dependencies: ["XMLCoder"],
            path: "Sources/JiraMacTool",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
