#import "include/SCELanguageConfiguration.h"
#import "SCELanguageConfigurationInternal.h"
#import "SCELexicalContextProvider.h"

@implementation SCELanguageConfiguration {
    id<SCELanguageContextProvider> _contextProvider;
}

+ (instancetype)languageConfigurationForJSON {
    return [[self alloc] initWithBracketPairs:@[
        [[SCEBracketPair alloc] initWithOpeningCharacter:'{' closingCharacter:'}' expandsOnNewline:YES],
        [[SCEBracketPair alloc] initWithOpeningCharacter:'[' closingCharacter:']' expandsOnNewline:YES],
    ]
                              contextProvider:[[SCELexicalContextProvider alloc] initWithJavaScriptEnabled:NO]];
}

+ (instancetype)languageConfigurationForJavaScript {
    return [[self alloc] initWithBracketPairs:@[
        [[SCEBracketPair alloc] initWithOpeningCharacter:'{' closingCharacter:'}' expandsOnNewline:YES],
        [[SCEBracketPair alloc] initWithOpeningCharacter:'[' closingCharacter:']' expandsOnNewline:YES],
        [[SCEBracketPair alloc] initWithOpeningCharacter:'(' closingCharacter:')' expandsOnNewline:NO],
    ]
                              contextProvider:[[SCELexicalContextProvider alloc] initWithJavaScriptEnabled:YES]];
}

- (instancetype)initWithBracketPairs:(NSArray<SCEBracketPair *> *)bracketPairs
                     contextProvider:(id<SCELanguageContextProvider>)contextProvider {
    if (!bracketPairs || !contextProvider) {
        [NSException raise:NSInvalidArgumentException format:@"Bracket pairs and a context provider are required."];
    }
    NSMutableIndexSet *characters = [NSMutableIndexSet indexSet];
    for (SCEBracketPair *pair in bracketPairs) {
        if (![pair isKindOfClass:SCEBracketPair.class] || [characters containsIndex:pair.openingCharacter] ||
            [characters containsIndex:pair.closingCharacter]) {
            [NSException raise:NSInvalidArgumentException
                        format:@"Each bracket character must belong to exactly one pair."];
        }
        [characters addIndex:pair.openingCharacter];
        [characters addIndex:pair.closingCharacter];
    }
    if ((self = [super init])) {
        _bracketPairs = [[NSArray alloc] initWithArray:bracketPairs copyItems:YES];
        _contextProvider = contextProvider;
    }
    return self;
}

- (SCELanguageContext)contextAtUTF16Offset:(NSUInteger)offset inBuffer:(SCETextBuffer *)buffer {
    return [_contextProvider contextAtUTF16Offset:offset inBuffer:[buffer copy]];
}

- (void)invalidateContextForReplacementOfUTF16Range:(NSRange)range
                                     previousBuffer:(SCETextBuffer *)previousBuffer
                                        afterBuffer:(SCETextBuffer *)afterBuffer {
    if ([_contextProvider isKindOfClass:SCELexicalContextProvider.class]) {
        [(SCELexicalContextProvider *)_contextProvider invalidateForReplacementOfUTF16Range:range
                                                                             previousBuffer:previousBuffer
                                                                                afterBuffer:afterBuffer];
    }
}

- (id)copyWithZone:(NSZone *)zone {
    return self;
}

@end
