#import "include/SCESyntaxTheme.h"

@implementation SCESyntaxTheme

+ (instancetype)defaultTheme {
    static SCESyntaxTheme *theme;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        theme = [[self alloc] initWithForegroundColors:@{
            SCESyntaxTokenComment : NSColor.secondaryLabelColor,
            SCESyntaxTokenString : NSColor.systemRedColor,
            SCESyntaxTokenEscape : NSColor.systemOrangeColor,
            SCESyntaxTokenNumber : NSColor.systemBlueColor,
            SCESyntaxTokenKeyword : NSColor.systemPurpleColor,
            SCESyntaxTokenFunction : NSColor.systemBrownColor,
            SCESyntaxTokenType : NSColor.systemIndigoColor,
            SCESyntaxTokenProperty : NSColor.systemTealColor,
            SCESyntaxTokenVariable : NSColor.textColor,
            SCESyntaxTokenOperator : NSColor.textColor,
            SCESyntaxTokenPunctuation : NSColor.secondaryLabelColor,
        }];
    });
    return theme;
}

- (instancetype)initWithForegroundColors:(NSDictionary<SCESyntaxTokenKind, NSColor *> *)colors {
    if ((self = [super init])) {
        _foregroundColors = [colors copy];
    }
    return self;
}

- (NSColor *)foregroundColorForKind:(SCESyntaxTokenKind)kind {
    NSColor *color = _foregroundColors[kind];
    while (!color) {
        NSRange separator = [kind rangeOfString:@"." options:NSBackwardsSearch];
        if (separator.location == NSNotFound) {
            break;
        }
        kind = [kind substringToIndex:separator.location];
        color = _foregroundColors[kind];
    }
    return color;
}

- (id)copyWithZone:(NSZone *)zone {
    return self;
}

@end
