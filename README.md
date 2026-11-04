# SourceEditor

A macOS code editor component focused on text rendering, predictable editing costs, and native input handling.

Distributed as a Swift package, with Objective-C libraries, a demo application, and automated checks. Only the required `Package.swift` manifest uses Swift. SourceEditor supports macOS 14 and later. The core has no third-party dependencies or unsafe compiler flags. The optional Tree-sitter module uses pinned C runtime and grammar sources downloaded during dependency setup, without a Swift wrapper or remote SwiftPM dependency.

## Getting started

```sh
./script/bootstrap.sh
swift build
./script/build_and_run.sh
./script/test.sh
```

`bootstrap.sh` requires Python 3 and curl. It downloads missing dependencies, verifies their pinned SHA-256 checksums, and caches them outside Git. The demo and full test scripts initialize dependencies automatically and work offline once the sources are installed. See [Vendor/README.md](Vendor/README.md) for dependency metadata and cache behavior.

To build or check only the core from a fresh checkout without downloading dependencies:

```sh
SOURCE_EDITOR_CORE_ONLY=1 swift build --target SourceEditor
./script/test.sh --core-only
```

`SourceEditor` is the standalone editor library; `SourceEditorTreeSitter` is the optional syntax highlighting library. The AppKit demo defaults to Plain Text. Use the language control in the status bar or the **Syntax** menu to select Plain Text, JSON, or JavaScript while preserving the document and undo history. The status bar uses an `NSVisualEffectView` over the scrolling editor, with separate indicator and separator views. Scroll insets keep the last line and caret above it. If a highlighter cannot initialize, the demo uses Plain Text.

The status bar items and available languages are configurable. `SCEStatusBarView.items` sets the items and their order: `line`, `column`, `lineCount`, and `language`. The language item appears at the trailing edge. `languageTitles` defines the available choices. An empty list hides the language item, one title displays a fixed label, and two or more titles display a pop-up button. When no items are visible, `hasVisibleItems` returns `NO`; the demo hides the bar and removes its scroll insets.

The demo reads both settings from user defaults. Each accepts a comma-separated string or an array; an empty value selects no items:

```sh
open dist/SourceEditorDemo.app --args -SCEStatusBarItems 'line,column,language' -SCESyntaxLanguages 'json,javascript'
open dist/SourceEditorDemo.app --args -SCEStatusBarItems ''      # Hide the status bar.
open dist/SourceEditorDemo.app --args -SCESyntaxLanguages 'json' # Use a fixed JSON language label.
```

The demo starts with the first listed language and displays the **Syntax** menu when at least two languages are available. Objective-C API names and demo launch keys use the `SCE` prefix. Integrations written against the earlier two-letter prefix must update their references.

`script/build_and_run.sh` builds an application bundle in `dist/` and launches it. It also supports `--verify`, `--debug`, `--logs`, and `--telemetry`. Use `./script/build_and_run.sh --preview` to launch a separate build with its own bundle path while preserving existing windows and their undo history.

The demo hosts the editor component and retains document content in memory. Closing the application discards that content. Host applications are responsible for file management and persistence.

## Coding conventions

All project content, including code, documentation, comments, examples, and interface text, must use professional English unless another language is explicitly requested. Use precise editor development terminology throughout the project.

Follow Apple's [Coding Guidelines for Cocoa](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CodingGuidelines/CodingGuidelines.html) and [Objective-C conventions](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ProgrammingWithObjectiveC/Conventions/Conventions.html). Project-owned Objective-C types and related symbols use the three-letter `SCE` prefix, meaning Source Code Editor. [AGENTS.md](AGENTS.md) defines the complete contribution requirements, including naming, ownership, nullability, and validation.

The repository's `.clang-format` defines formatting: four-space indentation, opening braces on the signature or control statement line, braces around control statement bodies, and separate lines for method, function, and block bodies. Run `./script/format.sh` to format Objective-C files or `./script/format.sh --check` to verify them. The script uses `clang-format` from `PATH` when available and otherwise checks the active Xcode toolchain.

The Swift manifest uses the same indentation and line width through `.swift-format`. Format it with `xcrun swift-format format --in-place Package.swift` and verify it with `xcrun swift-format lint --strict Package.swift`.

## Embedding the editor

Enable Clang modules in the host Objective-C target, then import the library:

```objc
@import SourceEditor;

NSScrollView *scrollView = [SCEEditorView scrollableEditorView];
SCEEditorView *editor = (SCEEditorView *)scrollView.documentView;
editor.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
editor.string = @"// Document text.\n";
self.view = scrollView;
```

You can also create an `SCEEditorView` directly and assign it to an `NSScrollView`'s `documentView`. Access the editor and its properties on the main thread.

## Find and incremental search

`SCETextSearchQuery` describes a search with `SCETextSearchOptions`: case-sensitive matching, whole words, and ICU regular expressions. Searches ignore case by default. Whole-word matching treats letters, combining marks, numbers, and the underscore as word characters, like double-click word selection. In regular expressions, `^` and `$` match at line boundaries. Empty matches are skipped, and match ranges count UTF-16 code units.

Assigning `editor.searchQuery` highlights every match. The editor searches an O(1) buffer snapshot on a private serial queue, cancels superseded searches, and applies results on the main thread only when the document revision is unchanged. After an edit, matches outside the edited range move with the text until the next result arrives. `selectNextSearchMatch` and `selectPreviousSearchMatch` wrap around the document; when results are pending, they search synchronously first. `SCEEditorSearchResultsDidChangeNotification` reports new results, and `searchError` reports invalid patterns.

`SCEFindBarView` provides the search interface. On macOS 26 and later, the search field, match navigation, and close button are Liquid Glass shapes (`NSGlassEffectView`) in an `NSGlassEffectContainerView`; earlier systems use `NSVisualEffectView` capsules. The field shows the current match position and toggles for case, whole words, and regular expressions. Typing selects the first match at or after the caret position where the search began. Return and Shift-Return move between matches, and Escape ends the search:

```objc
SCEFindBarView *findBar = [[SCEFindBarView alloc] initWithFrame:NSZeroRect];
findBar.editor = editor;
findBar.dismissalHandler = ^{
    findBar.hidden = YES;
};
// Position the find bar over the editor, show it, then focus the search field.
[findBar beginSearch];
```

The demo places the find bar over the editor's top trailing corner and adds **Edit > Find** commands: Find (Command-F), Find Next (Command-G), Find Previous (Shift-Command-G), and Use Selection for Find (Command-E).

## Optional JSON and JavaScript highlighting

A host that depends only on the `SourceEditor` product does not compile or link Tree-sitter. The editor defaults to `syntaxHighlighter == nil` and supports plain text editing independently. To enable highlighting, add the `SourceEditorTreeSitter` product to the host target:

```objc
@import SourceEditor;
@import SourceEditorTreeSitter;

NSError *error = nil;
editor.syntaxHighlighter = [[SCETreeSitterHighlighter alloc]
    initWithLanguage:SCETreeSitterLanguageJavaScript error:&error];
// Use SCETreeSitterLanguageJSON for JSON documents.

// Restore plain text editing, cancel pending requests, and clear syntax colors.
editor.syntaxHighlighter = nil;
```

Initialization failures return `nil` and an error, allowing the host to continue with plain text editing. Create a separate highlighter instance for each editor and document.

Dependencies flow from `SourceEditorTreeSitter` to `SourceEditor`. The core defines the `SCESyntaxHighlighter` protocol, `SCESyntaxToken`, `SCETextEdit`, and `SCESyntaxHighlightResult`. Parser headers, syntax trees, language selection, and parser lifecycle management belong to the optional module. Other highlighting implementations can implement the same protocol.

Highlighting follows these steps:

1. The main thread submits an O(1) rope snapshot, an exact edit description, and a query range covering the visible lines plus six lines on either side.
2. The highlighter builds or incrementally updates a syntax tree on a private serial queue. The initial parse reads the complete document; later parses use `ts_tree_edit` and reuse the previous tree. Consecutive requests are coalesced, and superseded parsing can be canceled.
3. Queries return captures intersecting the requested range. Multiline comments and template strings retain their full document ranges. Highlighting does not require an attributed string for the complete document.
4. The main thread checks the document revision and request sequence before applying a result. Semantic ranges are assigned to the line cache. Only lines whose colors change rebuild their `CTLine` objects.

The parser reads UTF-16 little-endian chunks directly from the rope through a C input callback. It does not copy the complete document or convert it to UTF-8. Tree-sitter byte offsets and columns are twice the corresponding UTF-16 code-unit counts. Chunk boundaries preserve surrogate pairs. Snapshots carry document identifiers so that independent documents with equal revisions cannot reuse each other's syntax trees.

`SCESyntaxTheme` controls editor colors; the parser returns semantic tokens. Changing the theme does not reparse the document. Unconfigured token kinds use the plain text color. The default theme uses dynamic system colors for light and dark appearances:

```objc
editor.syntaxTheme = [[SCESyntaxTheme alloc] initWithForegroundColors:@{
    SCESyntaxTokenKeyword : NSColor.systemPurpleColor,
    SCESyntaxTokenString : NSColor.systemRedColor,
    SCESyntaxTokenComment : NSColor.secondaryLabelColor,
}];
```

The supplied queries cover JSON keys, strings, escapes, numbers, and constants, along with JavaScript keywords, functions, classes, properties, comments, regular expressions, and template interpolation. Query files are in `Sources/SourceEditorTreeSitter/Queries`. They use structural captures without requiring query predicates or language services.

Pinned versions, archive checksums, and extraction paths are recorded in `Vendor/versions.json`. Licenses remain in the downloaded sources and `Vendor/THIRD_PARTY_NOTICES.txt`. SwiftPM embeds the query resource bundle in host applications. The demo build script also copies that bundle and the third-party notices into `.app/Contents/Resources`. Hosts distributing binaries manually must include both resources.

## Architecture

SourceEditor uses AppKit for native interaction and Core Text for font layout, fallback, and drawing. The component manages text storage, viewport geometry, interaction, and invalidation. Storage, visible-line geometry, and layout caching have separate responsibilities, with undo and input-method handling integrated into editing transactions. End-to-end performance still requires measurement.

| Component | Responsibility | Implementation |
| --- | --- | --- |
| `SCETextBuffer` | UTF-16 storage, line indexing, independent snapshots | AVL rope with immutable nodes, leaves of at most 4,096 UTF-16 code units, and subtree length and line-feed counts |
| `SCEViewport` | Visible-line ranges | Fixed line height; visible lines plus six context lines on either side; independent of Core Text |
| `SCELineLayoutCache` | Layout, hit testing, selection geometry | Creates `CTLine` objects on demand; invalidates intersecting lines and shifts subsequent cache entries after edits |
| `SCEEditorView` | AppKit interaction and component integration | `NSTextInputClient`, standard editing commands, undo, mouse selection, and scrolling |
| `SCESyntaxHighlighter` and `SCESyntaxTheme` | Highlighting interface and presentation | Semantic UTF-16 ranges, asynchronous revision checks, and separate parsing and color configuration |
| `SourceEditorTreeSitter` | Optional JSON and JavaScript parsing | Pinned C grammars, incremental background parsing, and viewport capture queries |

Edits access intersecting rope chunks without constructing an `NSAttributedString` for the complete document. Line lookup traverses the tree. Snapshots share immutable nodes, making copies O(1). Reading `editor.string` or `buffer.string` materializes the complete document in O(N) time; avoid these reads in per-keystroke callbacks.

Text and selection use separate backing layers sized to the viewport. The caret uses an independent `CALayer`. The document view can be much taller than its drawing surfaces. Moving the selection or blinking the caret does not invalidate line layouts.

Selection rendering forms the union of visual line spans and line-ending extensions, removes internal edges, and rounds the exposed contour. Convex corners and concave joins between lines use pairs of cubic Bezier curves with continuous curvature. The endpoints meet straight edges at zero curvature; the paired curves have matching first and second derivatives at their midpoint. The default corner radius is 4 points and contracts along short edges.

The selection path is filled once with antialiasing to avoid internal seams. Geometry is computed from horizontal spans of visible lines without allocating a bitmap the size of the document. One context line above and below the viewport prevents artificial rounded corners at clipping edges. Unselected gaps, enclosed gaps, and disconnected spans in bidirectional text remain distinct.

Caches use logical line indices. Every edit adjusts both layouts and semantic styles using the previous line range and the change in line count. All edits must pass through the view's transaction methods. Font, tab-width, and appearance changes clear layout caches while preserving reusable semantic styles. Highlight results are checked by revision and request sequence, then compared by line style; the global revision does not invalidate every `CTLine`.

## Supported editing features

- Core Text rendering, system monospaced fonts, font fallback, and light and dark appearances.
- Horizontal and vertical scrolling, fixed line numbers, current-line highlighting, and independent caret blinking.
- A scope guide at the opening line's indentation for the innermost multiline `()`, `[]`, or `{}` pair enclosing the caret. The guide covers the lines between the brackets. `showsScopeGuide` defaults to `YES`.
- Text insertion and deletion, tabs, newlines that inherit leading indentation, cut, copy, paste, undo, and redo.
- Mouse drag selection, double-click word selection, triple-click or gutter line selection, and selection autoscrolling.
- Grapheme-boundary movement and deletion that preserve emoji, zero-width joiner sequences, and combining marks. CRLF is treated as one editing boundary.
- Arrow-key movement, Shift selection, Option word movement, Command line and document navigation, and page movement.
- Input-method marked text, commit, cancellation, and screen-coordinate queries. Each composition produces one undo transaction.
- Read-only mode, text and selection notifications, and basic accessibility text and selection interfaces.
- Background document search with literal, whole-word, case-sensitive, and regular expression matching, viewport match highlighting, wrapping navigation, and a Liquid Glass find bar.
- Optional JSON and JavaScript syntax highlighting, independent themes, background incremental parsing, and viewport queries.

All public positions and `NSRange` values count UTF-16 code units. Line indices start at zero. LF and CRLF are preserved, and a trailing newline adds an empty final line. The optional parser adapter converts these coordinates to Tree-sitter byte positions.

## Validation

`script/test.sh` runs the Objective-C `SourceEditorChecks` and `SourceEditorTreeSitterChecks` executables. `script/test.sh --core-only` builds and runs the core checks without linking Tree-sitter. SwiftPM does not directly discover these Objective-C check cases, so `swift test` does not execute them.

The existing checks cover:

- 12,000 randomized replacements compared with `NSMutableString`, followed by 3,000 insertions to exercise buffer growth, line indexing, range reads, and snapshot independence.
- Emoji, combining marks, CRLF deletion, undo and redo, preferred-column vertical movement, indentation, and read-only mode.
- Marked-text updates, selection replacement, commit, cancellation, composition undo and redo, input ranges, and screen-coordinate queries.
- Scope-guide matching against an independent stack-based reference, randomized bracket sequences across chunk boundaries and scan limits, changes after edits, and rendered position and line coverage.
- Core Text grapheme hit testing, tab advances, unchanged-line cache reuse, and selection changes without layout reconstruction.
- Visible-line cache bounds, local invalidation, scrolling, and drawing-surface sizing after shortening a 100,000-line document.
- Storage construction and random insertion and deletion timings for a 100,000-line buffer. These Debug storage measurements do not establish end-to-end input latency.
- Search options, line anchors, UTF-16 match ranges, invalid patterns, and match limits; background results, wrapping navigation, synchronous navigation during pending searches, match movement after edits, and highlight pixels confined to matching lines.
- Substitute highlighters, Core Text colors, unchanged-style cache reuse, stale-result rejection, highlighter removal, theme changes without parsing, and CRLF and UTF-16 edit coordinates.
- 120 randomized Unicode and newline edits for each supported language, comparing incremental and complete parses after every edit, including incomplete syntax.
- Nested templates, regular expressions, emoji at input chunk boundaries, range queries in a 20,000-line document, parse reuse during scrolling, multiline captures, document identity, request coalescing, and cancellation.

Protocol checks do not establish real input-method behavior. Candidate-window placement and continuous composition with Chinese and Japanese input methods require manual testing. Visual rendering, native shortcuts, Unicode paste, and horizontal scrolling also require application-level review when affected by a change.

## Limitations and planned work

1. **Input and performance validation.** Test candidate-window placement, selection replacement, and cancellation with real Chinese Pinyin and Japanese input methods. Use Instruments to measure input and scrolling frame times and record median and 95th-percentile input-to-display latency. Ordinary typing currently records one undo operation per insertion; native typing coalescing and a memory budget for large paste history remain planned.
2. **Long-line layout.** Each visible logical line currently creates one complete `CTLine`. A line containing a million characters can block the main thread. Grapheme navigation and selection geometry also process complete lines. Segmented layout needs shaping context, a horizontal visibility index, and explicit processing limits. Horizontal scroll width grows with visited lines and can remain wider than necessary after local deletions.
3. **Soft wrapping and bidirectional editing.** Layout currently uses unwrapped logical lines. Soft wrapping requires visual-line and height indices plus width-aware invalidation. Mixed-direction visual movement, caret affinity, and detailed selection behavior also need further work beyond system text shaping.
4. **Language services.** Extend the optional highlighting interface for additional parsers and languages before adding diagnostics, completion, Language Server Protocol support, or multiple carets.

Scope guides match bracket characters, including those in strings and comments. Each caret movement scans at most 131,072 UTF-16 code units in either direction. Brackets beyond that limit do not produce a guide. Syntax-tree-based matching remains a possible extension.

Each search materializes the document on the search queue, which takes O(document length) time and memory, and every edit restarts the search while a query is set. An editor collects at most 100,000 matches per query. Matches are not adjusted to grapheme boundaries, so a search for a base letter can match inside a combined character sequence. Replace is not implemented.

Standalone CR line endings, rectangular selection, code folding, language services, and complete VoiceOver parameterized navigation are not implemented. Highlighting uses syntax structure without scope binding or embedded-language parsing. Tree-sitter uses 32-bit byte coordinates. Unsupported document sizes, more than 20,000 captures in one query, or queries exceeding the match limit produce plain text for the requested range. Performance and interaction coverage require further validation before comparison with established editors.

References: [Core Text hit testing](https://developer.apple.com/documentation/coretext/ctlinegetstringindexforposition(_:_:)), [NSTextInputClient](https://developer.apple.com/documentation/appkit/nstextinputclient?language=objc), and [SwiftPM PackageDescription](https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html).
