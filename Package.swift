// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Faultday",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "faultday", targets: ["Faultday"])],
    targets: [
        .target(name: "FaultdayCore", path: "Sources/FaultdayCore"),
        .executableTarget(name: "Faultday", dependencies: ["FaultdayCore"], path: "Sources/Faultday"),
        .testTarget(name: "FaultdayCoreTests", dependencies: ["FaultdayCore"], path: "Tests/FaultdayCoreTests")
    ]
)
