// swift-tools-version: 6.1

import PackageDescription

let libassBinaryTarget: Target =
    Context.environment["SWIFT_LIBASS_USE_LOCAL_XCFRAMEWORK"] == "1"
        ? .binaryTarget(
            name: "LibASS",
            path: "Artifacts/LibASS.xcframework"
        )
        : .binaryTarget(
            name: "LibASS",
            url: "https://github.com/vvisionnn/swift-libass/releases/download/1.0.0/LibASS.xcframework.zip",
            checksum: "f9c414740a0f43260a03876e46cf2eb0d7e461f3b5d5aa6574d9fb6aa93fab32"
        )

let package = Package(
    name: "swift-libass",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "LibASS", targets: ["LibASS", "LibASSLinkerSupport"]),
    ],
    targets: [
        libassBinaryTarget,
        .target(
            name: "LibASSLinkerSupport",
            dependencies: ["LibASS"],
            resources: [.process("PrivacyInfo.xcprivacy")],
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreText"),
                .linkedLibrary("c++"),
                .linkedLibrary("iconv"),
            ]
        ),
        .testTarget(
            name: "LibASSTests",
            dependencies: ["LibASS", "LibASSLinkerSupport"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
