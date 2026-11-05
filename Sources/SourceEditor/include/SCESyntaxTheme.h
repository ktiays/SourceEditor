#import <AppKit/AppKit.h>
#import "SCESyntaxHighlighting.h"

NS_ASSUME_NONNULL_BEGIN

/// A color the editor draws outside syntax tokens.
typedef NSString *SCEEditorColorKey NS_TYPED_EXTENSIBLE_ENUM;

/// The text area. Defaults to the text background color. A translucent or clear color shows
/// what is behind the editor, which must then not draw a background of its own.
FOUNDATION_EXPORT SCEEditorColorKey const SCEEditorColorBackground;
/// Text without a token color. Defaults to the text color.
FOUNDATION_EXPORT SCEEditorColorKey const SCEEditorColorText;
/// The line number gutter. Defaults to the window background color.
FOUNDATION_EXPORT SCEEditorColorKey const SCEEditorColorGutterBackground;
/// Line numbers. Defaults to the secondary label color.
FOUNDATION_EXPORT SCEEditorColorKey const SCEEditorColorLineNumber;
/// The caret line's highlight. Defaults to the background blended slightly toward the text.
FOUNDATION_EXPORT SCEEditorColorKey const SCEEditorColorCurrentLine;
/// The selection while the editor has focus. Defaults to the selected text background color.
FOUNDATION_EXPORT SCEEditorColorKey const SCEEditorColorSelection;
/// The selection while the editor does not have focus. Defaults to the selection color at
/// reduced opacity when a selection color is set, else to the unemphasized selection color.
FOUNDATION_EXPORT SCEEditorColorKey const SCEEditorColorInactiveSelection;
/// The caret. Defaults to the control accent color, and then follows changes to the system
/// accent color.
FOUNDATION_EXPORT SCEEditorColorKey const SCEEditorColorCaret;
/// The bracket scope guide. Defaults to the tertiary label color.
FOUNDATION_EXPORT SCEEditorColorKey const SCEEditorColorScopeGuide;
/// The fill of search matches other than the current one. Defaults to translucent system yellow.
FOUNDATION_EXPORT SCEEditorColorKey const SCEEditorColorSearchMatch;
/// The fill of the current search match. Defaults to the translucent find highlight color.
FOUNDATION_EXPORT SCEEditorColorKey const SCEEditorColorCurrentSearchMatch;
/// The outline of the current search match. Defaults to system yellow.
FOUNDATION_EXPORT SCEEditorColorKey const SCEEditorColorCurrentSearchMatchBorder;

/// Immutable presentation policy. Highlighters do not own fonts or colors.
@interface SCESyntaxTheme : NSObject <NSCopying>
+ (instancetype)defaultTheme;

- (instancetype)initWithForegroundColors:(NSDictionary<SCESyntaxTokenKind, NSColor *> *)colors;
/// Editor colors that are absent use the defaults described by their keys.
- (instancetype)initWithForegroundColors:(NSDictionary<SCESyntaxTokenKind, NSColor *> *)colors
                            editorColors:(NSDictionary<SCEEditorColorKey, NSColor *> *)editorColors
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (nullable NSColor *)foregroundColorForKind:(SCESyntaxTokenKind)kind;
/// The color the theme sets for `key`, or nil for the default.
- (nullable NSColor *)editorColorForKey:(SCEEditorColorKey)key;
@property (nonatomic, readonly, copy) NSDictionary<SCESyntaxTokenKind, NSColor *> *foregroundColors;
@property (nonatomic, readonly, copy) NSDictionary<SCEEditorColorKey, NSColor *> *editorColors;
@end

NS_ASSUME_NONNULL_END
