# SourceEditor

A macOS code editor component focused on text rendering, predictable editing costs, and native input handling.

Distributed as a Swift package, with Objective-C libraries, a demo application, and automated checks. Only the required `Package.swift` manifest uses Swift. SourceEditor supports macOS 14 and later. The core has no third-party dependencies or unsafe compiler flags. The optional Tree-sitter module depends on the upstream [tree-sitter](https://github.com/tree-sitter/tree-sitter) runtime and [tree-sitter-json](https://github.com/tree-sitter/tree-sitter-json) grammar packages and calls their C API directly, without a Swift wrapper.

## Getting started

```sh
swift build
./script/build_and_run.sh
./script/test.sh
```

SwiftPM resolves the Tree-sitter packages on first build. Tree-sitter v0.27 removed its SwiftPM manifest, so the runtime is constrained to the v0.26 series.

To build or check only the core without resolving those packages:

```sh
SOURCE_EDITOR_CORE_ONLY=1 swift build --target SourceEditor
./script/test.sh --core-only
```

`SourceEditor` is the standalone editor library; `SourceEditorTreeSitter` is the optional syntax highlighting library. The AppKit demo defaults to Plain Text. Use the language control in the status bar or the **Syntax** menu to select Plain Text, JSON, or JavaScript while preserving the document and undo history. JSON enables highlighting and bracket completion on Return. JavaScript enables its editing rules without a syntax highlighter. The status bar uses an `NSVisualEffectView` over the scrolling editor, with separate indicator and separator views. Scroll insets keep the last line and caret above it. If the JSON highlighter cannot initialize, the demo uses Plain Text.

The status bar items and available languages are configurable. `SCEStatusBarView.items` sets the items and their order: `line`, `column`, `lineCount`, and `language`. The language item appears at the trailing edge. `languageTitles` defines the available choices. An empty list hides the language item, one title displays a fixed label, and two or more titles display a pop-up button. When no items are visible, `hasVisibleItems` returns `NO`; the demo hides the bar and removes its scroll insets.

The demo reads both settings from user defaults. Each accepts a comma-separated string or an array; an empty value selects no items:

```sh
open dist/SourceEditorDemo.app --args -SCEStatusBarItems 'line,column,language' -SCESyntaxLanguages 'plaintext,json'
open dist/SourceEditorDemo.app --args -SCEStatusBarItems ''      # Hide the status bar.
open dist/SourceEditorDemo.app --args -SCESyntaxLanguages 'json' # Use a fixed JSON language label.
open dist/SourceEditorDemo.app --args -SCESyntaxLanguages 'javascript,json'
```

The demo starts with the first listed language and displays the **Syntax** menu when at least two languages are available. Objective-C API names and demo launch keys use the `SCE` prefix. Integrations written against the earlier two-letter prefix must update their references.

`script/build_and_run.sh` builds an application bundle in `dist/` and launches it. It also supports `--verify`, `--debug`, `--logs`, and `--telemetry`. Use `./script/build_and_run.sh --preview` to launch a separate build with its own bundle path while preserving existing windows and their undo history.

The demo hosts the editor component and retains document content in memory. **File > Open** loads a UTF-8 file through a file-backed buffer, so large files open without being decoded; the demo does not save, and closing the application discards edits. Host applications are responsible for file management and persistence.

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

To open a UTF-8 file, create a file-backed buffer and let the editor share its storage:

```objc
NSError *error = nil;
SCETextBuffer *buffer = [[SCETextBuffer alloc] initWithContentsOfURL:fileURL error:&error];
if (buffer) {
    [editor replaceContentsWithBuffer:buffer];
}
```

`initWithContentsOfURL:error:` memory-maps files on local volumes and reads files on other volumes into memory. Loading scans the bytes once, in parallel, to record the UTF-16 length and line-feed count of each 16 KiB leaf; text is decoded only when read, through a cache of 64 leaves per file. A leading byte order mark is dropped, and each maximal ill-formed UTF-8 subsequence decodes to U+FFFD. Use `initWithString:` for other encodings. Replacing the file, as atomic saves do, does not affect an open buffer, but truncating a mapped file in place makes later reads of the removed pages terminate the process; do not map files that other processes rewrite in place.

## Indentation and bracket completion

Tab inserts spaces by default. `tabWidth` sets literal tab stops in space columns and defaults to 4. `indentationWidth` sets the indentation step and soft Tab stops; its default of 0 follows `tabWidth`. Tab inserts enough spaces to reach the next indentation stop from the rendered caret position, rather than counting UTF-16 offsets. With proportional fonts, the required distance rounds up to whole spaces. Both widths are limited to 32 columns, and `tabWidth` is at least 1.

Set `insertsSpacesForTabs` to `NO` to insert a literal tab on Tab. Generated leading indentation then uses tabs plus any remaining spaces, measured using `tabWidth`. Existing document text, explicit text replacements, and paste preserve their characters. Changing widths affects subsequent input and tab layout without rewriting document text or resetting undo.

`automaticIndentationEnabled` defaults to `YES`. Return inherits the current line's indentation. Language configurations can add a level after an opening bracket and separate an adjacent matching closer onto its own line. When automatic indentation is disabled, Return inserts only the document's LF or CRLF sequence.

```objc
editor.tabWidth = 4;
editor.indentationWidth = 2; // Use two-space indentation with four-column tab stops.
editor.insertsSpacesForTabs = YES;
editor.languageConfiguration = SCELanguageConfiguration.languageConfigurationForJSON;
editor.bracketCompletionMode = SCEBracketCompletionModeOnNewline;
```

Language rules are independent of the optional syntax highlighter. JSON configures `{}` and `[]` for completion and multiline expansion. JavaScript adds `()` for inline completion; parentheses do not expand into an indented block. Select its preset with `SCELanguageConfiguration.languageConfigurationForJavaScript`.

`bracketCompletionMode` defaults to `SCEBracketCompletionModeDisabled`:

| Mode | Behavior |
| --- | --- |
| `Disabled` | Never generates a closer. Language indentation and expansion around an existing closer still apply. |
| `OnNewline` | Return after an eligible opener, with only whitespace after the caret, generates a closer when the opener is unmatched. Existing adjacent closers are reused. |
| `WhileTyping` | Also pairs a single opening bracket delivered by keyboard input before whitespace, a configured closer, or the document end. Opening brackets insert a complete new pair so nested typing remains balanced. Typing a closer advances the caret over an adjacent closer that completion generated. Generated closers are forgotten when the caret leaves their line or a selection is made; other closers are never overtyped, because they may belong to an outer pair. |

For example, typing `{` and Return with the JSON preset and default widths produces `"{\n    \n}"`, with the caret after the four spaces. The generated replacement is one undo operation. An opener is unmatched when the pair's code-context openers before the caret outnumber its closers after the caret, so a closer that belongs to an enclosing block does not prevent completion. A matching closer already on a following line is preserved. When more than 131,072 UTF-16 units follow the caret, or a bracket's context is unknown, Return indents without inserting a closer.

Completion applies at an empty caret in code context. Nonempty selections, strings, comments, marked-text composition, multi-character input, paste, and explicit text replacements retain literal insertion behavior. Input-method commits remain one undo transaction. Setting `languageConfiguration` to `nil` restores ordinary newline indentation while preserving text, selection, and undo.

For custom languages, construct immutable `SCEBracketPair` values and pass them to `initWithBracketPairs:contextProvider:`. Each opening and closing character must be unique across all pairs. Pairs use distinct, non-whitespace BMP characters and exclude surrogates. The retained `SCELanguageContextProvider` implements `contextAtUTF16Offset:inBuffer:` on the main thread. It receives an independent buffer snapshot and must return promptly without mutating it. Return `SCELanguageContextUnknown` when current context cannot be established; only `SCELanguageContextCode` permits language-specific editing. `SCELanguageContextString` also covers template text and regular-expression literal contents.

The presets scan rope chunks and cache lexical checkpoints for exact snapshot contents. Edits invalidate checkpoints after the replacement start; independently edited snapshots with equal document identifiers and revisions cannot reuse each other's state. Each lookup reads at most 131,072 UTF-16 units. A distant uncached position returns unknown while subsequent lookups can resume from the cached prefix. Checkpoint storage is bounded.

JavaScript recognition handles quoted strings, line and block comments, template expressions, and common regular-expression and division contexts. Some lexical goals require syntactic context, as described in the [ECMAScript lexical grammar](https://tc39.es/ecma262/multipage/ecmascript-language-lexical-grammar.html). A slash after a closing parenthesis is division, except after the parenthesized head of `if`, `while`, `for`, or `with`, where it begins a regular expression. Other ambiguous slash positions, such as after a closing brace, escaped identifiers, nested regular-expression character classes, invalid string line endings, and template nesting beyond 32 levels return unknown. An ambiguous prefix can suppress completion later in the document until that prefix changes. This is conservative lexical recognition, not a JavaScript parser or formatter.

## Context menus and web links

Right-click or Control-click opens an editing menu with Cut, Copy, and Paste. A click inside the selection preserves it; a click outside selects the pointed-to word, or places the caret in empty space. Commands target the clicked editor and use its selection, editability, and the system pasteboard to determine availability. Copy remains available in read-only and non-focusable editors. Undo, Redo, Delete, and Select All are not in the context menu; they remain available through the main menu and their key equivalents, and Delete removes only the selection as one undoable edit.

Assign an object conforming to `SCEEditorViewDelegate` to `editor.delegate` to customize each menu. The delegate is weak, so the host must retain it. The callback runs on the main thread after establishing the context-click selection. Modify and return the supplied menu, return a replacement `NSMenu`, or return `nil` to suppress the menu:

```objc
// In the host's SCEEditorViewDelegate implementation:
- (NSMenu *)editorView:(SCEEditorView *)editorView
                  menu:(NSMenu *)menu
              forEvent:(NSEvent *)event {
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *item = [menu addItemWithTitle:@"Inspect Selection"
                                      action:@selector(inspectSelection:)
                               keyEquivalent:@""];
    item.target = self; // The host implements inspectSelection:.
    return menu;
}
```

Each request starts with a fresh menu. Set the inherited `editor.menu` property to provide a custom starting menu; the editor copies it before invoking the delegate, preserving the host's template. Custom items keep their specified targets and use AppKit's normal menu validation.

`automaticLinkDetectionEnabled` defaults to `YES`. Foundation's data detector recognizes HTTP and HTTPS URLs, including supported addresses without an explicit scheme. Hold Command while hovering over a link to underline it and show a pointing-hand cursor. Command-click opens the link through `NSWorkspace` in the default browser while preserving the selection, including in read-only and non-focusable editors. Ordinary clicks continue to select text. Dragging, releasing Command before mouse-up, or editing the document cancels a pending link click.

Use `URLAtPoint:effectiveRange:` to query the URL and its UTF-16 range at a visible point in the editor's document coordinates. Detection caches only the pointed-to logical line, and edits invalidate that cache. On lines longer than 4,096 UTF-16 code units, detection scans 2,048 code units on each side of the pointer instead of the whole line and ignores links that reach the edge of that window. The gutter, empty space, email addresses, and non-web URL schemes do not activate browser links. Links do not span logical lines.

## Find and incremental search

`SCETextSearchQuery` describes a search with `SCETextSearchOptions`: case-sensitive matching, whole words, and ICU regular expressions. Searches ignore case by default. Whole-word matching treats letters, combining marks, numbers, and the underscore as word characters, like double-click word selection. In regular expressions, `^` and `$` match at line boundaries. Empty matches are skipped, and match ranges count UTF-16 code units.

Assigning `editor.searchQuery` highlights every match, starting with the viewport. Most queries cannot match a line feed: literal patterns without one, and regular expressions without escapes, classes, or flags that can match one (a conservative check of the pattern). For these, the editor tracks which lines are still unsearched. The visible lines are searched on the main thread when they total at most 32,768 UTF-16 code units, so their matches appear immediately. The remaining lines are searched in chunks of about 131,072 code units on concurrent background queues, first from the viewport to the end of the document and then from the start. Each chunk reads its text from an O(1) rope snapshot, so the document is never materialized. An edit removes the matches of the edited lines, moves later matches with the text, and searches the edited lines again; other lines keep their results. `selectNextSearchMatch` and `selectPreviousSearchMatch` wrap around the document and search only the unsearched lines between the selection and the match. Queries that can cross lines are searched as a whole document on a background queue; after an edit, unaffected matches move with the text until the next result, and navigation searches synchronously. `SCEEditorSearchResultsDidChangeNotification` reports progress, and `searchError` reports invalid patterns as soon as the query is set.

`SCEFindBarView` provides the search interface. On macOS 26 and later, the search field, match navigation, and close button are Liquid Glass shapes (`NSGlassEffectView`) in an `NSGlassEffectContainerView`; earlier systems use `NSVisualEffectView` capsules. The field shows the current match position and toggles for case, whole words, and regular expressions. Typing selects the match nearest the caret, before or after it: the fewest lines away, then the fewest UTF-16 code units away, preferring the following match on a tie, so the selection stays near the content being edited instead of wrapping to the start of the document. Without a match, the caret returns to where the search began. That origin follows clicks, edits, and caret movement in the editor while the find bar is open, but not the find bar's own match selection, so continued typing keeps searching near the original caret position. The nearest match is located by searching the lines around the caret synchronously, widening outward, up to 32,768 UTF-16 code units, so it is usually selected immediately, even when the caret is outside the viewport; otherwise it is selected when the background search reaches it. Return and Shift-Return move between matches, and Escape ends the search:

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

## Optional JSON highlighting

A host that depends only on the `SourceEditor` product does not compile or link Tree-sitter. The editor defaults to `syntaxHighlighter == nil` and supports plain text editing independently. To enable highlighting, add the `SourceEditorTreeSitter` product to the host target:

```objc
@import SourceEditor;
@import SourceEditorTreeSitter;

NSError *error = nil;
editor.syntaxHighlighter = [[SCETreeSitterHighlighter alloc]
    initWithLanguage:SCETreeSitterLanguageJSON error:&error];

// Restore plain text editing, cancel pending requests, and clear syntax colors.
editor.syntaxHighlighter = nil;
```

Initialization failures return `nil` and an error, allowing the host to continue with plain text editing. Create a separate highlighter instance for each editor and document.

Dependencies flow from `SourceEditorTreeSitter` to `SourceEditor`. The core defines the `SCESyntaxHighlighter` protocol, `SCESyntaxToken`, `SCETextEdit`, and `SCESyntaxHighlightResult`. Parser headers, syntax trees, language selection, and parser lifecycle management belong to the optional module. Other highlighting implementations can implement the same protocol.

Highlighting follows these steps:

1. The main thread submits an O(1) rope snapshot, an exact edit description, and the ranges covering the visible lines plus six lines on either side. A line laid out in fragments contributes only the text within one viewport width of the visible area, in its own range, so a minified document is highlighted around the viewport instead of failing the capture limit. Highlighters that implement `highlightBuffer:UTF16Ranges:afterEdit:completion:` receive the disjoint ranges; others receive the smallest range that contains them.
2. The highlighter builds or incrementally updates a syntax tree on a private serial queue. The initial parse reads the complete document; later parses use `ts_tree_edit` and reuse the previous tree. Consecutive requests are coalesced, and superseded parsing can be canceled.
3. Queries return captures intersecting the requested ranges. Multiline comments and strings retain their full document ranges. Highlighting does not require an attributed string for the complete document.
4. The main thread applies a result only when its document revision is current, even if a later request superseded it. Semantic ranges are assigned to the line cache; on a partly highlighted long line, colors outside the requested part stay. Only lines whose colors change rebuild their `CTLine` objects.
5. Once the viewport's colors are current, the editor requests the short lines around it, up to one viewport height or 32 lines on either side and 32,768 UTF-16 code units in total. The cache retains those colors, so scrolling nearby shows colors without waiting; a range that is already highlighted for the current revision is not requested again.

The parser reads UTF-16 little-endian chunks directly from the rope through a C input callback. It does not copy the complete document or convert it to UTF-8. Tree-sitter byte offsets and columns are twice the corresponding UTF-16 code-unit counts. Chunk boundaries preserve surrogate pairs. Snapshots carry document identifiers so that independent documents with equal revisions cannot reuse each other's syntax trees.

`SCESyntaxTheme` controls editor colors; the parser returns semantic tokens. Changing the theme does not reparse the document. Unconfigured token kinds use the plain text color. The default theme uses dynamic system colors for light and dark appearances:

```objc
editor.syntaxTheme = [[SCESyntaxTheme alloc] initWithForegroundColors:@{
    SCESyntaxTokenKeyword : NSColor.systemPurpleColor,
    SCESyntaxTokenString : NSColor.systemRedColor,
    SCESyntaxTokenComment : NSColor.secondaryLabelColor,
}];
```

Use `initWithForegroundColors:editorColors:` to configure the text and gutter backgrounds, plain text, line numbers, current-line highlight, active and inactive selections, caret, scope guide, and search highlights. Omitted editor colors use system defaults. If only the active selection color is set, the inactive selection uses that color at half its opacity.

```objc
editor.syntaxTheme = [[SCESyntaxTheme alloc]
    initWithForegroundColors:SCESyntaxTheme.defaultTheme.foregroundColors
                editorColors:@{
                    SCEEditorColorBackground : NSColor.blackColor,
                    SCEEditorColorText : NSColor.whiteColor,
                    SCEEditorColorCaret : NSColor.systemOrangeColor,
                }];
```

Translucent text or gutter backgrounds allow content behind the editor to show through. To expose that content through an enclosing scroll view, set `scrollView.drawsBackground = NO`.

The supplied query covers JSON keys, strings, escapes, numbers, constants, comments, and punctuation. Query files are in `Sources/SourceEditorTreeSitter/Queries`. They use structural captures without requiring query predicates or language services.

Licenses remain in the resolved package sources and `THIRD_PARTY_NOTICES.txt`. SwiftPM embeds the query resource bundle in host applications. The demo build script also copies that bundle and the third-party notices into `.app/Contents/Resources`. Hosts distributing binaries manually must include both resources.

## Architecture

SourceEditor uses AppKit for native interaction and Core Text for font layout, fallback, and drawing. The component manages text storage, viewport geometry, interaction, and invalidation. Storage, visible-line geometry, and layout caching have separate responsibilities, with undo and input-method handling integrated into editing transactions. End-to-end performance still requires measurement.

| Component | Responsibility | Implementation |
| --- | --- | --- |
| `SCETextBuffer` | UTF-16 storage, line indexing, independent snapshots | AVL rope with immutable nodes and subtree length and line-feed counts. Edited leaves own at most 4,096 UTF-16 code units; file-backed leaves refer to up to 16 KiB of a mapped UTF-8 file and decode on demand |
| `SCEViewport` | Visible-line ranges | Fixed line height; visible lines plus six context lines on either side; independent of Core Text |
| `SCELineLayoutCache` | Layout, hit testing, selection geometry | Creates `CTLine` objects on demand, dividing long lines into fragments laid out as they become visible; invalidates intersecting lines and shifts subsequent cache entries after edits |
| `SCEEditorView` | AppKit interaction and component integration | `NSTextInputClient`, standard editing commands, undo, mouse selection, and scrolling |
| `SCELanguageConfiguration` | Language-specific editing rules | Immutable bracket pairs, independent context providers, bounded lexical recognition, and revision-checked checkpoints |
| `SCESyntaxHighlighter` and `SCESyntaxTheme` | Highlighting interface and presentation | Semantic UTF-16 ranges, asynchronous revision checks, and separate parsing and color configuration |
| `SourceEditorTreeSitter` | Optional JSON parsing | Upstream C runtime and grammar packages, incremental background parsing, and viewport capture queries |

Edits access intersecting rope chunks without constructing an `NSAttributedString` for the complete document. Line lookup traverses the tree. Snapshots share immutable nodes, making copies O(1). Reading `editor.string` or `buffer.string` materializes the complete document in O(N) time; avoid these reads in per-keystroke callbacks.

A file-backed buffer keeps the file mapped and holds only per-leaf counts, so its memory use does not grow with the file size. Splitting a file-backed leaf during an edit replaces it with owned leaves; other leaves keep referring to the file. Decoding uses one UTF-8 decoder for both the load-time index and on-demand reads, so the two always agree on UTF-16 lengths. The decoded-leaf cache is thread-safe and returns leaves without autoreleasing them, so a background reader such as the parser does not accumulate decoded text.

Lines up to 2,048 UTF-16 code units are laid out as one `CTLine`. Longer lines are divided into fragments of about 1,024 code units, preferably after a space or tab and always at a grapheme cluster boundary. Fragments are measured left to right on demand, because each fragment's position is the sum of the widths before it; `CTTypesetterCreateLineWithOffset` keeps tab stops relative to the line start. A layout retains the CTLines of eight fragments. Drawing, selection, search highlighting, and link hit testing pass the visible horizontal extent, so they measure only up to the viewport, and the document width uses the measured average advance to estimate the rest of a line. Locating a position measures the line through that position, so moving to the end of a long line measures it once. Recoloring a line or editing it keeps the measured geometry of the fragments before the edit. Bounding every Core Text query to one fragment matters: line-offset queries grow quadratically with line length for mixed-script text. Shaping and bidirectional reordering do not cross fragment boundaries, and fragments use a left-to-right base direction.

Text and selection use separate backing layers sized to the viewport. The caret uses an independent `CALayer`. The document view can be much taller than its drawing surfaces. Moving the selection or blinking the caret does not invalidate line layouts.

Selection rendering forms the union of visual line spans and line-ending extensions, removes internal edges, and rounds the exposed contour. Convex corners and concave joins between lines use pairs of cubic Bezier curves with continuous curvature. The endpoints meet straight edges at zero curvature; the paired curves have matching first and second derivatives at their midpoint. The default corner radius is 4 points and contracts along short edges.

The selection path is filled once with antialiasing to avoid internal seams. Geometry is computed from horizontal spans of visible lines without allocating a bitmap the size of the document. One context line above and below the viewport prevents artificial rounded corners at clipping edges. Unselected gaps, enclosed gaps, and disconnected spans in bidirectional text remain distinct.

Caches use logical line indices. Every edit adjusts both layouts and semantic styles using the previous line range and the change in line count. All edits must pass through the view's transaction methods. Font, tab-width, and appearance changes clear layout caches while preserving reusable semantic styles. Highlight results are checked by revision and highlighter generation, then compared by line style; the global revision does not invalidate every `CTLine`.

## Supported editing features

- Core Text rendering, system monospaced fonts, font fallback, and light and dark appearances.
- Horizontal and vertical scrolling, fixed line numbers, current-line highlighting, and independent caret blinking.
- A scope guide at the opening line's indentation for the innermost multiline `()`, `[]`, or `{}` pair that encloses the whole selection, or the caret when nothing is selected. As in Xcode, a selection shows one guide; selected brackets belong to the selection, so selecting a block's brackets moves the guide to the enclosing pair. The guide covers the lines between the brackets and fades in and out over 6 points at each end. `showsScopeGuide` defaults to `YES`.
- Text insertion and deletion, configurable space or tab indentation, language-aware newlines and bracket completion, cut, copy, paste, undo, and redo.
- Mouse drag selection, double-click word selection, triple-click or gutter line selection, and selection autoscrolling.
- Native context menus with validated editing commands and delegate customization.
- HTTP and HTTPS link recognition, Command-hover underlines, and Command-click browser opening.
- Grapheme-boundary movement and deletion that preserve emoji, zero-width joiner sequences, and combining marks. CRLF is treated as one editing boundary.
- Arrow-key movement, Shift selection, Option word movement, Command line and document navigation, and page movement.
- Input-method marked text, commit, cancellation, and screen-coordinate queries. Each composition produces one undo transaction.
- Read-only mode, which keeps the caret, navigation, and selection while rejecting edits.
- Non-focusable mode (`focusable = NO`), independent of read-only mode: the view never becomes the first responder and draws no caret, current-line highlight, or scope guide, while mouse selection still works.
- Text and selection notifications, and basic accessibility text and selection interfaces.
- Viewport-first, incremental document search with literal, whole-word, case-sensitive, and regular expression matching, parallel background chunks, lazy wrapping navigation, and a Liquid Glass find bar.
- Optional JSON syntax highlighting, independent themes, background incremental parsing, viewport queries with prefetching, and horizontally bounded requests for long lines.

All public positions and `NSRange` values count UTF-16 code units. Line indices start at zero. LF and CRLF are preserved, and a trailing newline adds an empty final line. The optional parser adapter converts these coordinates to Tree-sitter byte positions.

## Validation

`script/test.sh` runs the Objective-C `SourceEditorChecks` and `SourceEditorTreeSitterChecks` executables. `script/test.sh --core-only` builds and runs the core checks without linking Tree-sitter. SwiftPM does not directly discover these Objective-C check cases, so `swift test` does not execute them.

The existing checks cover:

- 12,000 randomized replacements compared with `NSMutableString`, followed by 3,000 insertions to exercise buffer growth, line indexing, range reads, and snapshot independence.
- Emoji, combining marks, CRLF deletion, undo and redo, preferred-column vertical movement, indentation, and read-only mode.
- Soft Tab stops, independent indentation and tab widths, literal-tab layout updates, JSON and JavaScript bracket completion, existing closer reuse, generated-edit undo, literal insertion during keyboard handling, and composition exclusions.
- Custom bracket pairs and context providers, lexical escapes, comments, template expressions, regular expressions and division, bounded context reads, checkpoint reuse and invalidation, and independent snapshot identity.
- Marked-text updates, selection replacement, commit, cancellation, composition undo and redo, input ranges, and screen-coordinate queries.
- Scope-guide matching against an independent stack-based reference, randomized bracket sequences across chunk boundaries and scan limits, changes after edits, and rendered position and line coverage.
- Core Text grapheme hit testing, tab advances, unchanged-line cache reuse, and selection changes without layout reconstruction.
- Context-menu contents and action routing, selection preservation, undoable deletion, read-only validation, non-focusable behavior, delegate modification, replacement, suppression, and custom menu templates.
- URL detection with UTF-16 offsets and CRLF, punctuation boundaries, web-scheme filtering, glyph hit testing, underline pixels, layout reuse, read-only opening requests, and click cancellation. Browser requests are intercepted during automated checks.
- Visible-line cache bounds, local invalidation, scrolling, and drawing-surface sizing after shortening a 100,000-line document.
- File-backed buffers compared with `NSString` decoding across leaf boundaries that split multibyte sequences, randomized edits and snapshot independence, shared-node insertion, byte order marks, ill-formed UTF-8 replacement, empty files, file errors, and editor adoption.
- Fragmented layout of long lines: measurement bounded by the viewport, exact positions and hit testing across fragments, line-relative tab stops, fragment starts at grapheme cluster boundaries, token precedence across fragments, geometry reuse after edits and recoloring, viewport-bounded drawing and selection, horizontal scrolling to the end of the line, and bounded navigation and Return reads.
- Load time and memory footprint for a 64 MiB file-backed buffer, and layout timings for a line of about 8 million UTF-16 code units. These Debug measurements do not establish end-to-end latency.
- Storage construction and random insertion and deletion timings for a 100,000-line buffer. These Debug storage measurements do not establish end-to-end input latency.
- Search timings for a one-million-line document: a whole-document search, the editor's first viewport matches and complete results, and edit latency with and without a query.
- Search options, line anchors, UTF-16 match ranges, invalid patterns, and match limits; line-locality classification and line-by-line equivalence; synchronous viewport results, lazy navigation into unsearched text, background completion, random edits during a search, whole-document searches for multiline patterns, the background match limit, and highlight pixels confined to matching lines.
- Substitute highlighters, Core Text colors, unchanged-style cache reuse, stale-result rejection, highlighter removal, theme changes without parsing, and CRLF and UTF-16 edit coordinates; partial-line token application, viewport-first prefetching, colors on lines scrolled into view, superseded results for the current revision, and horizontally bounded long-line requests.
- 120 randomized Unicode and newline edits to a JSON document, comparing incremental and complete parses after every edit, including incomplete syntax.
- Emoji at input chunk boundaries, range queries in a 20,000-line document, multiple-range queries with deduplicated spanning captures, parse reuse during scrolling, multiline captures, document identity, highlighting a minified 2-million-code-unit line in an editor, request coalescing, and cancellation.

Protocol checks do not establish real input-method behavior. Candidate-window placement and continuous composition with Chinese and Japanese input methods require manual testing. Visual rendering, native shortcuts, Unicode paste, and horizontal scrolling also require application-level review when affected by a change.

## Limitations and planned work

1. **Input and performance validation.** Test candidate-window placement, selection replacement, and cancellation with real Chinese Pinyin and Japanese input methods. Use Instruments to measure input and scrolling frame times and record median and 95th-percentile input-to-display latency. Ordinary typing currently records one undo operation per insertion; native typing coalescing and a memory budget for large paste history remain planned.
2. **Long lines and large files.** Measuring a whole long line, for example by moving to its end, takes time proportional to its length: about 0.2 seconds for 8 million ASCII code units and about 2 seconds for 2 million code units of mixed scripts in optimized builds. The document width is an estimate until a line is measured, grows with visited lines, and can remain wider than necessary after local deletions. The parser still processes complete lines, the first parse of a document must finish before any colors appear, and accessibility values and searches for patterns that can cross lines materialize the complete document.
3. **Soft wrapping and bidirectional editing.** Layout currently uses unwrapped logical lines. Soft wrapping requires visual-line and height indices plus width-aware invalidation. Mixed-direction visual movement, caret affinity, and detailed selection behavior also need further work beyond system text shaping.
4. **Language services.** Extend the optional highlighting interface for additional parsers and languages before adding diagnostics, completion, Language Server Protocol support, or multiple carets.

Scope guides match bracket characters, including those in strings and comments. Each selection change scans at most 131,072 UTF-16 code units before the selection, and the selection plus at most 131,072 code units after it. Brackets beyond that limit do not produce a guide. Syntax-tree-based matching remains a possible extension.

A single line is the smallest unit of search, so a long line is searched as a whole. Patterns that can cross lines are searched as a complete, materialized document, which takes O(document length) time and memory and restarts after every edit. Background searching stops once 100,000 matches are known; the count can exceed that by the chunks already in progress, and navigation and edits still search the lines they need. Matches are not adjusted to grapheme boundaries, so a search for a base letter can match inside a combined character sequence. Replace is not implemented.

Standalone CR line endings, rectangular selection, code folding, language services, and complete VoiceOver parameterized navigation are not implemented. Highlighting uses syntax structure without scope binding or embedded-language parsing. Tree-sitter uses 32-bit byte coordinates. Unsupported document sizes, more than 20,000 captures in one query, or queries exceeding the match limit produce plain text for the requested range. Performance and interaction coverage require further validation before comparison with established editors.

References: [Core Text hit testing](https://developer.apple.com/documentation/coretext/ctlinegetstringindexforposition(_:_:)), [NSTextInputClient](https://developer.apple.com/documentation/appkit/nstextinputclient?language=objc), and [SwiftPM PackageDescription](https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html).
