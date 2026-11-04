#import <AppKit/AppKit.h>
#import "SESyntaxHighlighting.h"

NS_ASSUME_NONNULL_BEGIN

/// Immutable presentation policy. Highlighters do not own fonts or colors.
@interface SESyntaxTheme : NSObject <NSCopying>
+ (instancetype)defaultTheme;

- (instancetype)initWithForegroundColors:(NSDictionary<SESyntaxTokenKind, NSColor *> *)colors;

- (nullable NSColor *)foregroundColorForKind:(SESyntaxTokenKind)kind;
@property (nonatomic, readonly, copy) NSDictionary<SESyntaxTokenKind, NSColor *> *foregroundColors;
@end

NS_ASSUME_NONNULL_END
