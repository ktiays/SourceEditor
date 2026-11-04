// swift-tools-version: 5.9
import Foundation
import PackageDescription

// A clean checkout can build the core without downloading optional C sources.
let coreOnly = ProcessInfo.processInfo.environment["SOURCE_EDITOR_CORE_ONLY"] == "1"

let package = Package(
    name: "SourceEditor",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SourceEditor", targets: ["SourceEditor"]),
    ] + (coreOnly ? [] : [
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
        // SwiftPM doesn't discover Objective-C XCTest cases. Keep the checks in
        // Objective-C too, and run this executable with script/test.sh.
        .executableTarget(
            name: "SourceEditorChecks",
            dependencies: ["SourceEditor"],
            path: "Tests/SourceEditorChecks"
        ),
    ] + (coreOnly ? [] : [
        .target(
            name: "SETreeSitterRuntime",
            path: "Vendor/tree-sitter/lib",
            sources: ["src/lib.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("src")]
        ),
        .target(
            name: "SETreeSitterJSONGrammar",
            path: "Vendor/tree-sitter-json",
            exclude: ["LICENSE", "queries", "src/node-types.json"],
            sources: ["src/parser.c"],
            publicHeadersPath: "bindings/swift/TreeSitterJSON",
            cSettings: [.headerSearchPath("src")]
        ),
        .target(
            name: "SETreeSitterJavaScriptGrammar",
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
                "SETreeSitterRuntime",
                "SETreeSitterJSONGrammar",
                "SETreeSitterJavaScriptGrammar",
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
