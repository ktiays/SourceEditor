#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>
#import "include/SCETextBuffer.h"
#import "include/SCESyntaxTheme.h"

NS_ASSUME_NONNULL_BEGIN

@interface SCELineLayout : NSObject
@property (nonatomic, readonly) CTLineRef line;
@property (nonatomic, readonly, copy) NSString *text;
@property (nonatomic, readonly) CGFloat width;

- (CGFloat)xForUTF16Index:(NSUInteger)index;

- (NSUInteger)UTF16IndexForX:(CGFloat)x;
/// Rectangles in line-local coordinates, with y = 0 and the requested height.
- (NSArray<NSValue *> *)selectionRectsForUTF16Range:(NSRange)range height:(CGFloat)height;
@end

@interface SCELineLayoutCache : NSObject
- (instancetype)initWithBuffer:(SCETextBuffer *)buffer font:(NSFont *)font;
@property (nonatomic, copy) NSFont *font;
@property (nonatomic, copy) NSColor *textColor;
@property (nonatomic) NSUInteger tabWidth;
@property (nonatomic, copy) SCESyntaxTheme *syntaxTheme;
@property (nonatomic, strong, nullable) NSAppearance *appearance;
@property (nonatomic, readonly) NSUInteger cachedLineCount;
@property (nonatomic, readonly) NSUInteger totalLayoutBuildCount;

- (SCELineLayout *)layoutForLineAtIndex:(NSUInteger)lineIndex;

/// Updates the cache after the buffer replaced `range` of `previousBuffer`, a
/// snapshot taken before the edit, with `replacementLength` UTF-16 units.
/// Layouts of edited lines are discarded and later lines move with the change in
/// line count. Syntax tokens of edited lines are remapped into the edited text so
/// that the previous colors stay visible until a new highlight result arrives.
- (void)invalidateForReplacementOfUTF16Range:(NSRange)range
                           replacementLength:(NSUInteger)replacementLength
                              previousBuffer:(SCETextBuffer *)previousBuffer;

- (void)retainLinesInRange:(NSRange)range;

- (void)removeAllLayouts;

/// Returns whether any line's presentation actually changed.
- (BOOL)applySyntaxTokens:(NSArray<SCESyntaxToken *> *)tokens toLineRange:(NSRange)lineRange;

- (void)removeAllSyntaxTokens;
@end

NS_ASSUME_NONNULL_END
