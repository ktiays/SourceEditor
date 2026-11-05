#import "SCELexicalContextProvider.h"
#import "SCETextBufferInternal.h"
#import <string.h>

enum {
    SCELexicalChunkLength = 4096,
    SCELexicalScanLimit = 1 << 17,
    SCELexicalMaximumCheckpointCount = 2048,
    SCELexicalMaximumTemplateDepth = 32,
    SCELexicalKeywordLength = 16,
    SCELexicalMaximumTrackedParenthesisDepth = 64,
};

typedef NS_ENUM(NSUInteger, SCELexicalMode) {
    SCELexicalModeCode,
    SCELexicalModeDoubleQuotedString,
    SCELexicalModeSingleQuotedString,
    SCELexicalModeTemplate,
    SCELexicalModeLineComment,
    SCELexicalModeBlockComment,
    SCELexicalModeRegularExpression,
    SCELexicalModeUnknown,
};

typedef NS_ENUM(NSUInteger, SCERegularExpressionPosition) {
    SCERegularExpressionPositionAllowed,
    SCERegularExpressionPositionDisallowed,
    SCERegularExpressionPositionUnknown,
};

// This state describes only consumed characters, without looking past the
// checkpoint. Inserting at a checkpoint therefore preserves its validity.
typedef struct {
    SCELexicalMode mode;
    SCERegularExpressionPosition regularExpressionPosition;
    BOOL escaped;
    BOOL escapedCarriageReturn;
    BOOL blockCommentStar;
    BOOL regularExpressionCharacterClass;
    BOOL pendingSlash;
    BOOL templateDollar;
    BOOL readingIdentifier;
    BOOL propertyNameExpected;
    BOOL identifierIsProperty;
    char identifier[SCELexicalKeywordLength];
    NSUInteger identifierLength;
    unichar previousOperator;
    SCERegularExpressionPosition positionBeforeOperator;
    // Whether the most recent token is a statement keyword whose parenthesized
    // head may be followed by a regular expression, as in "if (x) /re/.test(y)".
    BOOL previousTokenIsControlKeyword;
    // Bit n records whether the parenthesis at depth n follows such a keyword.
    // Deeper nesting is counted but its closers make slash positions unknown.
    NSUInteger parenthesisDepth;
    uint64_t controlParenthesisMask;
    NSUInteger templateDepth;
    NSUInteger templateBraceDepth[SCELexicalMaximumTemplateDepth];
} SCELexicalState;

typedef struct {
    NSUInteger offset;
    SCELexicalState state;
} SCELexicalCheckpoint;

static BOOL SCEIsLexicalLineEnding(unichar character) {
    return character == '\n' || character == '\r' || character == 0x2028 || character == 0x2029;
}

static BOOL SCEIsLexicalWhitespace(unichar character) {
    return character == ' ' || character == '\t' || character == '\v' || character == '\f' || character == 0x00a0 ||
           character == 0xfeff || SCEIsLexicalLineEnding(character) || (character >= 0x2000 && character <= 0x200a) ||
           character == 0x1680 || character == 0x202f || character == 0x205f || character == 0x3000;
}

static BOOL SCEIsLexicalIdentifierCharacter(unichar character) {
    return (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') ||
           (character >= '0' && character <= '9') || character == '_' || character == '$' || character >= 0x80;
}

static void SCEFinishLexicalIdentifier(SCELexicalState *state) {
    if (!state->readingIdentifier) {
        return;
    }
    state->readingIdentifier = NO;
    state->regularExpressionPosition = SCERegularExpressionPositionDisallowed;
    state->previousTokenIsControlKeyword = NO;
    if (!state->identifierIsProperty && state->identifierLength < SCELexicalKeywordLength) {
        state->identifier[state->identifierLength] = 0;
        state->previousTokenIsControlKeyword =
            strcmp(state->identifier, "if") == 0 || strcmp(state->identifier, "while") == 0 ||
            strcmp(state->identifier, "for") == 0 || strcmp(state->identifier, "with") == 0;
        const char *keywords[] = {"return", "throw", "case",       "delete", "void", "typeof",
                                  "new",    "in",    "instanceof", "else",   "do"};
        for (NSUInteger index = 0; index < sizeof(keywords) / sizeof(keywords[0]); index++) {
            if (strcmp(state->identifier, keywords[index]) == 0) {
                state->regularExpressionPosition = SCERegularExpressionPositionAllowed;
                break;
            }
        }
        if (strcmp(state->identifier, "break") == 0 || strcmp(state->identifier, "continue") == 0 ||
            strcmp(state->identifier, "debugger") == 0 || strcmp(state->identifier, "yield") == 0 ||
            strcmp(state->identifier, "await") == 0 || strcmp(state->identifier, "of") == 0) {
            state->regularExpressionPosition = SCERegularExpressionPositionUnknown;
        }
    }
}

static void SCEConsumeLexicalCharacter(SCELexicalState *state, unichar character, BOOL javaScriptEnabled) {
    if (state->mode == SCELexicalModeUnknown) {
        return;
    }
    if (state->mode == SCELexicalModeLineComment) {
        if (SCEIsLexicalLineEnding(character)) {
            state->mode = SCELexicalModeCode;
            if (state->regularExpressionPosition == SCERegularExpressionPositionDisallowed) {
                state->regularExpressionPosition = SCERegularExpressionPositionUnknown;
            }
        }
        return;
    }
    if (state->mode == SCELexicalModeBlockComment) {
        if (SCEIsLexicalLineEnding(character) &&
            state->regularExpressionPosition == SCERegularExpressionPositionDisallowed) {
            state->regularExpressionPosition = SCERegularExpressionPositionUnknown;
        }
        if (state->blockCommentStar && character == '/') {
            state->mode = SCELexicalModeCode;
            state->blockCommentStar = NO;
        } else {
            state->blockCommentStar = character == '*';
        }
        return;
    }
    if (state->mode == SCELexicalModeDoubleQuotedString || state->mode == SCELexicalModeSingleQuotedString) {
        if (state->escapedCarriageReturn) {
            state->escapedCarriageReturn = NO;
            if (character == '\n') {
                return;
            }
        }
        if (state->escaped) {
            state->escaped = NO;
            if (SCEIsLexicalLineEnding(character)) {
                if (!javaScriptEnabled) {
                    state->mode = SCELexicalModeUnknown;
                } else {
                    state->escapedCarriageReturn = character == '\r';
                }
            }
        } else if (character == '\\') {
            state->escaped = YES;
        } else if (character == (state->mode == SCELexicalModeDoubleQuotedString ? '"' : '\'')) {
            state->mode = SCELexicalModeCode;
            state->regularExpressionPosition = SCERegularExpressionPositionDisallowed;
        } else if (character == '\n' || character == '\r') {
            state->mode = SCELexicalModeUnknown;
        }
        return;
    }
    if (state->mode == SCELexicalModeTemplate) {
        if (state->escaped) {
            state->escaped = NO;
            state->templateDollar = NO;
        } else if (character == '\\') {
            state->escaped = YES;
            state->templateDollar = NO;
        } else if (character == '`') {
            state->templateDepth--;
            state->mode = SCELexicalModeCode;
            state->regularExpressionPosition = SCERegularExpressionPositionDisallowed;
            state->templateDollar = NO;
        } else if (state->templateDollar && character == '{') {
            state->mode = SCELexicalModeCode;
            state->regularExpressionPosition = SCERegularExpressionPositionAllowed;
            state->templateBraceDepth[state->templateDepth - 1] = 0;
            state->templateDollar = NO;
        } else {
            state->templateDollar = character == '$';
        }
        return;
    }
    if (state->mode == SCELexicalModeRegularExpression) {
        if (SCEIsLexicalLineEnding(character)) {
            state->mode = SCELexicalModeUnknown;
        } else if (state->escaped) {
            state->escaped = NO;
        } else if (character == '\\') {
            state->escaped = YES;
        } else if (character == '[') {
            // Nested Unicode-set classes require the later regular-expression
            // flags. Avoid guessing before the complete literal is available.
            if (state->regularExpressionCharacterClass) {
                state->mode = SCELexicalModeUnknown;
            } else {
                state->regularExpressionCharacterClass = YES;
            }
        } else if (character == ']') {
            state->regularExpressionCharacterClass = NO;
        } else if (character == '/' && !state->regularExpressionCharacterClass) {
            state->mode = SCELexicalModeCode;
            state->regularExpressionPosition = SCERegularExpressionPositionDisallowed;
        }
        return;
    }
    if (state->pendingSlash) {
        state->pendingSlash = NO;
        if (character == '/') {
            state->mode = SCELexicalModeLineComment;
            return;
        }
        if (character == '*') {
            state->mode = SCELexicalModeBlockComment;
            return;
        }
        state->previousTokenIsControlKeyword = NO;
        if (state->regularExpressionPosition == SCERegularExpressionPositionUnknown) {
            state->mode = SCELexicalModeUnknown;
            return;
        }
        if (state->regularExpressionPosition == SCERegularExpressionPositionAllowed) {
            state->mode = SCELexicalModeRegularExpression;
            SCEConsumeLexicalCharacter(state, character, javaScriptEnabled);
            return;
        }
        state->regularExpressionPosition = SCERegularExpressionPositionAllowed;
    }
    if (!SCEIsLexicalWhitespace(character) && SCEIsLexicalIdentifierCharacter(character)) {
        if (!state->readingIdentifier) {
            state->readingIdentifier = YES;
            state->identifierLength = 0;
            state->identifierIsProperty = state->propertyNameExpected;
            state->propertyNameExpected = NO;
        }
        if (state->identifierLength < SCELexicalKeywordLength) {
            state->identifier[state->identifierLength++] = character < 0x80 ? (char)character : '?';
        }
        state->previousOperator = 0;
        return;
    }
    SCEFinishLexicalIdentifier(state);
    if (SCEIsLexicalWhitespace(character)) {
        if (SCEIsLexicalLineEnding(character) &&
            state->regularExpressionPosition == SCERegularExpressionPositionDisallowed) {
            state->regularExpressionPosition = SCERegularExpressionPositionUnknown;
        }
        state->previousOperator = 0;
        return;
    }
    state->propertyNameExpected = NO;
    BOOL followsControlKeyword = state->previousTokenIsControlKeyword;
    // A slash may begin a comment, which must not separate a keyword from its head.
    if (character != '/') {
        state->previousTokenIsControlKeyword = NO;
    }
    if (javaScriptEnabled && character == '!' && state->previousOperator == '#') {
        state->mode = SCELexicalModeLineComment;
        state->previousOperator = 0;
        return;
    }
    if (character == '"' || (javaScriptEnabled && character == '\'')) {
        state->mode = character == '"' ? SCELexicalModeDoubleQuotedString : SCELexicalModeSingleQuotedString;
        state->previousOperator = 0;
        return;
    }
    if (character == '`' && javaScriptEnabled) {
        if (state->templateDepth == SCELexicalMaximumTemplateDepth) {
            state->mode = SCELexicalModeUnknown;
        } else {
            state->templateBraceDepth[state->templateDepth++] = 0;
            state->mode = SCELexicalModeTemplate;
            state->templateDollar = NO;
        }
        state->previousOperator = 0;
        return;
    }
    if (character == '/') {
        if (javaScriptEnabled) {
            state->pendingSlash = YES;
        } else {
            state->mode = SCELexicalModeUnknown;
        }
        state->previousOperator = 0;
        return;
    }
    if (character == '\\' || (!javaScriptEnabled && (character == '\'' || character == '`'))) {
        state->mode = SCELexicalModeUnknown;
        return;
    }
    if (character == '{' && state->templateDepth) {
        state->templateBraceDepth[state->templateDepth - 1]++;
    } else if (character == '}' && state->templateDepth) {
        NSUInteger *depth = &state->templateBraceDepth[state->templateDepth - 1];
        if (*depth == 0) {
            state->mode = SCELexicalModeTemplate;
            state->templateDollar = NO;
            return;
        }
        (*depth)--;
    }
    if (character == '(') {
        if (state->parenthesisDepth < SCELexicalMaximumTrackedParenthesisDepth) {
            uint64_t bit = (uint64_t)1 << state->parenthesisDepth;
            state->controlParenthesisMask =
                followsControlKeyword ? state->controlParenthesisMask | bit : state->controlParenthesisMask & ~bit;
        }
        state->parenthesisDepth++;
    }
    if (character == ')') {
        // A closing parenthesis ends an expression, so a following slash is
        // division, except after the head of if, while, for, or with, where a
        // statement and therefore a regular expression may follow.
        if (state->parenthesisDepth == 0) {
            state->regularExpressionPosition = SCERegularExpressionPositionUnknown;
        } else {
            state->parenthesisDepth--;
            if (state->parenthesisDepth >= SCELexicalMaximumTrackedParenthesisDepth) {
                state->regularExpressionPosition = SCERegularExpressionPositionUnknown;
            } else if (state->controlParenthesisMask & ((uint64_t)1 << state->parenthesisDepth)) {
                state->regularExpressionPosition = SCERegularExpressionPositionAllowed;
            } else {
                state->regularExpressionPosition = SCERegularExpressionPositionDisallowed;
            }
        }
    } else if (character == '}') {
        // A closing brace can end either a block statement or an object literal.
        // Resolving a following slash requires grammar context, so suppress
        // editing there.
        state->regularExpressionPosition = SCERegularExpressionPositionUnknown;
    } else if (character == '.' && state->previousOperator == '.') {
        // A spread token and a property-access dot have different lexical goals.
        state->regularExpressionPosition = SCERegularExpressionPositionUnknown;
    } else if (character == ']' || character == '.' || character == '#') {
        state->regularExpressionPosition = SCERegularExpressionPositionDisallowed;
        state->propertyNameExpected = character == '.' || character == '#';
    } else if ((character == '+' || character == '-') && state->previousOperator == character) {
        state->regularExpressionPosition = state->positionBeforeOperator == SCERegularExpressionPositionDisallowed
                                               ? SCERegularExpressionPositionDisallowed
                                               : SCERegularExpressionPositionUnknown;
    } else {
        state->positionBeforeOperator = state->regularExpressionPosition;
        state->regularExpressionPosition = SCERegularExpressionPositionAllowed;
    }
    state->previousOperator = character;
}

static SCELanguageContext SCEContextForLexicalState(SCELexicalState state) {
    if (state.pendingSlash) {
        return SCELanguageContextUnknown;
    }
    switch (state.mode) {
        case SCELexicalModeCode:
            return SCELanguageContextCode;
        case SCELexicalModeDoubleQuotedString:
        case SCELexicalModeSingleQuotedString:
        case SCELexicalModeTemplate:
        case SCELexicalModeRegularExpression:
            return SCELanguageContextString;
        case SCELexicalModeLineComment:
        case SCELexicalModeBlockComment:
            return SCELanguageContextComment;
        case SCELexicalModeUnknown:
            return SCELanguageContextUnknown;
    }
}

@implementation SCELexicalContextProvider {
    BOOL _javaScriptEnabled;
    SCETextBuffer *_snapshot;
    NSMutableData *_checkpoints;
    SCELexicalCheckpoint _lastCheckpoint;
}

- (instancetype)initWithJavaScriptEnabled:(BOOL)javaScriptEnabled {
    if ((self = [super init])) {
        _javaScriptEnabled = javaScriptEnabled;
        _checkpoints = [NSMutableData data];
        [self resetCheckpoints];
    }
    return self;
}

- (void)resetCheckpoints {
    _lastCheckpoint = (SCELexicalCheckpoint){0};
    _checkpoints.length = 0;
    [_checkpoints appendBytes:&_lastCheckpoint length:sizeof(_lastCheckpoint)];
}

- (BOOL)matchesSnapshot:(SCETextBuffer *)snapshot {
    return _snapshot && _snapshot.revision == snapshot.revision &&
           [_snapshot.documentIdentifier isEqual:snapshot.documentIdentifier] &&
           [_snapshot hasSameStorageAsBuffer:snapshot];
}

- (SCELexicalCheckpoint)checkpointAtOrBeforeOffset:(NSUInteger)offset {
    const SCELexicalCheckpoint *checkpoints = _checkpoints.bytes;
    NSUInteger low = 0;
    NSUInteger high = _checkpoints.length / sizeof(*checkpoints);
    while (low < high) {
        NSUInteger middle = low + (high - low) / 2;
        if (checkpoints[middle].offset <= offset) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    SCELexicalCheckpoint checkpoint = checkpoints[low - 1];
    if (_lastCheckpoint.offset <= offset && _lastCheckpoint.offset > checkpoint.offset) {
        checkpoint = _lastCheckpoint;
    }
    return checkpoint;
}

- (void)appendCheckpoint:(SCELexicalCheckpoint)checkpoint {
    NSUInteger count = _checkpoints.length / sizeof(checkpoint);
    const SCELexicalCheckpoint *checkpoints = _checkpoints.bytes;
    if (checkpoint.offset <= checkpoints[count - 1].offset ||
        checkpoint.offset - checkpoints[count - 1].offset < SCELexicalChunkLength) {
        return;
    }
    if (count == SCELexicalMaximumCheckpointCount) {
        [_checkpoints replaceBytesInRange:NSMakeRange(sizeof(checkpoint), sizeof(checkpoint)) withBytes:NULL length:0];
    }
    [_checkpoints appendBytes:&checkpoint length:sizeof(checkpoint)];
}

- (SCELanguageContext)contextAtUTF16Offset:(NSUInteger)offset inBuffer:(SCETextBuffer *)snapshot {
    if (offset > snapshot.lengthUTF16) {
        return SCELanguageContextUnknown;
    }
    if (![self matchesSnapshot:snapshot]) {
        [self resetCheckpoints];
        _snapshot = [snapshot copy];
    }
    SCELexicalCheckpoint checkpoint = [self checkpointAtOrBeforeOffset:offset];
    NSUInteger end = checkpoint.offset + MIN(offset - checkpoint.offset, SCELexicalScanLimit);
    unichar characters[SCELexicalChunkLength];
    while (checkpoint.offset < end && checkpoint.state.mode != SCELexicalModeUnknown) {
        NSUInteger length = MIN(SCELexicalChunkLength, end - checkpoint.offset);
        [snapshot getUTF16Characters:characters range:NSMakeRange(checkpoint.offset, length)];
        for (NSUInteger index = 0; index < length; index++) {
            SCEConsumeLexicalCharacter(&checkpoint.state, characters[index], _javaScriptEnabled);
            checkpoint.offset++;
        }
        [self appendCheckpoint:checkpoint];
    }
    _lastCheckpoint = checkpoint;
    if (checkpoint.offset < offset || checkpoint.state.mode == SCELexicalModeUnknown) {
        return SCELanguageContextUnknown;
    }
    return SCEContextForLexicalState(checkpoint.state);
}

- (void)invalidateForReplacementOfUTF16Range:(NSRange)range
                              previousBuffer:(SCETextBuffer *)previousBuffer
                                 afterBuffer:(SCETextBuffer *)afterBuffer {
    if (![self matchesSnapshot:previousBuffer]) {
        _snapshot = nil;
        return;
    }
    NSUInteger count = _checkpoints.length / sizeof(SCELexicalCheckpoint);
    const SCELexicalCheckpoint *checkpoints = _checkpoints.bytes;
    while (count > 1 && checkpoints[count - 1].offset > range.location) {
        count--;
    }
    if (_lastCheckpoint.offset > range.location) {
        _lastCheckpoint = checkpoints[count - 1];
    }
    _checkpoints.length = count * sizeof(SCELexicalCheckpoint);
    _snapshot = [afterBuffer copy];
}

@end
