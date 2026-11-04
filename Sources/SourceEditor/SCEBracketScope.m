#import "SCEBracketScope.h"

const NSUInteger SCEBracketScopeDefaultScanLimit = 1 << 17;

enum {
    SCEBracketKindCount = 3,
    SCEBracketChunkLength = 4096,
};

static NSInteger SCEOpeningBracketKind(unichar character) {
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

static NSInteger SCEClosingBracketKind(unichar character) {
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
    __unsafe_unretained SCETextBuffer *buffer;
    NSUInteger position;
    NSUInteger limit;
    NSUInteger chunkStart;
    NSUInteger chunkLength;
    unichar chunk[SCEBracketChunkLength];
} SCEBracketReader;

static BOOL SCEReadBackward(SCEBracketReader *reader, unichar *character, NSUInteger *offset) {
    if (reader->position <= reader->limit) {
        return NO;
    }
    NSUInteger index = reader->position - 1;
    if (index < reader->chunkStart || index >= reader->chunkStart + reader->chunkLength) {
        NSUInteger start =
            MAX(reader->limit, reader->position > SCEBracketChunkLength ? reader->position - SCEBracketChunkLength : 0);
        reader->chunkStart = start;
        reader->chunkLength = reader->position - start;
        [reader->buffer getUTF16Characters:reader->chunk range:NSMakeRange(start, reader->chunkLength)];
    }
    reader->position = index;
    *character = reader->chunk[index - reader->chunkStart];
    *offset = index;
    return YES;
}

static BOOL SCEReadForward(SCEBracketReader *reader, unichar *character, NSUInteger *offset) {
    if (reader->position >= reader->limit) {
        return NO;
    }
    NSUInteger index = reader->position;
    if (index < reader->chunkStart || index >= reader->chunkStart + reader->chunkLength) {
        reader->chunkStart = index;
        reader->chunkLength = MIN(SCEBracketChunkLength, reader->limit - index);
        [reader->buffer getUTF16Characters:reader->chunk range:NSMakeRange(index, reader->chunkLength)];
    }
    reader->position = index + 1;
    *character = reader->chunk[index - reader->chunkStart];
    *offset = index;
    return YES;
}

NSRange SCEEnclosingMultilineBracketRange(SCETextBuffer *buffer, NSUInteger offset, NSUInteger scanLimit) {
    NSRange notFound = NSMakeRange(NSNotFound, 0);
    NSUInteger length = buffer.lengthUTF16;
    offset = MIN(offset, length);
    SCEBracketReader *backward = calloc(1, sizeof(SCEBracketReader));
    SCEBracketReader *forward = calloc(1, sizeof(SCEBracketReader));
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
    NSUInteger backwardDepth[SCEBracketKindCount] = {0};
    NSUInteger openersFound[SCEBracketKindCount] = {0};
    NSUInteger forwardDepth[SCEBracketKindCount] = {0};
    NSMutableArray<NSNumber *> *closers[SCEBracketKindCount] = {
        [NSMutableArray array], [NSMutableArray array], [NSMutableArray array]};
    NSRange result = notFound;
    unichar character;
    NSUInteger position;
    while (SCEReadBackward(backward, &character, &position)) {
        NSInteger kind = SCEClosingBracketKind(character);
        if (kind >= 0) {
            backwardDepth[kind]++;
            continue;
        }
        kind = SCEOpeningBracketKind(character);
        if (kind < 0) {
            continue;
        }
        if (backwardDepth[kind]) {
            backwardDepth[kind]--;
            continue;
        }
        NSUInteger open = position;
        NSUInteger ordinal = openersFound[kind]++;
        while (closers[kind].count <= ordinal && SCEReadForward(forward, &character, &position)) {
            NSInteger openKind = SCEOpeningBracketKind(character);
            if (openKind >= 0) {
                forwardDepth[openKind]++;
                continue;
            }
            NSInteger closeKind = SCEClosingBracketKind(character);
            if (closeKind < 0) {
                continue;
            }
            if (forwardDepth[closeKind]) {
                forwardDepth[closeKind]--;
            } else {
                [closers[closeKind] addObject:@(position)];
            }
        }
        // The closing bracket may be absent during editing or beyond the scan
        // limit. An enclosing scope of another kind may still be complete.
        if (closers[kind].count <= ordinal) {
            continue;
        }
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
