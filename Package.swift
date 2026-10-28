// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QuotaDeck",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "QuotaDeckCore",
            targets: ["QuotaDeckCore"]
        ),
        .executable(
            name: "QuotaDeck",
            targets: ["QuotaDeckApp"]
        ),
        .executable(
            name: "QuotaDeckWidget",
            targets: ["QuotaDeckWidget"]
        ),
    ],
    targets: [
        .target(
            name: "QuotaDeckCore",
            path: "Sources/QuotaDeckCore",
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "QuotaDeckApp",
            dependencies: ["QuotaDeckCore"],
            path: "Sources/QuotaDeckApp",
            exclude: ["Info.plist", "QuotaDeck.entitlements"],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Security"),
                .linkedFramework("WidgetKit"),
            ]
        ),
        .executableTarget(
            name: "QuotaDeckWidget",
            dependencies: ["QuotaDeckCore"],
            path: "Sources/QuotaDeckWidget",
            exclude: ["Info.plist", "QuotaDeckWidget.entitlements"],
            linkerSettings: [
                .linkedFramework("WidgetKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .testTarget(
            name: "QuotaDeckCoreTests",
            dependencies: ["QuotaDeckCore"],
            path: "Tests/QuotaDeckCoreTests"
        ),
    ]
)
