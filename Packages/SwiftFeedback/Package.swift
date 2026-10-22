// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftFeedback",
    platforms: [.macOS("14.4")],
    products: [.library(name: "SwiftFeedback", targets: ["SwiftFeedback"])],
    targets: [
        .target(name: "SwiftFeedback"),
        .testTarget(name: "SwiftFeedbackTests", dependencies: ["SwiftFeedback"]),
    ],
    swiftLanguageModes: [.v5]
)
