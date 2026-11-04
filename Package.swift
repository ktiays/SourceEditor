// swift-tools-version: 5.9
import Foundation
import PackageDescription

// The core can build without resolving the optional parser packages.
let isCoreOnly = ProcessInfo.processInfo.environment["SOURCE_EDITOR_CORE_ONLY"] == "1"

let package = Package(
    name: "SourceEditor",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SourceEditor", targets: ["SourceEditor"])
    ]
        + (isCoreOnly
            ? []
            : [
                .library(name: "SourceEditorTreeSitter", targets: ["SourceEditorTreeSitter"]),
                .executable(name: "SourceEditorDemo", targets: ["SourceEditorDemo"]),
            ]),
    // Tree-sitter v0.27 removed its SwiftPM manifest, so the runtime stays on v0.26.
    dependencies: isCoreOnly
        ? []
        : [
            .package(url: "https://github.com/tree-sitter/tree-sitter", .upToNextMinor(from: "0.26.13")),
            .package(url: "https://github.com/tree-sitter/tree-sitter-json", .upToNextMinor(from: "0.24.8")),
        ],
    targets: [
        .target(
            name: "SourceEditor",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreText"),
                .linkedFramework("QuartzCore"),
            ]
        ),
        // SwiftPM does not discover Objective-C XCTest cases. Run these
        // Objective-C checks through script/test.sh.
        .executableTarget(
            name: "SourceEditorChecks",
            dependencies: ["SourceEditor"],
            path: "Tests/SourceEditorChecks"
        ),
    ]
        + (isCoreOnly
            ? []
            : [
                .target(
                    name: "SourceEditorTreeSitter",
                    dependencies: [
                        "SourceEditor",
                        .product(name: "TreeSitter", package: "tree-sitter"),
                        .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
                    ],
                    resources: [.copy("Queries")],
                    publicHeadersPath: "include"
                ),
                .executableTarget(name: "SourceEditorDemo", dependencies: ["SourceEditor", "SourceEditorTreeSitter"]),
                .executableTarget(
                    name: "SourceEditorTreeSitterChecks",
                    dependencies: ["SourceEditor", "SourceEditorTreeSitter"],
                    path: "Tests/SourceEditorTreeSitterChecks"
                ),
            ])
)
