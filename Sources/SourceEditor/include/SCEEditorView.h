#import <AppKit/AppKit.h>
#import "SCETextBuffer.h"
#import "SCESyntaxHighlighting.h"
#import "SCESyntaxTheme.h"
#import "SCETextSearch.h"
#import "SCELanguageConfiguration.h"

NS_ASSUME_NONNULL_BEGIN

@class SCEEditorView;

typedef NS_ENUM(NSUInteger, SCEBracketCompletionMode) {
    SCEBracketCompletionModeDisabled,
    SCEBracketCompletionModeOnNewline,
    SCEBracketCompletionModeWhileTyping,
};

@protocol SCEEditorViewDelegate <NSObject>
@optional
/// Called on the main thread after the context-click selection is established.
/// Modify and return menu, return a replacement, or return nil to suppress it.
/// Menu items supplied by the editor target that editor directly.
- (nullable NSMenu *)editorView:(SCEEditorView *)editorView menu:(NSMenu *)menu forEvent:(NSEvent *)event;
@end

FOUNDATION_EXPORT NSNotificationName const SCEEditorTextDidChangeNotification;
FOUNDATION_EXPORT NSNotificationName const SCEEditorSelectionDidChangeNotification;
FOUNDATION_EXPORT NSNotificationName const SCEEditorSyntaxHighlightingDidUpdateNotification;
/// Posted on the main thread when search results change, including progress of a
/// background search, at most once per main queue turn while it runs.
FOUNDATION_EXPORT NSNotificationName const SCEEditorSearchResultsDidChangeNotification;

/// An AppKit document view that renders plain text with Core Text.
/// Assign it to an NSScrollView's documentView or use +scrollableEditorView.
/// As the document view, the editor sets the scroll view's left scroller inset
/// to the width of the line-number gutter and updates it when that width
/// changes, so the horizontal scroller spans only the text. It leaves the other
/// scroller insets unchanged and resets the left inset when it leaves the
/// scroll view.
/// Access the view on the main thread. All ranges count UTF-16 code units.
@interface SCEEditorView : NSView <NSTextInputClient, NSUserInterfaceValidations>

+ (NSScrollView *)scrollableEditorView;

/// Reading this materializes the document. Setting it resets selection and undo.
@property (nonatomic, copy) NSString *string;
@property (nonatomic, copy) NSFont *font;
@property (nonatomic) NSRange selectedRange;
@property (nonatomic, getter=isEditable) BOOL editable;
/// Whether the view can become the first responder. When NO, the view never
/// takes keyboard focus and resigns it if it has it, and it draws no caret,
/// current-line highlight or scope guide. Mouse selection still works, and the
/// selection is drawn in the inactive color. Independent of `editable`.
/// Defaults to YES.
@property (nonatomic, getter=isFocusable) BOOL focusable;
@property (nonatomic) BOOL showsLineNumbers;
/// Draws a vertical guide through the lines inside the innermost (), [] or {}
/// pair that encloses the whole selection, or the caret when the selection is
/// empty, at the opening line's indentation. Selected brackets belong to the
/// selection, so selecting a block's brackets moves the guide to the enclosing
/// pair. A guide requires at least one line between the brackets, and its ends
/// fade in and out. Defaults to YES.
@property (nonatomic) BOOL showsScopeGuide;
/// The opening through closing bracket the guide is drawn for, or
/// {NSNotFound, 0}. Character matching includes brackets in strings and comments.
/// The search is bounded around the selection.
@property (nonatomic, readonly) NSRange scopeGuideBracketRange;
/// Distance between literal tab stops in space columns. Defaults to 4 and is
/// clamped to 1...32. Changing it affects layout without rewriting text.
@property (nonatomic) NSUInteger tabWidth;
/// Columns per indentation level and soft Tab stop. Defaults to 0, which follows
/// tabWidth. Explicit values are clamped to 1...32.
@property (nonatomic) NSUInteger indentationWidth;
/// Tab inserts spaces to the next indentation stop when YES, or one literal tab
/// when NO. Generated leading indentation uses spaces, or tabs plus any remaining
/// spaces, respectively. Defaults to YES. Existing text and paste are preserved.
@property (nonatomic) BOOL insertsSpacesForTabs;
/// Return inherits indentation and applies the language's newline rules. When
/// NO, Return inserts only the document's newline sequence. Defaults to YES.
@property (nonatomic, getter=isAutomaticIndentationEnabled) BOOL automaticIndentationEnabled;
/// Defaults to Disabled. OnNewline generates a closer on Return after an unmatched
/// eligible opener when only whitespace follows the caret on its line. An enclosing
/// block's closer does not match the new opener. WhileTyping also pairs
/// single-character keyboard input, nesting inside any existing pair, and advances
/// over an adjacent closer that it generated while the caret remains on that line.
/// Paste, explicit text replacements, nonempty selections, and marked-text
/// composition do not pair.
@property (nonatomic) SCEBracketCompletionMode bracketCompletionMode;
/// Optional immutable language rules. Defaults to nil. Independent of the syntax
/// highlighter; assigning rules preserves document text, selection, and undo.
@property (nonatomic, copy, nullable) SCELanguageConfiguration *languageConfiguration;
@property (nonatomic, readonly) NSUInteger lineCount;

/// Customizes each context menu. The editor does not retain its delegate.
/// An assigned NSView.menu is copied as the starting menu; otherwise the editor
/// supplies Cut, Copy, and Paste.
@property (nonatomic, weak, nullable) id<SCEEditorViewDelegate> delegate;
/// Recognizes HTTP and HTTPS links with Foundation's data detector. Defaults to
/// YES. Command-hover underlines a link; Command-click opens it in the default
/// browser without changing the selection. Available in read-only views too.
@property (nonatomic, getter=isAutomaticLinkDetectionEnabled) BOOL automaticLinkDetectionEnabled;

/// Returns the HTTP or HTTPS URL under point in the editor's document coordinates.
/// Only visible text is hit-tested; the gutter and empty space never match.
/// The optional range receives the link's UTF-16 range, or {NSNotFound, 0}.
/// Detection examines and caches one logical line, without reading self.string.
- (nullable NSURL *)URLAtPoint:(NSPoint)point effectiveRange:(nullable NSRangePointer)effectiveRange;

/// The default is nil, which enables plain text editing without a highlighter.
/// Use a separate highlighter instance for each editor and document.
@property (nonatomic, strong, nullable) id<SCESyntaxHighlighter> syntaxHighlighter;
@property (nonatomic, copy) SCESyntaxTheme *syntaxTheme;

/// The query whose matches the editor highlights, or nil. Setting a query searches
/// the visible lines immediately when they are short, then searches the rest of
/// the document in chunks on background queues, starting after the viewport.
/// When the query cannot match across lines, an edit searches only the edited
/// lines again and moves later matches with the text. A query that can match
/// across lines is searched as a whole document after each edit; until then,
/// matches outside the edited range move with the text.
@property (nonatomic, copy, nullable) SCETextSearchQuery *searchQuery;
/// YES while part of the document remains unsearched and searching continues.
@property (nonatomic, readonly, getter=isSearchPending) BOOL searchPending;
/// The pattern error of the current query, such as an invalid regular expression.
@property (nonatomic, readonly, nullable) NSError *searchError;
/// The number of known matches. Background searching stops once at least
/// SCETextSearchDefaultMaximumMatchCount matches are known.
@property (nonatomic, readonly) NSUInteger numberOfSearchMatches;
/// YES when background searching stopped at SCETextSearchDefaultMaximumMatchCount
/// with text left unsearched, so the match count is incomplete.
@property (nonatomic, readonly, getter=isSearchResultTruncated) BOOL searchResultTruncated;
/// The known matches in document order. Building the array is O(match count).
@property (nonatomic, readonly, copy) NSArray<NSValue *> *searchMatchRanges;
/// The index of the match equal to the selected range, or NSNotFound.
@property (nonatomic, readonly) NSUInteger currentSearchMatchIndex;

/// Selects and scrolls to the match after the selection, wrapping to the first
/// match. Unsearched text between the selection and that match is searched
/// synchronously first. Returns NO and keeps the selection when there are no matches.
- (BOOL)selectNextSearchMatch;

/// Selects and scrolls to the match before the selection, wrapping to the last
/// match. Unsearched text between them is searched synchronously first.
- (BOOL)selectPreviousSearchMatch;

/// O(1) immutable-node snapshot. The returned buffer can be edited independently.
- (SCETextBuffer *)bufferSnapshot;

/// Replaces the document with the text of buffer, like setting string, but shares
/// buffer's immutable storage instead of copying the text. Use it with
/// -[SCETextBuffer initWithContentsOfURL:error:] to open large files without
/// decoding them. Resets selection and undo. Later edits to either buffer do not
/// affect the other.
- (void)replaceContentsWithBuffer:(SCETextBuffer *)buffer;

- (void)scrollSelectionToVisible;

- (void)undo:(nullable id)sender;

- (void)redo:(nullable id)sender;

- (void)copy:(nullable id)sender;

- (void)cut:(nullable id)sender;

- (void)paste:(nullable id)sender;

/// Deletes the selection as one undoable edit. Does nothing at an empty caret.
- (void)delete:(nullable id)sender;

- (void)selectAll:(nullable id)sender;

@end

NS_ASSUME_NONNULL_END
