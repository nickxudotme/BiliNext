// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BiliNext", platforms: [.macOS("26.0")],
    products: [
        .executable(name: "BiliNext", targets: ["BiliNext"])
    ],
    targets: [
        .systemLibrary(name: "CMPV", pkgConfig: "mpv", providers: [.brew(["mpv"])]),
        .target(name: "BiliNextCore"),
        .executableTarget(name: "BiliNext", dependencies: ["BiliNextCore", "CMPV"]),
        .testTarget(name: "BiliNextCoreTests", dependencies: ["BiliNextCore"]),
        .testTarget(name: "BiliNextTests", dependencies: ["BiliNext"]),
    ], swiftLanguageModes: [.v5])
