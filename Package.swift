// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QingJie",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "QingJie", targets: ["QingJie"])],
    targets: [
        .target(name: "QingJiePNG", linkerSettings: [.linkedLibrary("z")]),
        .target(name: "QingJieCore", dependencies: ["QingJiePNG"]),
        .executableTarget(name: "QingJie", dependencies: ["QingJieCore"]),
        .testTarget(name: "QingJieCoreTests", dependencies: ["QingJieCore"])
    ]
)
