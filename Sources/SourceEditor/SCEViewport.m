#import "SCEViewport.h"
#import <math.h>

@implementation SCEViewport

+ (NSRange)lineRangeForVisibleRect:(CGRect)rect
                         lineCount:(NSUInteger)lineCount
                        lineHeight:(CGFloat)lineHeight
                          topInset:(CGFloat)topInset
                          overscan:(NSUInteger)overscan {
    if (!lineCount || lineHeight <= 0 || CGRectIsEmpty(rect)) {
        return NSMakeRange(0, 0);
    }
    CGFloat firstValue = floor(MAX(0, CGRectGetMinY(rect) - topInset) / lineHeight);
    CGFloat lastValue = ceil(MAX(0, CGRectGetMaxY(rect) - topInset) / lineHeight);
    NSUInteger first = (NSUInteger)MIN(firstValue, (CGFloat)(lineCount - 1));
    NSUInteger end = (NSUInteger)MIN(lastValue + 1, (CGFloat)lineCount);
    first = first > overscan ? first - overscan : 0;
    end += MIN(overscan, lineCount - end);
    return NSMakeRange(first, end - first);
}

@end
