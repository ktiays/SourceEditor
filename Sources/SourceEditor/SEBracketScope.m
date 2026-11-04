#import "SEBracketScope.h"

const NSUInteger SEBracketScopeDefaultScanLimit = 1 << 17;

enum {
    SEBracketKindCount = 3,
    SEBracketChunkLength = 4096,
};

static NSInteger SEOpeningBracketKind(unichar character) {
    switch (character) {
    case '(':
        return 0;
    case '[':
        return 1;
    case '{':
        return 2;
    default:
        return -1;
    }
}

static NSInteger SEClosingBracketKind(unichar character) {
    switch (character) {
    case ')':
        return 0;
    case ']':
        return 1;
    case '}':
        return 2;
    default:
        return -1;
    }
}

// Reads the rope one bounded chunk at a time, in either direction, without
// materializing an NSString.
typedef struct {
    __unsafe_unretained SETextBuffer *buffer;
    NSUInteger position;
    NSUInteger limit;
    NSUInteger chunkStart;
    NSUInteger chunkLength;
    unichar chunk[SEBracketChunkLength];
} SEBracketReader;

static BOOL SEReadBackward(SEBracketReader *reader, unichar *character, NSUInteger *offset) {
    if (reader->position <= reader->limit)
        return NO;
    NSUInteger index = reader->position - 1;
    if (index < reader->chunkStart || index >= reader->chunkStart + reader->chunkLength) {
        NSUInteger start
            = MAX(reader->limit, reader->position > SEBracketChunkLength ? reader->position - SEBracketChunkLength : 0);
        reader->chunkStart = start;
        reader->chunkLength = reader->position - start;
        [reader->buffer getUTF16Characters:reader->chunk range:NSMakeRange(start, reader->chunkLength)];
    }
    reader->position = index;
    *character = reader->chunk[index - reader->chunkStart];
    *offset = index;
    return YES;
}

static BOOL SEReadForward(SEBracketReader *reader, unichar *character, NSUInteger *offset) {
    if (reader->position >= reader->limit)
        return NO;
    NSUInteger index = reader->position;
    if (index < reader->chunkStart || index >= reader->chunkStart + reader->chunkLength) {
        reader->chunkStart = index;
        reader->chunkLength = MIN(SEBracketChunkLength, reader->limit - index);
        [reader->buffer getUTF16Characters:reader->chunk range:NSMakeRange(index, reader->chunkLength)];
    }
    reader->position = index + 1;
    *character = reader->chunk[index - reader->chunkStart];
    *offset = index;
    return YES;
}

NSRange SEEnclosingMultilineBracketRange(SETextBuffer *buffer, NSUInteger offset, NSUInteger scanLimit) {
    NSRange notFound = NSMakeRange(NSNotFound, 0);
    NSUInteger length = buffer.lengthUTF16;
    offset = MIN(offset, length);
    SEBracketReader *backward = calloc(1, sizeof(SEBracketReader));
    SEBracketReader *forward = calloc(1, sizeof(SEBracketReader));
    if (!backward || !forward) {
        free(backward);
        free(forward);
        return notFound;
    }
    backward->buffer = buffer;
    backward->position = offset;
    backward->limit = offset > scanLimit ? offset - scanLimit : 0;
    forward->buffer = buffer;
    forward->position = offset;
    forward->limit = length - offset > scanLimit ? offset + scanLimit : length;

    // With each kind balanced on its own, the n-th unmatched opener of a kind
    // before the caret pairs with the n-th unmatched closer of that kind after it.
    NSUInteger backwardDepth[SEBracketKindCount] = { 0 };
    NSUInteger openersFound[SEBracketKindCount] = { 0 };
    NSUInteger forwardDepth[SEBracketKindCount] = { 0 };
    NSMutableArray<NSNumber *> *closers[SEBracketKindCount]
        = { [NSMutableArray array], [NSMutableArray array], [NSMutableArray array] };
    NSRange result = notFound;
    unichar character;
    NSUInteger position;
    while (SEReadBackward(backward, &character, &position)) {
        NSInteger kind = SEClosingBracketKind(character);
        if (kind >= 0) {
            backwardDepth[kind]++;
            continue;
        }
        kind = SEOpeningBracketKind(character);
        if (kind < 0)
            continue;
        if (backwardDepth[kind]) {
            backwardDepth[kind]--;
            continue;
        }
        NSUInteger open = position;
        NSUInteger ordinal = openersFound[kind]++;
        while (closers[kind].count <= ordinal && SEReadForward(forward, &character, &position)) {
            NSInteger openKind = SEOpeningBracketKind(character);
            if (openKind >= 0) {
                forwardDepth[openKind]++;
                continue;
            }
            NSInteger closeKind = SEClosingBracketKind(character);
            if (closeKind < 0)
                continue;
            if (forwardDepth[closeKind])
                forwardDepth[closeKind]--;
            else
                [closers[closeKind] addObject:@(position)];
        }
        // Unclosed within the budget, e.g. while it's still being typed. An
        // outer scope of another kind may still be complete.
        if (closers[kind].count <= ordinal)
            continue;
        NSUInteger close = closers[kind][ordinal].unsignedIntegerValue;
        NSUInteger openLine = [buffer lineIndexForUTF16Offset:open];
        NSUInteger closeLine = [buffer lineIndexForUTF16Offset:close];
        if (closeLine >= openLine + 2) {
            result = NSMakeRange(open, close + 1 - open);
            break;
        }
    }
    free(backward);
    free(forward);
    return result;
}
