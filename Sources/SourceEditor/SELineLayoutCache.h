#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>
#import "include/SETextBuffer.h"
#import "include/SESyntaxTheme.h"

NS_ASSUME_NONNULL_BEGIN

@interface SELineLayout : NSObject
@property (nonatomic, readonly) CTLineRef line;
@property (nonatomic, readonly) NSString *text;
@property (nonatomic, readonly) CGFloat width;

- (CGFloat)xForUTF16Index:(NSUInteger)index;

- (NSUInteger)UTF16IndexForX:(CGFloat)x;
/// Rectangles in line-local coordinates, with y = 0 and the requested height.
- (NSArray<NSValue *> *)selectionRectsForUTF16Range:(NSRange)range height:(CGFloat)height;
@end

@interface SELineLayoutCache : NSObject
- (instancetype)initWithBuffer:(SETextBuffer *)buffer font:(NSFont *)font;
@property (nonatomic, copy) NSFont *font;
@property (nonatomic, copy) NSColor *textColor;
@property (nonatomic) NSUInteger tabWidth;
@property (nonatomic, copy) SESyntaxTheme *syntaxTheme;
@property (nonatomic, strong, nullable) NSAppearance *appearance;
@property (nonatomic, readonly) NSUInteger cachedLineCount;
@property (nonatomic, readonly) NSUInteger totalLayoutBuildCount;

- (SELineLayout *)layoutForLineAtIndex:(NSUInteger)lineIndex;

- (void)invalidateLinesInRange:(NSRange)oldLineRange lineDelta:(NSInteger)delta;

- (void)retainLinesInRange:(NSRange)range;

- (void)removeAllLayouts;

/// Returns whether any line's presentation actually changed.
- (BOOL)applySyntaxTokens:(NSArray<SESyntaxToken *> *)tokens toLineRange:(NSRange)lineRange;

- (void)removeAllSyntaxTokens;
@end

NS_ASSUME_NONNULL_END
