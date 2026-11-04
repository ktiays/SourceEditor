#import <AppKit/AppKit.h>
#import "SETextBuffer.h"
#import "SESyntaxHighlighting.h"
#import "SESyntaxTheme.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const SEEditorTextDidChangeNotification;
FOUNDATION_EXPORT NSNotificationName const SEEditorSelectionDidChangeNotification;
FOUNDATION_EXPORT NSNotificationName const SEEditorSyntaxHighlightingDidUpdateNotification;

/// A plain-text AppKit document view, rendered with Core Text. Embed it as the
/// documentView of an NSScrollView, or use +scrollableEditorView.
/// Use on the main thread. All ranges count UTF-16 code units.
@interface SEEditorView : NSView <NSTextInputClient, NSUserInterfaceValidations>

+ (NSScrollView *)scrollableEditorView;

/// Reading this materializes the document. Setting it resets selection and undo.
@property (nonatomic, copy) NSString *string;
@property (nonatomic, copy) NSFont *font;
@property (nonatomic) NSRange selectedRange;
@property (nonatomic, getter=isEditable) BOOL editable;
@property (nonatomic) BOOL showsLineNumbers;
/// Draws a vertical guide through the lines inside the innermost (), [] or {}
/// pair around the caret, at the opening line's indentation. Only pairs with at
/// least one line between their brackets get a guide. Defaults to YES.
@property (nonatomic) BOOL showsScopeGuide;
/// The opening through closing bracket the guide is drawn for, or
/// {NSNotFound, 0}. Brackets are matched by character, so ones inside strings
/// and comments count too; the search is bounded around the caret.
@property (nonatomic, readonly) NSRange scopeGuideBracketRange;
@property (nonatomic) NSUInteger tabWidth;
@property (nonatomic) BOOL automaticIndentationEnabled;
@property (nonatomic, readonly) NSUInteger lineCount;

/// Optional. Nil is the default and keeps this view a standalone plain editor.
/// A provider belongs to one document/view; use a separate instance per editor.
@property (nonatomic, strong, nullable) id<SESyntaxHighlighter> syntaxHighlighter;
@property (nonatomic, copy) SESyntaxTheme *syntaxTheme;

/// O(1) immutable-node snapshot. The returned buffer can be edited independently.
- (SETextBuffer *)bufferSnapshot;

- (void)scrollSelectionToVisible;

- (void)undo:(nullable id)sender;

- (void)redo:(nullable id)sender;

- (void)copy:(nullable id)sender;

- (void)cut:(nullable id)sender;

- (void)paste:(nullable id)sender;

- (void)selectAll:(nullable id)sender;

@end

NS_ASSUME_NONNULL_END
