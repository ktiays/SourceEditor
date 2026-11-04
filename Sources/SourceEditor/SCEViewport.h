#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Computes visible-line geometry independently of text storage and Core Text.
@interface SCEViewport : NSObject
+ (NSRange)lineRangeForVisibleRect:(CGRect)rect
                         lineCount:(NSUInteger)lineCount
                        lineHeight:(CGFloat)lineHeight
                          topInset:(CGFloat)topInset
                          overscan:(NSUInteger)overscan;
@end

NS_ASSUME_NONNULL_END
