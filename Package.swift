// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SlyTerm",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        .target(name: "CMultitouch", path: "Sources/CMultitouch"),
        .executableTarget(
            name: "SlyTerm",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm"), "CMultitouch"],
            path: "Sources/SlyTerm",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("WebKit"),
            ]
        ),
    ]
)
