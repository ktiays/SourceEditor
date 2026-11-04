// swift-tools-version: 5.9
import Foundation
import PackageDescription

// The core can build without downloading the optional parser's C sources.
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
                    name: "SCETreeSitterRuntime",
                    path: "Vendor/tree-sitter/lib",
                    sources: ["src/lib.c"],
                    publicHeadersPath: "include",
                    cSettings: [.headerSearchPath("src")]
                ),
                .target(
                    name: "SCETreeSitterJSONGrammar",
                    path: "Vendor/tree-sitter-json",
                    exclude: ["LICENSE", "queries", "src/node-types.json"],
                    sources: ["src/parser.c"],
                    publicHeadersPath: "bindings/swift/TreeSitterJSON",
                    cSettings: [.headerSearchPath("src")]
                ),
                .target(
                    name: "SCETreeSitterJavaScriptGrammar",
                    path: "Vendor/tree-sitter-javascript",
                    exclude: ["LICENSE", "queries", "src/node-types.json"],
                    sources: ["src/parser.c", "src/scanner.c"],
                    publicHeadersPath: "bindings/swift/TreeSitterJavaScript",
                    cSettings: [.headerSearchPath("src")]
                ),
                .target(
                    name: "SourceEditorTreeSitter",
                    dependencies: [
                        "SourceEditor",
                        "SCETreeSitterRuntime",
                        "SCETreeSitterJSONGrammar",
                        "SCETreeSitterJavaScriptGrammar",
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
