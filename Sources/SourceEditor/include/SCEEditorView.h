#import <AppKit/AppKit.h>
#import "SCETextBuffer.h"
#import "SCESyntaxHighlighting.h"
#import "SCESyntaxTheme.h"
#import "SCETextSearch.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const SCEEditorTextDidChangeNotification;
FOUNDATION_EXPORT NSNotificationName const SCEEditorSelectionDidChangeNotification;
FOUNDATION_EXPORT NSNotificationName const SCEEditorSyntaxHighlightingDidUpdateNotification;
/// Posted on the main thread after the editor applies or clears search results.
FOUNDATION_EXPORT NSNotificationName const SCEEditorSearchResultsDidChangeNotification;

/// An AppKit document view that renders plain text with Core Text.
/// Assign it to an NSScrollView's documentView or use +scrollableEditorView.
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
/// pair around the caret, at the opening line's indentation. A guide requires
/// at least one line between the brackets. Defaults to YES.
@property (nonatomic) BOOL showsScopeGuide;
/// The opening through closing bracket the guide is drawn for, or
/// {NSNotFound, 0}. Character matching includes brackets in strings and comments.
/// The search is bounded around the caret.
@property (nonatomic, readonly) NSRange scopeGuideBracketRange;
@property (nonatomic) NSUInteger tabWidth;
@property (nonatomic, getter=isAutomaticIndentationEnabled) BOOL automaticIndentationEnabled;
@property (nonatomic, readonly) NSUInteger lineCount;

/// The default is nil, which enables plain text editing without a highlighter.
/// Use a separate highlighter instance for each editor and document.
@property (nonatomic, strong, nullable) id<SCESyntaxHighlighter> syntaxHighlighter;
@property (nonatomic, copy) SCESyntaxTheme *syntaxTheme;

/// The query whose matches the editor highlights, or nil. Setting a query starts
/// a search of a buffer snapshot on a private serial queue; results are applied
/// on the main thread only when the document revision is unchanged. After each
/// edit, existing matches outside the edited range move with the text and a new
/// search starts. Previous matches stay visible until new results arrive.
@property (nonatomic, copy, nullable) SCETextSearchQuery *searchQuery;
/// YES while a search for the current query and document revision is in progress.
@property (nonatomic, readonly, getter=isSearchPending) BOOL searchPending;
/// The error from the latest search, such as an invalid regular expression.
@property (nonatomic, readonly, nullable) NSError *searchError;
/// The number of highlighted matches, at most SCETextSearchDefaultMaximumMatchCount.
@property (nonatomic, readonly) NSUInteger numberOfSearchMatches;
/// YES when the latest search stopped at SCETextSearchDefaultMaximumMatchCount.
@property (nonatomic, readonly, getter=isSearchResultTruncated) BOOL searchResultTruncated;
/// The highlighted matches in document order. Building the array is O(match count).
@property (nonatomic, readonly, copy) NSArray<NSValue *> *searchMatchRanges;
/// The index of the match equal to the selected range, or NSNotFound.
@property (nonatomic, readonly) NSUInteger currentSearchMatchIndex;

/// Selects and scrolls to the match after the selection, wrapping to the first
/// match. When results are pending, searches synchronously first. Returns NO and
/// keeps the selection when there are no matches.
- (BOOL)selectNextSearchMatch;

/// Selects and scrolls to the match before the selection, wrapping to the last match.
- (BOOL)selectPreviousSearchMatch;

/// O(1) immutable-node snapshot. The returned buffer can be edited independently.
- (SCETextBuffer *)bufferSnapshot;

- (void)scrollSelectionToVisible;

- (void)undo:(nullable id)sender;

- (void)redo:(nullable id)sender;

- (void)copy:(nullable id)sender;

- (void)cut:(nullable id)sender;

- (void)paste:(nullable id)sender;

- (void)selectAll:(nullable id)sender;

@end

NS_ASSUME_NONNULL_END
