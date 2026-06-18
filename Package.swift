// swift-tools-version: 5.9
//
// SwiftPM manifest for the Ghostty fork at github.com/mason-blumling/ghostty.
//
// Consumer usage (e.g. Mission Control):
//
//     dependencies: [
//         .package(url: "https://github.com/mason-blumling/ghostty.git", from: "0.2.2"),
//     ],
//     targets: [
//         .target(name: "MyApp", dependencies: [.product(name: "Ghostty", package: "ghostty")]),
//     ]
//
// The xcframework is committed to tag commits at vendor/GhosttyKit.xcframework/.
// The release process converts libghostty's static archive into a single-slice
// dynamic framework (macOS arm64), wraps it in a .framework bundle with proper
// Headers + module.modulemap + Info.plist, and combines that into an xcframework.
// Full debug info is preserved: NO strip, NO -Wl,-dead_strip, NO exported-symbols
// filter. The resulting dynamic dylib is ~18 MB (largest single file well under
// Apple GHE's 100 MB per-file push limit), with a separate dSYM published as a
// Release asset. No Git LFS, no URL-based binary target, no checksum management;
// consumers fetch via a standard `git clone` of the tag.
//
// On `main`, `vendor/GhosttyKit.xcframework/` and `Sources/Ghostty/Resources/`
// are absent; they are populated only on tag commits. Consumers always check out
// tagged versions. The upstream source each tag is built from is recorded in the
// top-level UPSTREAM_BASE file.

import PackageDescription

let package = Package(
    name: "Ghostty",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Ghostty", targets: ["Ghostty"]),
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "vendor/GhosttyKit.xcframework"
        ),
        .target(
            name: "Ghostty",
            dependencies: ["GhosttyKit"],
            resources: [
                .copy("Resources"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("Foundation"),
                .linkedFramework("IOKit"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedLibrary("c++"),
            ]
        ),
        .testTarget(
            name: "GhosttyTests",
            dependencies: ["Ghostty"]
        ),
    ]
)
