#import <AppKit/AppKit.h>
#import "SCETextBuffer.h"
#import "SCESyntaxHighlighting.h"
#import "SCESyntaxTheme.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const SCEEditorTextDidChangeNotification;
FOUNDATION_EXPORT NSNotificationName const SCEEditorSelectionDidChangeNotification;
FOUNDATION_EXPORT NSNotificationName const SCEEditorSyntaxHighlightingDidUpdateNotification;

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
