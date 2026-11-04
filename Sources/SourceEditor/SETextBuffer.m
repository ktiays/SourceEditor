#import "include/SETextBuffer.h"

static const NSUInteger SEChunkSize = 4096;

// Nodes are immutable. Editing copies only the search paths and boundary chunks.
@interface SETextNode : NSObject
@property (nonatomic, readonly, nullable) SETextNode *left;
@property (nonatomic, readonly, nullable) SETextNode *right;
@property (nonatomic, readonly, nullable) NSString *text;
@property (nonatomic, readonly, nullable) NSData *lineFeeds;
@property (nonatomic, readonly) NSUInteger length;
@property (nonatomic, readonly) NSUInteger lineFeedCount;
@property (nonatomic, readonly) NSInteger height;

- (instancetype)initWithText:(NSString *)text;

- (instancetype)initWithLeft:(SETextNode *)left right:(SETextNode *)right;
@end

@implementation SETextNode

- (instancetype)initWithText:(NSString *)text {
    if ((self = [super init])) {
        _text = [text copy];
        _length = text.length;
        _height = 1;
        unichar characters[4096];
        [text getCharacters:characters range:NSMakeRange(0, text.length)];
        NSMutableData *feeds = [NSMutableData data];
        for (uint32_t i = 0; i < text.length; i++) {
            if (characters[i] == '\n')
                [feeds appendBytes:&i length:sizeof(i)];
        }
        _lineFeeds = [feeds copy];
        _lineFeedCount = feeds.length / sizeof(uint32_t);
    }
    return self;
}

- (instancetype)initWithLeft:(SETextNode *)left right:(SETextNode *)right {
    if ((self = [super init])) {
        _left = left;
        _right = right;
        _length = left.length + right.length;
        _lineFeedCount = left.lineFeedCount + right.lineFeedCount;
        _height = MAX(left.height, right.height) + 1;
    }
    return self;
}

@end

static SETextNode *SEBranch(SETextNode *left, SETextNode *right) {
    if (!left)
        return right;
    if (!right)
        return left;
    return [[SETextNode alloc] initWithLeft:left right:right];
}

static SETextNode *SEBalance(SETextNode *node) {
    NSInteger delta = node.left.height - node.right.height;
    if (delta > 1) {
        SETextNode *left = node.left;
        if (left.left.height < left.right.height) {
            SETextNode *pivot = left.right;
            left = SEBranch(SEBranch(left.left, pivot.left), pivot.right);
        }
        return SEBranch(left.left, SEBranch(left.right, node.right));
    }
    if (delta < -1) {
        SETextNode *right = node.right;
        if (right.right.height < right.left.height) {
            SETextNode *pivot = right.left;
            right = SEBranch(pivot.left, SEBranch(pivot.right, right.right));
        }
        return SEBranch(SEBranch(node.left, right.left), right.right);
    }
    return node;
}

static SETextNode *SEJoin(SETextNode *left, SETextNode *right) {
    if (!left)
        return right;
    if (!right)
        return left;
    if (left.text && right.text && left.length + right.length <= SEChunkSize) {
        return [[SETextNode alloc] initWithText:[left.text stringByAppendingString:right.text]];
    }
    if (left.height > right.height + 1) {
        return SEBalance(SEBranch(left.left, SEJoin(left.right, right)));
    }
    if (right.height > left.height + 1) {
        return SEBalance(SEBranch(SEJoin(left, right.left), right.right));
    }
    return SEBranch(left, right);
}

static SETextNode *SEBuild(NSString *string, NSRange range) {
    if (range.length == 0)
        return nil;
    if (range.length <= SEChunkSize) {
        return [[SETextNode alloc] initWithText:[string substringWithRange:range]];
    }
    NSUInteger half = range.length / 2;
    return SEBranch(SEBuild(string, NSMakeRange(range.location, half)),
        SEBuild(string, NSMakeRange(range.location + half, range.length - half)));
}

static void SESplit(SETextNode *node, NSUInteger offset, SETextNode *__strong *left, SETextNode *__strong *right) {
    if (offset == 0) {
        *left = nil;
        *right = node;
        return;
    }
    if (offset == node.length) {
        *left = node;
        *right = nil;
        return;
    }
    if (node.text) {
        *left = [[SETextNode alloc] initWithText:[node.text substringToIndex:offset]];
        *right = [[SETextNode alloc] initWithText:[node.text substringFromIndex:offset]];
        return;
    }
    SETextNode *a;
    SETextNode *b;
    if (offset < node.left.length) {
        SESplit(node.left, offset, &a, &b);
        *left = a;
        *right = SEJoin(b, node.right);
    } else {
        SESplit(node.right, offset - node.left.length, &a, &b);
        *left = SEJoin(node.left, a);
        *right = b;
    }
}

static void SEAppendRange(SETextNode *node, NSRange range, NSMutableString *result) {
    if (!range.length)
        return;
    if (node.text) {
        [result appendString:[node.text substringWithRange:range]];
        return;
    }
    NSUInteger leftLength = node.left.length;
    if (range.location < leftLength) {
        SEAppendRange(node.left, NSMakeRange(range.location, MIN(range.length, leftLength - range.location)), result);
    }
    if (NSMaxRange(range) > leftLength) {
        NSUInteger start = MAX(range.location, leftLength);
        SEAppendRange(node.right, NSMakeRange(start - leftLength, NSMaxRange(range) - start), result);
    }
}

static void SECopyCharacters(SETextNode *node, NSRange range, unichar *destination) {
    if (!range.length)
        return;
    if (node.text) {
        [node.text getCharacters:destination range:range];
        return;
    }
    NSUInteger leftLength = node.left.length;
    if (range.location < leftLength) {
        SECopyCharacters(
            node.left, NSMakeRange(range.location, MIN(range.length, leftLength - range.location)), destination);
    }
    if (NSMaxRange(range) > leftLength) {
        NSUInteger start = MAX(range.location, leftLength);
        SECopyCharacters(node.right, NSMakeRange(start - leftLength, NSMaxRange(range) - start),
            destination + (start - range.location));
    }
}

static NSUInteger SECountLineFeedsBefore(SETextNode *node, NSUInteger offset) {
    if (!offset || !node)
        return 0;
    if (offset == node.length)
        return node.lineFeedCount;
    if (!node.text) {
        if (offset <= node.left.length)
            return SECountLineFeedsBefore(node.left, offset);
        return node.left.lineFeedCount + SECountLineFeedsBefore(node.right, offset - node.left.length);
    }
    const uint32_t *feeds = node.lineFeeds.bytes;
    NSUInteger low = 0;
    NSUInteger high = node.lineFeedCount;
    while (low < high) {
        NSUInteger mid = low + (high - low) / 2;
        if (feeds[mid] < offset)
            low = mid + 1;
        else
            high = mid;
    }
    return low;
}

static NSUInteger SEOffsetOfLineFeed(SETextNode *node, NSUInteger index) {
    if (node.text)
        return ((const uint32_t *)node.lineFeeds.bytes)[index];
    if (index < node.left.lineFeedCount)
        return SEOffsetOfLineFeed(node.left, index);
    return node.left.length + SEOffsetOfLineFeed(node.right, index - node.left.lineFeedCount);
}

@implementation SETextBuffer {
    SETextNode *_root;
    NSUInteger _revision;
}

- (instancetype)init {
    return [self initWithString:@""];
}

- (instancetype)initWithString:(NSString *)string {
    if ((self = [super init])) {
        _root = SEBuild(string, NSMakeRange(0, string.length));
        _documentIdentifier = NSUUID.UUID;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    SETextBuffer *copy = [[[self class] allocWithZone:zone] init];
    copy->_root = _root;
    copy->_revision = _revision;
    copy->_documentIdentifier = _documentIdentifier;
    return copy;
}

- (NSUInteger)lengthUTF16 {
    return _root.length;
}

- (NSUInteger)lineCount {
    return _root.lineFeedCount + 1;
}

- (NSUInteger)revision {
    return _revision;
}

- (NSString *)string {
    return [self substringWithUTF16Range:NSMakeRange(0, self.lengthUTF16)];
}

- (void)validateRange:(NSRange)range {
    if (range.location > self.lengthUTF16 || range.length > self.lengthUTF16 - range.location) {
        [NSException raise:NSRangeException
                    format:@"UTF-16 range %@ exceeds buffer length %lu", NSStringFromRange(range),
            (unsigned long)self.lengthUTF16];
    }
}

- (NSString *)substringWithUTF16Range:(NSRange)range {
    [self validateRange:range];
    NSMutableString *result = [NSMutableString stringWithCapacity:range.length];
    SEAppendRange(_root, range, result);
    return result;
}

- (NSUInteger)lineIndexForUTF16Offset:(NSUInteger)offset {
    [self validateRange:NSMakeRange(offset, 0)];
    return SECountLineFeedsBefore(_root, offset);
}

- (void)getUTF16Characters:(unichar *)characters range:(NSRange)range {
    [self validateRange:range];
    NSParameterAssert(characters || !range.length);
    SECopyCharacters(_root, range, characters);
}

- (NSRange)UTF16RangeOfLine:(NSUInteger)lineIndex includingLineEnding:(BOOL)includeEnding {
    if (lineIndex >= self.lineCount) {
        [NSException raise:NSRangeException
                    format:@"Line %lu exceeds line count %lu", (unsigned long)lineIndex, (unsigned long)self.lineCount];
    }
    NSUInteger start = lineIndex == 0 ? 0 : SEOffsetOfLineFeed(_root, lineIndex - 1) + 1;
    BOOL hasEnding = lineIndex < _root.lineFeedCount;
    NSUInteger end = hasEnding ? SEOffsetOfLineFeed(_root, lineIndex) + 1 : self.lengthUTF16;
    if (!includeEnding && hasEnding) {
        end--;
        if (end > start && [[self substringWithUTF16Range:NSMakeRange(end - 1, 1)] characterAtIndex:0] == '\r')
            end--;
    }
    return NSMakeRange(start, end - start);
}

- (void)replaceCharactersInUTF16Range:(NSRange)range withString:(NSString *)string {
    [self validateRange:range];
    if (!range.length && !string.length)
        return;
    SETextNode *before;
    SETextNode *tail;
    SETextNode *removed;
    SETextNode *after;
    SESplit(_root, range.location, &before, &tail);
    SESplit(tail, range.length, &removed, &after);
    _root = SEJoin(SEJoin(before, SEBuild(string, NSMakeRange(0, string.length))), after);
    _revision++;
}

@end
