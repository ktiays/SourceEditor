#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

/// Geometry only. This module has no dependency on Core Text or text storage.
@interface SEViewport : NSObject
+ (NSRange)lineRangeForVisibleRect:(CGRect)rect
                         lineCount:(NSUInteger)lineCount
                        lineHeight:(CGFloat)lineHeight
                          topInset:(CGFloat)topInset
                          overscan:(NSUInteger)overscan;
@end
