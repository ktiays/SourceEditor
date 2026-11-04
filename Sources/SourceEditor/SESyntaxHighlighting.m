#import "include/SESyntaxHighlighting.h"

SESyntaxTokenKind const SESyntaxTokenComment = @"comment";
SESyntaxTokenKind const SESyntaxTokenString = @"string";
SESyntaxTokenKind const SESyntaxTokenEscape = @"escape";
SESyntaxTokenKind const SESyntaxTokenNumber = @"number";
SESyntaxTokenKind const SESyntaxTokenKeyword = @"keyword";
SESyntaxTokenKind const SESyntaxTokenFunction = @"function";
SESyntaxTokenKind const SESyntaxTokenType = @"type";
SESyntaxTokenKind const SESyntaxTokenProperty = @"property";
SESyntaxTokenKind const SESyntaxTokenVariable = @"variable";
SESyntaxTokenKind const SESyntaxTokenOperator = @"operator";
SESyntaxTokenKind const SESyntaxTokenPunctuation = @"punctuation";

@implementation SESyntaxToken

- (instancetype)initWithRange:(NSRange)range kind:(SESyntaxTokenKind)kind {
    if ((self = [super init])) {
        _range = range;
        _kind = [kind copy];
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    return self;
}

- (BOOL)isEqual:(id)object {
    if (object == self)
        return YES;
    if (![object isKindOfClass:SESyntaxToken.class])
        return NO;
    SESyntaxToken *other = object;
    return NSEqualRanges(_range, other.range) && [_kind isEqualToString:other.kind];
}

- (NSUInteger)hash {
    return _range.location ^ (_range.length * 31) ^ _kind.hash;
}

@end

@implementation SETextEdit

- (instancetype)initWithRange:(NSRange)range
          insertedLengthUTF16:(NSUInteger)insertedLength
                       before:(SETextBuffer *)before
                        after:(SETextBuffer *)after {
    NSParameterAssert(range.location <= before.lengthUTF16);
    NSParameterAssert(range.length <= before.lengthUTF16 - range.location);
    NSParameterAssert(range.location <= after.lengthUTF16);
    NSParameterAssert(insertedLength <= after.lengthUTF16 - range.location);
    if ((self = [super init])) {
        _rangeBeforeEdit = range;
        _insertedLengthUTF16 = insertedLength;
        _previousRevision = before.revision;
        _revision = after.revision;
        _startLine = [before lineIndexForUTF16Offset:range.location];
        _startColumnUTF16 = range.location - [before UTF16RangeOfLine:_startLine includingLineEnding:YES].location;
        _oldEndLine = [before lineIndexForUTF16Offset:NSMaxRange(range)];
        _oldEndColumnUTF16 = NSMaxRange(range) - [before UTF16RangeOfLine:_oldEndLine includingLineEnding:YES].location;
        NSUInteger newEnd = range.location + insertedLength;
        _newEndLine = [after lineIndexForUTF16Offset:newEnd];
        _newEndColumnUTF16 = newEnd - [after UTF16RangeOfLine:_newEndLine includingLineEnding:YES].location;
    }
    return self;
}

@end

@implementation SESyntaxHighlightResult

- (instancetype)initWithRevision:(NSUInteger)revision
                    coveredRange:(NSRange)range
                          tokens:(NSArray<SESyntaxToken *> *)tokens {
    if ((self = [super init])) {
        _revision = revision;
        _coveredRange = range;
        _tokens = [tokens copy];
    }
    return self;
}

@end
