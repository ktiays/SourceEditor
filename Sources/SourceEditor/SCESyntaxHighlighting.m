#import "include/SCESyntaxHighlighting.h"

SCESyntaxTokenKind const SCESyntaxTokenComment = @"comment";
SCESyntaxTokenKind const SCESyntaxTokenString = @"string";
SCESyntaxTokenKind const SCESyntaxTokenEscape = @"escape";
SCESyntaxTokenKind const SCESyntaxTokenNumber = @"number";
SCESyntaxTokenKind const SCESyntaxTokenKeyword = @"keyword";
SCESyntaxTokenKind const SCESyntaxTokenFunction = @"function";
SCESyntaxTokenKind const SCESyntaxTokenType = @"type";
SCESyntaxTokenKind const SCESyntaxTokenProperty = @"property";
SCESyntaxTokenKind const SCESyntaxTokenVariable = @"variable";
SCESyntaxTokenKind const SCESyntaxTokenOperator = @"operator";
SCESyntaxTokenKind const SCESyntaxTokenPunctuation = @"punctuation";

@implementation SCESyntaxToken

- (instancetype)initWithRange:(NSRange)range kind:(SCESyntaxTokenKind)kind {
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
    if (object == self) {
        return YES;
    }
    if (![object isKindOfClass:SCESyntaxToken.class]) {
        return NO;
    }
    SCESyntaxToken *other = object;
    return NSEqualRanges(_range, other.range) && [_kind isEqualToString:other.kind];
}

- (NSUInteger)hash {
    return _range.location ^ (_range.length * 31) ^ _kind.hash;
}

@end

@implementation SCETextEdit

- (instancetype)initWithRange:(NSRange)range
          insertedLengthUTF16:(NSUInteger)insertedLength
                 beforeBuffer:(SCETextBuffer *)beforeBuffer
                  afterBuffer:(SCETextBuffer *)afterBuffer {
    NSParameterAssert(range.location <= beforeBuffer.lengthUTF16);
    NSParameterAssert(range.length <= beforeBuffer.lengthUTF16 - range.location);
    NSParameterAssert(range.location <= afterBuffer.lengthUTF16);
    NSParameterAssert(insertedLength <= afterBuffer.lengthUTF16 - range.location);
    if ((self = [super init])) {
        _rangeBeforeEdit = range;
        _insertedLengthUTF16 = insertedLength;
        _previousRevision = beforeBuffer.revision;
        _revision = afterBuffer.revision;
        _startLine = [beforeBuffer lineIndexForUTF16Offset:range.location];
        _startColumnUTF16 =
            range.location - [beforeBuffer UTF16RangeOfLine:_startLine includingLineEnding:YES].location;
        _oldEndLine = [beforeBuffer lineIndexForUTF16Offset:NSMaxRange(range)];
        _oldEndColumnUTF16 =
            NSMaxRange(range) - [beforeBuffer UTF16RangeOfLine:_oldEndLine includingLineEnding:YES].location;
        NSUInteger newEnd = range.location + insertedLength;
        _newEndLine = [afterBuffer lineIndexForUTF16Offset:newEnd];
        _newEndColumnUTF16 = newEnd - [afterBuffer UTF16RangeOfLine:_newEndLine includingLineEnding:YES].location;
    }
    return self;
}

@end

@implementation SCESyntaxHighlightResult

- (instancetype)initWithRevision:(NSUInteger)revision
                    coveredRange:(NSRange)range
                          tokens:(NSArray<SCESyntaxToken *> *)tokens {
    return [self initWithRevision:revision coveredRanges:@[ [NSValue valueWithRange:range] ] tokens:tokens];
}

- (instancetype)initWithRevision:(NSUInteger)revision
                   coveredRanges:(NSArray<NSValue *> *)ranges
                          tokens:(NSArray<SCESyntaxToken *> *)tokens {
    NSParameterAssert(ranges.count > 0);
    if ((self = [super init])) {
        _revision = revision;
        _coveredRanges = [ranges copy];
        NSUInteger start = ranges.firstObject.rangeValue.location;
        _coveredRange = NSMakeRange(start, NSMaxRange(ranges.lastObject.rangeValue) - start);
        _tokens = [tokens copy];
    }
    return self;
}

@end
