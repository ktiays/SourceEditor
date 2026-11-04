#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Unions axis-aligned selection rectangles, traces their exposed contours and
/// rounds every convex/concave turn with G2-continuous cubic pairs. Real holes
/// and disconnected components remain separate. The caller owns the result.
CGPathRef SECreateSelectionPath(NSArray<NSValue *> *rects, CGFloat cornerRadius) CF_RETURNS_RETAINED;

NS_ASSUME_NONNULL_END
