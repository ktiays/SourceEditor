#import "include/SCETextBuffer.h"

static const NSUInteger SCETextChunkLength = 4096;

// Nodes are immutable. Editing copies only the search paths and boundary chunks.
@interface SCETextNode : NSObject
@property (nonatomic, readonly, strong, nullable) SCETextNode *left;
@property (nonatomic, readonly, strong, nullable) SCETextNode *right;
@property (nonatomic, readonly, copy, nullable) NSString *text;
@property (nonatomic, readonly, copy, nullable) NSData *lineFeeds;
@property (nonatomic, readonly) NSUInteger length;
@property (nonatomic, readonly) NSUInteger lineFeedCount;
@property (nonatomic, readonly) NSInteger height;

- (instancetype)initWithText:(NSString *)text;

- (instancetype)initWithLeft:(SCETextNode *)left right:(SCETextNode *)right;
@end

@implementation SCETextNode

- (instancetype)initWithText:(NSString *)text {
    if ((self = [super init])) {
        _text = [text copy];
        _length = text.length;
        _height = 1;
        unichar characters[4096];
        [text getCharacters:characters range:NSMakeRange(0, text.length)];
        NSMutableData *feeds = [NSMutableData data];
        for (uint32_t i = 0; i < text.length; i++) {
            if (characters[i] == '\n') {
                [feeds appendBytes:&i length:sizeof(i)];
            }
        }
        _lineFeeds = [feeds copy];
        _lineFeedCount = feeds.length / sizeof(uint32_t);
    }
    return self;
}

- (instancetype)initWithLeft:(SCETextNode *)left right:(SCETextNode *)right {
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

static SCETextNode *SCECreateTextBranch(SCETextNode *left, SCETextNode *right) {
    if (!left) {
        return right;
    }
    if (!right) {
        return left;
    }
    return [[SCETextNode alloc] initWithLeft:left right:right];
}

static SCETextNode *SCEBalanceTextNode(SCETextNode *node) {
    NSInteger delta = node.left.height - node.right.height;
    if (delta > 1) {
        SCETextNode *left = node.left;
        if (left.left.height < left.right.height) {
            SCETextNode *pivot = left.right;
            left = SCECreateTextBranch(SCECreateTextBranch(left.left, pivot.left), pivot.right);
        }
        return SCECreateTextBranch(left.left, SCECreateTextBranch(left.right, node.right));
    }
    if (delta < -1) {
        SCETextNode *right = node.right;
        if (right.right.height < right.left.height) {
            SCETextNode *pivot = right.left;
            right = SCECreateTextBranch(pivot.left, SCECreateTextBranch(pivot.right, right.right));
        }
        return SCECreateTextBranch(SCECreateTextBranch(node.left, right.left), right.right);
    }
    return node;
}

static SCETextNode *SCEJoinTextNodes(SCETextNode *left, SCETextNode *right) {
    if (!left) {
        return right;
    }
    if (!right) {
        return left;
    }
    if (left.text && right.text && left.length + right.length <= SCETextChunkLength) {
        return [[SCETextNode alloc] initWithText:[left.text stringByAppendingString:right.text]];
    }
    if (left.height > right.height + 1) {
        return SCEBalanceTextNode(SCECreateTextBranch(left.left, SCEJoinTextNodes(left.right, right)));
    }
    if (right.height > left.height + 1) {
        return SCEBalanceTextNode(SCECreateTextBranch(SCEJoinTextNodes(left, right.left), right.right));
    }
    return SCECreateTextBranch(left, right);
}

static SCETextNode *SCEBuildTextNode(NSString *string, NSRange range) {
    if (range.length == 0) {
        return nil;
    }
    if (range.length <= SCETextChunkLength) {
        return [[SCETextNode alloc] initWithText:[string substringWithRange:range]];
    }
    NSUInteger half = range.length / 2;
    return SCECreateTextBranch(SCEBuildTextNode(string, NSMakeRange(range.location, half)),
                               SCEBuildTextNode(string, NSMakeRange(range.location + half, range.length - half)));
}

static void SCESplitTextNode(SCETextNode *node, NSUInteger offset, SCETextNode *__strong *left,
                             SCETextNode *__strong *right) {
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
        *left = [[SCETextNode alloc] initWithText:[node.text substringToIndex:offset]];
        *right = [[SCETextNode alloc] initWithText:[node.text substringFromIndex:offset]];
        return;
    }
    SCETextNode *leftFragment;
    SCETextNode *rightFragment;
    if (offset < node.left.length) {
        SCESplitTextNode(node.left, offset, &leftFragment, &rightFragment);
        *left = leftFragment;
        *right = SCEJoinTextNodes(rightFragment, node.right);
    } else {
        SCESplitTextNode(node.right, offset - node.left.length, &leftFragment, &rightFragment);
        *left = SCEJoinTextNodes(node.left, leftFragment);
        *right = rightFragment;
    }
}

static void SCEAppendTextRange(SCETextNode *node, NSRange range, NSMutableString *result) {
    if (!range.length) {
        return;
    }
    if (node.text) {
        [result appendString:[node.text substringWithRange:range]];
        return;
    }
    NSUInteger leftLength = node.left.length;
    if (range.location < leftLength) {
        SCEAppendTextRange(node.left, NSMakeRange(range.location, MIN(range.length, leftLength - range.location)),
                           result);
    }
    if (NSMaxRange(range) > leftLength) {
        NSUInteger start = MAX(range.location, leftLength);
        SCEAppendTextRange(node.right, NSMakeRange(start - leftLength, NSMaxRange(range) - start), result);
    }
}

static void SCECopyTextCharacters(SCETextNode *node, NSRange range, unichar *destination) {
    if (!range.length) {
        return;
    }
    if (node.text) {
        [node.text getCharacters:destination range:range];
        return;
    }
    NSUInteger leftLength = node.left.length;
    if (range.location < leftLength) {
        SCECopyTextCharacters(node.left, NSMakeRange(range.location, MIN(range.length, leftLength - range.location)),
                              destination);
    }
    if (NSMaxRange(range) > leftLength) {
        NSUInteger start = MAX(range.location, leftLength);
        SCECopyTextCharacters(node.right, NSMakeRange(start - leftLength, NSMaxRange(range) - start),
                              destination + (start - range.location));
    }
}

static NSUInteger SCECountLineFeedsBefore(SCETextNode *node, NSUInteger offset) {
    if (!offset || !node) {
        return 0;
    }
    if (offset == node.length) {
        return node.lineFeedCount;
    }
    if (!node.text) {
        if (offset <= node.left.length) {
            return SCECountLineFeedsBefore(node.left, offset);
        }
        return node.left.lineFeedCount + SCECountLineFeedsBefore(node.right, offset - node.left.length);
    }
    const uint32_t *feeds = node.lineFeeds.bytes;
    NSUInteger low = 0;
    NSUInteger high = node.lineFeedCount;
    while (low < high) {
        NSUInteger mid = low + (high - low) / 2;
        if (feeds[mid] < offset) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    return low;
}

static NSUInteger SCEOffsetOfLineFeed(SCETextNode *node, NSUInteger index) {
    if (node.text) {
        return ((const uint32_t *)node.lineFeeds.bytes)[index];
    }
    if (index < node.left.lineFeedCount) {
        return SCEOffsetOfLineFeed(node.left, index);
    }
    return node.left.length + SCEOffsetOfLineFeed(node.right, index - node.left.lineFeedCount);
}

@implementation SCETextBuffer {
    SCETextNode *_root;
    NSUInteger _revision;
}

- (instancetype)init {
    return [self initWithString:@""];
}

- (instancetype)initWithString:(NSString *)string {
    if ((self = [super init])) {
        _root = SCEBuildTextNode(string, NSMakeRange(0, string.length));
        _documentIdentifier = NSUUID.UUID;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    SCETextBuffer *copy = [[[self class] allocWithZone:zone] init];
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
    SCEAppendTextRange(_root, range, result);
    return result;
}

- (NSUInteger)lineIndexForUTF16Offset:(NSUInteger)offset {
    [self validateRange:NSMakeRange(offset, 0)];
    return SCECountLineFeedsBefore(_root, offset);
}

- (void)getUTF16Characters:(unichar *)characters range:(NSRange)range {
    [self validateRange:range];
    NSParameterAssert(characters || !range.length);
    SCECopyTextCharacters(_root, range, characters);
}

- (NSRange)UTF16RangeOfLine:(NSUInteger)lineIndex includingLineEnding:(BOOL)includeEnding {
    if (lineIndex >= self.lineCount) {
        [NSException raise:NSRangeException
                    format:@"Line %lu exceeds line count %lu", (unsigned long)lineIndex, (unsigned long)self.lineCount];
    }
    NSUInteger start = lineIndex == 0 ? 0 : SCEOffsetOfLineFeed(_root, lineIndex - 1) + 1;
    BOOL hasEnding = lineIndex < _root.lineFeedCount;
    NSUInteger end = hasEnding ? SCEOffsetOfLineFeed(_root, lineIndex) + 1 : self.lengthUTF16;
    if (!includeEnding && hasEnding) {
        end--;
        if (end > start && [[self substringWithUTF16Range:NSMakeRange(end - 1, 1)] characterAtIndex:0] == '\r') {
            end--;
        }
    }
    return NSMakeRange(start, end - start);
}

- (void)replaceCharactersInUTF16Range:(NSRange)range withString:(NSString *)string {
    [self validateRange:range];
    if (!range.length && !string.length) {
        return;
    }
    SCETextNode *before;
    SCETextNode *tail;
    SCETextNode *removed;
    SCETextNode *after;
    SCESplitTextNode(_root, range.location, &before, &tail);
    SCESplitTextNode(tail, range.length, &removed, &after);
    _root = SCEJoinTextNodes(SCEJoinTextNodes(before, SCEBuildTextNode(string, NSMakeRange(0, string.length))), after);
    _revision++;
}

@end
