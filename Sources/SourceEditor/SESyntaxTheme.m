#import "include/SESyntaxTheme.h"

@implementation SESyntaxTheme

+ (instancetype)defaultTheme {
    static SESyntaxTheme *theme;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        theme = [[self alloc] initWithForegroundColors:@{
            SESyntaxTokenComment : NSColor.secondaryLabelColor,
            SESyntaxTokenString : NSColor.systemRedColor,
            SESyntaxTokenEscape : NSColor.systemOrangeColor,
            SESyntaxTokenNumber : NSColor.systemBlueColor,
            SESyntaxTokenKeyword : NSColor.systemPurpleColor,
            SESyntaxTokenFunction : NSColor.systemBrownColor,
            SESyntaxTokenType : NSColor.systemIndigoColor,
            SESyntaxTokenProperty : NSColor.systemTealColor,
            SESyntaxTokenVariable : NSColor.textColor,
            SESyntaxTokenOperator : NSColor.textColor,
            SESyntaxTokenPunctuation : NSColor.secondaryLabelColor,
        }];
    });
    return theme;
}

- (instancetype)initWithForegroundColors:(NSDictionary<SESyntaxTokenKind, NSColor *> *)colors {
    if ((self = [super init]))
        _foregroundColors = [colors copy];
    return self;
}

- (NSColor *)foregroundColorForKind:(SESyntaxTokenKind)kind {
    NSColor *color = _foregroundColors[kind];
    while (!color) {
        NSRange separator = [kind rangeOfString:@"." options:NSBackwardsSearch];
        if (separator.location == NSNotFound)
            break;
        kind = [kind substringToIndex:separator.location];
        color = _foregroundColors[kind];
    }
    return color;
}

- (id)copyWithZone:(NSZone *)zone {
    return self;
}

@end
