#import "include/SCEBracketPair.h"

@implementation SCEBracketPair

- (instancetype)initWithOpeningCharacter:(unichar)openingCharacter
                        closingCharacter:(unichar)closingCharacter
                        expandsOnNewline:(BOOL)expandsOnNewline {
    NSCharacterSet *invalid = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    if (openingCharacter == closingCharacter || openingCharacter == 0 || closingCharacter == 0 ||
        (openingCharacter >= 0xd800 && openingCharacter <= 0xdfff) ||
        (closingCharacter >= 0xd800 && closingCharacter <= 0xdfff) || [invalid characterIsMember:openingCharacter] ||
        [invalid characterIsMember:closingCharacter]) {
        [NSException raise:NSInvalidArgumentException
                    format:@"Bracket characters must be distinct, non-whitespace BMP characters."];
    }
    if ((self = [super init])) {
        _openingCharacter = openingCharacter;
        _closingCharacter = closingCharacter;
        _expandsOnNewline = expandsOnNewline;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    return self;
}

@end
