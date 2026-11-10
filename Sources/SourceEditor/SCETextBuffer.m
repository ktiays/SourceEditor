#import "include/SCETextBuffer.h"
#import "SCETextBufferInternal.h"
#import <fcntl.h>
#import <os/lock.h>
#import <sys/mman.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <unistd.h>

enum {
    // The maximum UTF-16 length of a leaf that owns its text. Edits create and
    // merge leaves up to this length.
    SCETextChunkLength = 4096,
    // The number of decoded file-backed leaves each file keeps. A viewport reads
    // a few leaves, so this bounds memory without decoding visible text again.
    SCEDecodedFileChunkLimit = 64,
};

// The maximum byte length of a file-backed leaf. A leaf decodes to at most this
// many UTF-16 code units. Larger leaves keep the node count of a large file low,
// since they hold no text until read.
static const NSUInteger SCEFileChunkByteLength = 16384;

#pragma mark - Decoded text

// The immutable text of one leaf and the UTF-16 offsets of its line feeds.
@interface SCETextChunk : NSObject
@property (nonatomic, readonly, copy) NSString *text;
@property (nonatomic, readonly, copy) NSData *lineFeeds;

- (instancetype)initWithText:(NSString *)text lineFeeds:(NSData *)lineFeeds;
@end

@implementation SCETextChunk

- (instancetype)initWithText:(NSString *)text lineFeeds:(NSData *)lineFeeds {
    if ((self = [super init])) {
        _text = [text copy];
        _lineFeeds = [lineFeeds copy];
    }
    return self;
}

@end

static SCETextChunk *SCECreateTextChunk(NSString *text) {
    NSCParameterAssert(text.length <= SCETextChunkLength);
    unichar characters[SCETextChunkLength];
    [text getCharacters:characters range:NSMakeRange(0, text.length)];
    NSMutableData *feeds = [NSMutableData data];
    for (uint32_t i = 0; i < text.length; i++) {
        if (characters[i] == '\n') {
            [feeds appendBytes:&i length:sizeof(i)];
        }
    }
    return [[SCETextChunk alloc] initWithText:text lineFeeds:feeds];
}

#pragma mark - UTF-8 decoding

// Decodes the scalar value that starts at bytes[0] and returns the number of
// bytes consumed. Ill-formed input produces U+FFFD for each maximal subpart, as
// the Unicode Standard recommends: a valid lead byte followed by a valid prefix of
// continuation bytes is replaced as a unit, and the first byte that cannot extend
// the sequence starts the next scalar value. Indexing and decoding share this
// function, so they always agree on UTF-16 lengths.
static inline NSUInteger SCEDecodeUTF8Scalar(const uint8_t *bytes, NSUInteger length, uint32_t *scalar) {
    uint8_t lead = bytes[0];
    if (lead < 0x80) {
        *scalar = lead;
        return 1;
    }
    NSUInteger continuationCount;
    uint32_t value;
    uint8_t lower = 0x80;
    uint8_t upper = 0xBF;
    if (lead >= 0xC2 && lead <= 0xDF) {
        continuationCount = 1;
        value = lead & 0x1F;
    } else if (lead >= 0xE0 && lead <= 0xEF) {
        continuationCount = 2;
        value = lead & 0x0F;
        if (lead == 0xE0) {
            lower = 0xA0;
        } else if (lead == 0xED) {
            upper = 0x9F;
        }
    } else if (lead >= 0xF0 && lead <= 0xF4) {
        continuationCount = 3;
        value = lead & 0x07;
        if (lead == 0xF0) {
            lower = 0x90;
        } else if (lead == 0xF4) {
            upper = 0x8F;
        }
    } else {
        *scalar = 0xFFFD;
        return 1;
    }
    for (NSUInteger index = 1; index <= continuationCount; index++) {
        if (index >= length || bytes[index] < lower || bytes[index] > upper) {
            *scalar = 0xFFFD;
            return index;
        }
        lower = 0x80;
        upper = 0xBF;
        value = (value << 6) | (bytes[index] & 0x3F);
    }
    *scalar = value;
    return continuationCount + 1;
}

static inline BOOL SCEIsASCIIWord(uint64_t word) {
    return !(word & 0x8080808080808080ULL);
}

// Counts the line feed bytes in eight ASCII bytes. Masking the high bits before
// the addition prevents carries between bytes, so the count is exact.
static inline NSUInteger SCECountLineFeedsInASCIIWord(uint64_t word) {
    uint64_t difference = word ^ 0x0A0A0A0A0A0A0A0AULL;
    uint64_t nonzero = ((difference & 0x7F7F7F7F7F7F7F7FULL) + 0x7F7F7F7F7F7F7F7FULL) | difference;
    return (NSUInteger)__builtin_popcountll(~nonzero & 0x8080808080808080ULL);
}

typedef struct {
    NSUInteger byteOffset;
    NSUInteger byteLength;
    NSUInteger length;
    NSUInteger lineFeedCount;
    BOOL isASCII;
} SCEFileChunkInfo;

static void SCEMeasureUTF8(const uint8_t *bytes, SCEFileChunkInfo *info) {
    NSUInteger byteLength = info->byteLength;
    NSUInteger length = 0;
    NSUInteger lineFeedCount = 0;
    NSUInteger index = 0;
    BOOL isASCII = YES;
    while (index < byteLength) {
        if (byteLength - index >= sizeof(uint64_t)) {
            uint64_t word;
            memcpy(&word, bytes + index, sizeof(word));
            if (SCEIsASCIIWord(word)) {
                lineFeedCount += SCECountLineFeedsInASCIIWord(word);
                length += sizeof(word);
                index += sizeof(word);
                continue;
            }
        }
        uint8_t byte = bytes[index];
        if (byte < 0x80) {
            lineFeedCount += byte == '\n';
            length++;
            index++;
            continue;
        }
        isASCII = NO;
        uint32_t scalar;
        index += SCEDecodeUTF8Scalar(bytes + index, byteLength - index, &scalar);
        length += scalar >= 0x10000 ? 2 : 1;
    }
    info->length = length;
    info->lineFeedCount = lineFeedCount;
    info->isASCII = isASCII;
}

static SCETextChunk *SCEDecodeFileChunk(const uint8_t *bytes, const SCEFileChunkInfo *info) {
    NSMutableData *feeds = [NSMutableData dataWithCapacity:info->lineFeedCount * sizeof(uint32_t)];
    NSString *text;
    if (info->isASCII) {
        // ASCII bytes are their own UTF-16 code units. NSString stores them in
        // eight bits, which halves the memory of the decoded cache entry.
        const uint8_t *cursor = bytes;
        const uint8_t *end = bytes + info->byteLength;
        while ((cursor = memchr(cursor, '\n', (size_t)(end - cursor)))) {
            uint32_t offset = (uint32_t)(cursor - bytes);
            [feeds appendBytes:&offset length:sizeof(offset)];
            cursor++;
        }
        text = [[NSString alloc] initWithBytes:bytes length:info->byteLength encoding:NSASCIIStringEncoding];
    } else {
        unichar *characters = malloc(MAX(1, info->length) * sizeof(unichar));
        NSUInteger length = 0;
        NSUInteger index = 0;
        while (index < info->byteLength) {
            uint32_t scalar;
            index += SCEDecodeUTF8Scalar(bytes + index, info->byteLength - index, &scalar);
            if (scalar == '\n') {
                uint32_t offset = (uint32_t)length;
                [feeds appendBytes:&offset length:sizeof(offset)];
            }
            if (scalar >= 0x10000) {
                characters[length++] = (unichar)(0xD7C0 + (scalar >> 10));
                characters[length++] = (unichar)(0xDC00 | (scalar & 0x3FF));
            } else {
                characters[length++] = (unichar)scalar;
            }
        }
        NSCAssert(length == info->length, @"Decoding disagrees with the file index");
        text = [[NSString alloc] initWithCharactersNoCopy:characters length:length freeWhenDone:YES];
    }
    return [[SCETextChunk alloc] initWithText:text lineFeeds:feeds];
}

#pragma mark - File storage

// Owns the bytes of one file: a read-only, copy-on-write mapping, or data read
// into memory for volumes where mapping is unsafe. Thread-safe; leaves on any
// queue decode through its cache.
@interface SCEFileTextStorage : NSObject
@property (nonatomic, readonly) const uint8_t *bytes;
@property (nonatomic, readonly) NSUInteger length;

- (nullable instancetype)initWithURL:(NSURL *)url error:(NSError **)error;

/// Returns the decoded leaf, retained, so that reading a large file in one
/// autorelease scope does not keep every decoded leaf alive.
- (SCETextChunk *)chunkForInfo:(const SCEFileChunkInfo *)info NS_RETURNS_RETAINED;
@end

// One decoded leaf in a file's cache, identified by its byte offset.
typedef struct {
    NSUInteger byteOffset;
    uint64_t lastUse;
    __strong SCETextChunk *chunk;
} SCEDecodedFileChunk;

static NSError *SCEFileReadError(NSURL *url, int code) {
    NSInteger cocoaCode = NSFileReadUnknownError;
    if (code == ENOENT) {
        cocoaCode = NSFileReadNoSuchFileError;
    } else if (code == EACCES || code == EPERM) {
        cocoaCode = NSFileReadNoPermissionError;
    } else if (code == EFBIG) {
        cocoaCode = NSFileReadTooLargeError;
    }
    NSError *underlying = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
    return [NSError errorWithDomain:NSCocoaErrorDomain
                               code:cocoaCode
                           userInfo:@{NSURLErrorKey : url, NSUnderlyingErrorKey : underlying}];
}

@implementation SCEFileTextStorage {
    void *_mapping;
    size_t _mappingLength;
    NSData *_data;
    // A least-recently-used cache. NSCache is not used because it returns
    // autoreleased objects, which would keep evicted leaves alive until the
    // reader's autorelease pool drains.
    os_unfair_lock _chunkLock;
    SCEDecodedFileChunk _chunks[SCEDecodedFileChunkLimit];
    NSUInteger _chunkCount;
    uint64_t _chunkClock;
}

- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error {
    if ((self = [super init])) {
        _chunkLock = OS_UNFAIR_LOCK_INIT;
        if (!url.isFileURL) {
            if (error) {
                *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                             code:NSFileReadUnsupportedSchemeError
                                         userInfo:@{NSURLErrorKey : url}];
            }
            return nil;
        }
        int descriptor = open(url.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
        if (descriptor < 0) {
            if (error) {
                *error = SCEFileReadError(url, errno);
            }
            return nil;
        }
        struct stat status;
        struct statfs volume;
        if (fstat(descriptor, &status) != 0 || fstatfs(descriptor, &volume) != 0) {
            int code = errno;
            close(descriptor);
            if (error) {
                *error = SCEFileReadError(url, code);
            }
            return nil;
        }
        if (!S_ISREG(status.st_mode)) {
            close(descriptor);
            if (error) {
                *error = SCEFileReadError(url, S_ISDIR(status.st_mode) ? EISDIR : EINVAL);
            }
            return nil;
        }
        if ((uint64_t)status.st_size > SIZE_MAX / 2) {
            close(descriptor);
            if (error) {
                *error = SCEFileReadError(url, EFBIG);
            }
            return nil;
        }
        size_t size = (size_t)status.st_size;
        // A network or removable volume can disappear while mapped, which turns
        // reads into faults. Read such files into memory instead.
        if (size && (volume.f_flags & MNT_LOCAL)) {
            void *mapping = mmap(NULL, size, PROT_READ, MAP_PRIVATE, descriptor, 0);
            if (mapping != MAP_FAILED) {
                _mapping = mapping;
                _mappingLength = size;
                _bytes = mapping;
                _length = size;
            }
        }
        close(descriptor);
        if (size && !_mapping) {
            _data = [NSData dataWithContentsOfURL:url options:NSDataReadingUncached error:error];
            if (!_data) {
                return nil;
            }
            _bytes = _data.bytes;
            _length = _data.length;
        }
    }
    return self;
}

- (void)dealloc {
    if (_mapping) {
        munmap(_mapping, _mappingLength);
    }
}

- (SCETextChunk *)chunkForInfo:(const SCEFileChunkInfo *)info {
    // File-backed leaves never move within the file, so the byte offset
    // identifies a leaf without retaining it.
    SCETextChunk *chunk = nil;
    os_unfair_lock_lock(&_chunkLock);
    for (NSUInteger index = 0; index < _chunkCount; index++) {
        if (_chunks[index].byteOffset == info->byteOffset) {
            _chunks[index].lastUse = ++_chunkClock;
            chunk = _chunks[index].chunk;
            break;
        }
    }
    os_unfair_lock_unlock(&_chunkLock);
    if (chunk) {
        return chunk;
    }
    // Decode outside the lock so that readers on other queues are not blocked.
    // Two readers may decode the same leaf; both results are equal.
    chunk = SCEDecodeFileChunk(_bytes + info->byteOffset, info);
    os_unfair_lock_lock(&_chunkLock);
    NSUInteger slot = _chunkCount;
    if (_chunkCount < SCEDecodedFileChunkLimit) {
        _chunkCount++;
    } else {
        slot = 0;
        for (NSUInteger index = 1; index < _chunkCount; index++) {
            if (_chunks[index].lastUse < _chunks[slot].lastUse) {
                slot = index;
            }
        }
    }
    _chunks[slot].byteOffset = info->byteOffset;
    _chunks[slot].lastUse = ++_chunkClock;
    _chunks[slot].chunk = chunk;
    os_unfair_lock_unlock(&_chunkLock);
    return chunk;
}

@end

#pragma mark - Rope nodes

// Nodes are immutable. Editing copies only the search paths and boundary chunks.
// A leaf either owns its text or refers to a byte range of a file and decodes it
// on demand.
@interface SCETextNode : NSObject
@property (nonatomic, readonly, strong, nullable) SCETextNode *left;
@property (nonatomic, readonly, strong, nullable) SCETextNode *right;
@property (nonatomic, readonly) NSUInteger length;
@property (nonatomic, readonly) NSUInteger lineFeedCount;
@property (nonatomic, readonly) NSInteger height;
@property (nonatomic, readonly, getter=isLeaf) BOOL leaf;
/// YES for a leaf that owns its text and can merge with adjacent owned leaves.
@property (nonatomic, readonly, getter=isOwnedLeaf) BOOL ownedLeaf;

- (instancetype)initWithText:(NSString *)text;

- (instancetype)initWithStorage:(SCEFileTextStorage *)storage info:(SCEFileChunkInfo)info;

- (instancetype)initWithLeft:(SCETextNode *)left right:(SCETextNode *)right;

/// The decoded text of a leaf, retained. File-backed leaves decode through the
/// file's cache.
- (SCETextChunk *)chunk NS_RETURNS_RETAINED;
@end

@implementation SCETextNode {
    SCETextChunk *_ownedChunk;
    SCEFileTextStorage *_storage;
    SCEFileChunkInfo _fileChunk;
}

- (instancetype)initWithText:(NSString *)text {
    if ((self = [super init])) {
        _ownedChunk = SCECreateTextChunk(text);
        _length = text.length;
        _lineFeedCount = _ownedChunk.lineFeeds.length / sizeof(uint32_t);
        _height = 1;
    }
    return self;
}

- (instancetype)initWithStorage:(SCEFileTextStorage *)storage info:(SCEFileChunkInfo)info {
    if ((self = [super init])) {
        _storage = storage;
        _fileChunk = info;
        _length = info.length;
        _lineFeedCount = info.lineFeedCount;
        _height = 1;
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

- (BOOL)isLeaf {
    return _ownedChunk || _storage;
}

- (BOOL)isOwnedLeaf {
    return _ownedChunk != nil;
}

- (SCETextChunk *)chunk {
    return _ownedChunk ?: [_storage chunkForInfo:&_fileChunk];
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
    // File-backed leaves are never merged, so that an edit decodes only the
    // leaves it touches.
    if (left.isOwnedLeaf && right.isOwnedLeaf && left.length + right.length <= SCETextChunkLength) {
        return [[SCETextNode alloc] initWithText:[left.chunk.text stringByAppendingString:right.chunk.text]];
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

static SCETextNode *SCEBuildBalancedTextNode(NSArray<SCETextNode *> *leaves, NSRange range) {
    if (range.length == 0) {
        return nil;
    }
    if (range.length == 1) {
        return leaves[range.location];
    }
    NSUInteger half = range.length / 2;
    return SCECreateTextBranch(
        SCEBuildBalancedTextNode(leaves, NSMakeRange(range.location, half)),
        SCEBuildBalancedTextNode(leaves, NSMakeRange(range.location + half, range.length - half)));
}

// Divides the file into leaves of at most SCEFileChunkByteLength bytes, indexes
// them concurrently, and builds a balanced tree. Boundaries move back over UTF-8
// continuation bytes so that well-formed sequences stay within one leaf.
static SCETextNode *SCEBuildFileTextNode(SCEFileTextStorage *storage) {
    const uint8_t *bytes = storage.bytes;
    NSUInteger length = storage.length;
    NSUInteger start = 0;
    if (length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
        start = 3;
    }
    if (start >= length) {
        return nil;
    }
    NSUInteger capacity = (length - start) / (SCEFileChunkByteLength - 3) + 1;
    SCEFileChunkInfo *infos = calloc(capacity, sizeof(SCEFileChunkInfo));
    NSUInteger count = 0;
    while (start < length) {
        NSUInteger end = MIN(start + SCEFileChunkByteLength, length);
        if (end < length) {
            NSUInteger boundary = end;
            for (NSUInteger step = 0; step < 3 && (bytes[boundary] & 0xC0) == 0x80; step++) {
                boundary--;
            }
            // More than three continuation bytes cannot belong to one sequence,
            // so splitting them changes no well-formed text.
            if ((bytes[boundary] & 0xC0) != 0x80) {
                end = boundary;
            }
        }
        infos[count++] = (SCEFileChunkInfo){.byteOffset = start, .byteLength = end - start};
        start = end;
    }
    dispatch_apply(count, DISPATCH_APPLY_AUTO, ^(size_t index) {
        SCEMeasureUTF8(bytes + infos[index].byteOffset, &infos[index]);
    });
    NSMutableArray<SCETextNode *> *leaves = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger index = 0; index < count; index++) {
        if (infos[index].length) {
            [leaves addObject:[[SCETextNode alloc] initWithStorage:storage info:infos[index]]];
        }
    }
    free(infos);
    return SCEBuildBalancedTextNode(leaves, NSMakeRange(0, leaves.count));
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
    if (node.isLeaf) {
        // Splitting a file-backed leaf replaces it with owned leaves of at most
        // SCETextChunkLength, so the edited region no longer refers to the file.
        NSString *text = node.chunk.text;
        *left = SCEBuildTextNode(text, NSMakeRange(0, offset));
        *right = SCEBuildTextNode(text, NSMakeRange(offset, text.length - offset));
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
    if (node.isLeaf) {
        [result appendString:[node.chunk.text substringWithRange:range]];
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
    if (node.isLeaf) {
        [node.chunk.text getCharacters:destination range:range];
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
    if (!node.isLeaf) {
        if (offset <= node.left.length) {
            return SCECountLineFeedsBefore(node.left, offset);
        }
        return node.left.lineFeedCount + SCECountLineFeedsBefore(node.right, offset - node.left.length);
    }
    const uint32_t *feeds = node.chunk.lineFeeds.bytes;
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
    if (node.isLeaf) {
        return ((const uint32_t *)node.chunk.lineFeeds.bytes)[index];
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

- (instancetype)initWithContentsOfURL:(NSURL *)url error:(NSError **)error {
    SCEFileTextStorage *storage = [[SCEFileTextStorage alloc] initWithURL:url error:error];
    if (!storage) {
        return nil;
    }
    if ((self = [self initWithString:@""])) {
        _root = SCEBuildFileTextNode(storage);
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

- (BOOL)hasSameStorageAsBuffer:(SCETextBuffer *)buffer {
    return _root == buffer->_root;
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
        unichar previous = 0;
        if (end > start) {
            SCECopyTextCharacters(_root, NSMakeRange(end - 1, 1), &previous);
        }
        if (previous == '\r') {
            end--;
        }
    }
    return NSMakeRange(start, end - start);
}

- (void)replaceCharactersInUTF16Range:(NSRange)range withNode:(SCETextNode *)replacement {
    SCETextNode *before;
    SCETextNode *tail;
    SCETextNode *removed;
    SCETextNode *after;
    SCESplitTextNode(_root, range.location, &before, &tail);
    SCESplitTextNode(tail, range.length, &removed, &after);
    _root = SCEJoinTextNodes(SCEJoinTextNodes(before, replacement), after);
    _revision++;
}

- (void)replaceCharactersInUTF16Range:(NSRange)range withString:(NSString *)string {
    [self validateRange:range];
    if (!range.length && !string.length) {
        return;
    }
    [self replaceCharactersInUTF16Range:range withNode:SCEBuildTextNode(string, NSMakeRange(0, string.length))];
}

- (void)replaceCharactersInUTF16Range:(NSRange)range withBuffer:(SCETextBuffer *)buffer {
    NSParameterAssert(buffer);
    [self validateRange:range];
    // Read the replacement first, in case buffer is the receiver.
    SCETextNode *replacement = buffer->_root;
    if (!range.length && !replacement) {
        return;
    }
    [self replaceCharactersInUTF16Range:range withNode:replacement];
}

@end
