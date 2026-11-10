#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>
#import "include/SCETextBuffer.h"
#import "include/SCESyntaxTheme.h"

NS_ASSUME_NONNULL_BEGIN

/// Lines longer than this many UTF-16 code units are laid out in fragments.
FOUNDATION_EXPORT const NSUInteger SCELineLayoutMaximumUnfragmentedLength;
/// The nominal UTF-16 length of one fragment of a long line.
FOUNDATION_EXPORT const NSUInteger SCELineLayoutFragmentLength;

/// The Core Text layout of one logical line, in line-local coordinates: x = 0 is
/// the start of the line and offsets count UTF-16 code units from the line start.
///
/// A line up to SCELineLayoutMaximumUnfragmentedLength is one CTLine. A longer
/// line is divided into fragments of about SCELineLayoutFragmentLength, preferably
/// after a space or tab and always at a grapheme cluster boundary, and each
/// fragment is a CTLine positioned after the fragments before it. Fragments are
/// laid out on demand, left to right, because a fragment's position is the sum of
/// the widths before it and tabs depend on that position. Only a few fragment
/// CTLines are retained, so the cost of drawing, hit testing and caret placement
/// depends on the fragments involved rather than on the line length. Shaping and
/// bidirectional reordering do not cross fragment boundaries, and each fragment of
/// a long line uses a left-to-right base direction.
///
/// Methods that take a maximum x measure fragments only up to that position, so
/// they are suitable for the viewport. Other methods measure the line up to the
/// requested index. Use on the main thread.
@interface SCELineLayout : NSObject
/// The UTF-16 length of the line content, excluding its line ending.
@property (nonatomic, readonly) NSUInteger length;
/// The CTLine of a single-fragment layout, or NULL for a fragmented long line.
@property (nonatomic, readonly, nullable) CTLineRef line;
@property (nonatomic, readonly) NSUInteger fragmentCount;
/// The number of leading fragments whose widths are known.
@property (nonatomic, readonly) NSUInteger measuredFragmentCount;
/// The exact typographic width. For a fragmented line, this measures every fragment.
@property (nonatomic, readonly) CGFloat width;
/// The exact width once every fragment is measured; otherwise the measured width
/// plus an estimate for the remaining text based on the measured average advance.
/// Reading it never lays out text.
@property (nonatomic, readonly) CGFloat estimatedWidth;

- (CGFloat)xForUTF16Index:(NSUInteger)index;

/// Returns MIN([self xForUTF16Index:index], maximumX) and measures fragments only
/// until their positions reach maximumX.
- (CGFloat)xForUTF16Index:(NSUInteger)index clampedToMaximumX:(CGFloat)maximumX;

- (NSUInteger)UTF16IndexForX:(CGFloat)x;

/// Rectangles in line-local coordinates, with y = 0 and the requested height.
- (NSArray<NSValue *> *)selectionRectsForUTF16Range:(NSRange)range height:(CGFloat)height;

/// Returns the rectangles that may intersect minimumX...maximumX. Fragments that
/// start at or after maximumX are neither measured nor included, and fragments
/// entirely before minimumX are measured but not laid out for drawing. The
/// rectangles are not clipped to the interval.
- (NSArray<NSValue *> *)selectionRectsForUTF16Range:(NSRange)range
                                             height:(CGFloat)height
                                           minimumX:(CGFloat)minimumX
                                           maximumX:(CGFloat)maximumX;

/// Draws the fragments that intersect minimumX...maximumX in a flipped context.
/// origin is the start of the line on its baseline, in context coordinates.
- (void)drawInContext:(CGContextRef)context
     atBaselineOrigin:(CGPoint)origin
             minimumX:(CGFloat)minimumX
             maximumX:(CGFloat)maximumX;

/// The CTLine of the fragment that contains index, laid out with syntax colors.
/// The fragment's line-local start is returned in fragmentStart.
- (CTLineRef)lineOfFragmentContainingUTF16Index:(NSUInteger)index fragmentStart:(NSUInteger *_Nullable)fragmentStart;
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
