#import <AppKit/AppKit.h>
#import "SCESyntaxHighlighting.h"

NS_ASSUME_NONNULL_BEGIN

/// Immutable presentation policy. Highlighters do not own fonts or colors.
@interface SCESyntaxTheme : NSObject <NSCopying>
+ (instancetype)defaultTheme;

- (instancetype)initWithForegroundColors:(NSDictionary<SCESyntaxTokenKind, NSColor *> *)colors;

- (nullable NSColor *)foregroundColorForKind:(SCESyntaxTokenKind)kind;
@property (nonatomic, readonly, copy) NSDictionary<SCESyntaxTokenKind, NSColor *> *foregroundColors;
@end

NS_ASSUME_NONNULL_END
