// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QingJie",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "QingJie", targets: ["QingJie"])],
    targets: [
        .target(name: "QingJieCore"),
        .executableTarget(name: "QingJie", dependencies: ["QingJieCore"]),
        .testTarget(name: "QingJieCoreTests", dependencies: ["QingJieCore"])
    ]
)
