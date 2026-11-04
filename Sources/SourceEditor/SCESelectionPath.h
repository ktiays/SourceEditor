#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Forms the union of selection rectangles and rounds the exposed contours
/// with continuous-curvature cubic curve pairs. Enclosed gaps and disconnected
/// selection regions remain separate. The caller owns the returned path.
FOUNDATION_EXPORT CGPathRef SCECreateSelectionPath(NSArray<NSValue *> *rectangles,
                                                   CGFloat cornerRadius) CF_RETURNS_RETAINED;

NS_ASSUME_NONNULL_END
