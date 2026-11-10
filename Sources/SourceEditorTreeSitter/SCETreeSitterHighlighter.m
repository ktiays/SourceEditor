#import "include/SCETreeSitterHighlighter.h"
#import "resource_bundle_accessor.h"
@import TreeSitter;
@import TreeSitterJSON;

NSErrorDomain const SCETreeSitterErrorDomain = @"dev.ktiays.SourceEditor.TreeSitter";

typedef struct {
    __unsafe_unretained SCETextBuffer *snapshot;
    unichar characters[4096];
} SCEParserInput;

typedef struct {
    __unsafe_unretained SCETreeSitterHighlighter *highlighter;
    NSUInteger cancellationGeneration;
    NSUInteger revision;
} SCEParserCancellation;

@interface SCETreeSitterHighlighter ()
- (BOOL)shouldCancelGeneration:(NSUInteger)cancellationGeneration revision:(NSUInteger)revision;
@end

static const char *SCEReadInput(void *payload, uint32_t byteIndex, TSPoint position, uint32_t *bytesRead) {
    SCEParserInput *input = payload;
    NSUInteger offset = byteIndex / sizeof(unichar);
    if ((byteIndex % sizeof(unichar)) || offset >= input->snapshot.lengthUTF16) {
        *bytesRead = 0;
        return NULL;
    }
    NSUInteger count = MIN(4096, input->snapshot.lengthUTF16 - offset);
    [input->snapshot getUTF16Characters:input->characters range:NSMakeRange(offset, count)];
    // A decoder must see both halves of a surrogate pair in the same chunk.
    if (offset + count < input->snapshot.lengthUTF16 &&
        CFStringIsSurrogateHighCharacter(input->characters[count - 1])) {
        count--;
    }
    *bytesRead = (uint32_t)(count * sizeof(unichar));
    return (const char *)input->characters;
}

static bool SCEParseShouldCancel(TSParseState *state) {
    SCEParserCancellation *cancellation = state->payload;
    return [cancellation->highlighter shouldCancelGeneration:cancellation->cancellationGeneration
                                                    revision:cancellation->revision];
}

static BOOL SCEEditFitsParser(SCETextEdit *edit) {
    NSUInteger maximum = UINT32_MAX / sizeof(unichar);
    NSRange range = edit.rangeBeforeEdit;
    return range.location <= maximum && range.length <= maximum - range.location &&
           edit.insertedLengthUTF16 <= maximum - range.location && edit.startColumnUTF16 <= maximum &&
           edit.oldEndColumnUTF16 <= maximum && edit.newEndColumnUTF16 <= maximum;
}

static TSInputEdit SCEParserEdit(SCETextEdit *edit) {
    TSInputEdit input = {
        .start_byte = (uint32_t)(edit.rangeBeforeEdit.location * sizeof(unichar)),
        .old_end_byte = (uint32_t)(NSMaxRange(edit.rangeBeforeEdit) * sizeof(unichar)),
        .new_end_byte = (uint32_t)((edit.rangeBeforeEdit.location + edit.insertedLengthUTF16) * sizeof(unichar)),
        .start_point =
            {
                (uint32_t)edit.startLine,
                (uint32_t)(edit.startColumnUTF16 * sizeof(unichar)),
            },
        .old_end_point =
            {
                (uint32_t)edit.oldEndLine,
                (uint32_t)(edit.oldEndColumnUTF16 * sizeof(unichar)),
            },
        .new_end_point =
            {
                (uint32_t)edit.newEndLine,
                (uint32_t)(edit.newEndColumnUTF16 * sizeof(unichar)),
            },
    };
    return input;
}

static NSUInteger SCEKindPriority(SCESyntaxTokenKind kind) {
    static NSArray<SCESyntaxTokenKind> *kinds;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kinds = @[
            SCESyntaxTokenVariable, SCESyntaxTokenPunctuation, SCESyntaxTokenOperator, SCESyntaxTokenString,
            SCESyntaxTokenNumber, SCESyntaxTokenKeyword, SCESyntaxTokenProperty, SCESyntaxTokenFunction,
            SCESyntaxTokenType, SCESyntaxTokenEscape, SCESyntaxTokenComment
        ];
    });
    NSUInteger index = [kinds indexOfObject:kind];
    return index == NSNotFound ? 0 : index;
}

// One capture of a highlight query, before conversion to a token.
typedef struct {
    NSUInteger start;
    NSUInteger end;
    uint32_t captureIndex;
    NSUInteger priority;
} SCECapturedToken;

// Applies enclosing scopes before nested captures. For equal ranges, semantic
// specificity lets JSON property names override the enclosing string token.
static int SCECompareCapturedTokens(const void *a, const void *b) {
    const SCECapturedToken *lhs = a;
    const SCECapturedToken *rhs = b;
    NSUInteger lhsLength = lhs->end - lhs->start;
    NSUInteger rhsLength = rhs->end - rhs->start;
    if (lhsLength != rhsLength) {
        return lhsLength > rhsLength ? -1 : 1;
    }
    if (lhs->priority != rhs->priority) {
        return lhs->priority < rhs->priority ? -1 : 1;
    }
    if (lhs->start != rhs->start) {
        return lhs->start < rhs->start ? -1 : 1;
    }
    return lhs->captureIndex < rhs->captureIndex ? -1 : (lhs->captureIndex > rhs->captureIndex ? 1 : 0);
}

// The maximum number of captures in one result. Requests cover the viewport, so
// a larger count means unusually dense text; the editor keeps its colors.
static const NSUInteger SCEMaximumCapturedTokenCount = 20000;

static void SCEDeleteParserResources(TSParser *parser, TSQuery *query, TSTree *tree) {
    if (tree) {
        ts_tree_delete(tree);
    }
    if (query) {
        ts_query_delete(query);
    }
    if (parser) {
        ts_parser_delete(parser);
    }
}

@implementation SCETreeSitterHighlighter {
    TSParser *_parser;
    TSQuery *_query;
    TSTree *_tree;
    NSUInteger _treeRevision;
    NSUUID *_treeDocumentIdentifier;
    NSArray<SCESyntaxTokenKind> *_captureKinds;
    // The override priority of each capture's kind, indexed by capture.
    NSData *_capturePriorities;
    dispatch_queue_t _queue;
    NSLock *_stateLock;
    SCETextBuffer *_pendingSnapshot;
    NSMutableArray<SCETextEdit *> *_pendingEdits;
    NSArray<NSValue *> *_pendingRanges;
    BOOL _pendingRequestHasRanges;
    SCESyntaxHighlightCompletion _pendingCompletion;
    NSUInteger _requestIdentifier;
    NSUInteger _cancellationGeneration;
    BOOL _scheduled;
    BOOL _resetOnNextRequest;
    NSUInteger _parseCount;
    NSUInteger _incrementalParseCount;
}

- (instancetype)initWithLanguage:(SCETreeSitterLanguage)language error:(NSError **)error {
    if (!(self = [super init])) {
        return nil;
    }
    _language = language;
    const TSLanguage *grammar = NULL;
    NSString *queryName = nil;
    switch (language) {
        case SCETreeSitterLanguageJSON:
            grammar = tree_sitter_json();
            queryName = @"json";
            break;
        default:
            if (error) {
                *error = [NSError errorWithDomain:SCETreeSitterErrorDomain
                                             code:1
                                         userInfo:@{
                                             NSLocalizedDescriptionKey : @"Unsupported language.",
                                         }];
            }
            return nil;
    }
    _stateLock = [[NSLock alloc] init];
    _queue = dispatch_queue_create("dev.ktiays.SourceEditor.TreeSitter", DISPATCH_QUEUE_SERIAL);
    _pendingEdits = [NSMutableArray array];
    _parser = ts_parser_new();
    if (!ts_parser_set_language(_parser, grammar)) {
        if (error) {
            *error = [NSError errorWithDomain:SCETreeSitterErrorDomain
                                         code:2
                                     userInfo:@{
                                         NSLocalizedDescriptionKey : @"Incompatible grammar ABI.",
                                     }];
        }
        return nil;
    }
    NSURL *url = nil;
    @try {
        url = [SWIFTPM_MODULE_BUNDLE URLForResource:queryName withExtension:@"scm" subdirectory:@"Queries"];
    } @catch (NSException *exception) {
        if (![exception.name isEqualToString:@"SwiftPMResourcesAccessor"]) {
            @throw;
        }
    }
    NSError *resourceError = nil;
    NSData *source = url ? [NSData dataWithContentsOfURL:url options:0 error:&resourceError] : nil;
    if (!source) {
        if (error) {
            *error = resourceError
                         ?: [NSError errorWithDomain:SCETreeSitterErrorDomain
                                                code:3
                                            userInfo:@{
                                                NSLocalizedDescriptionKey : @"Highlight query resource is missing.",
                                            }];
        }
        return nil;
    }
    uint32_t errorOffset = 0;
    TSQueryError queryError = TSQueryErrorNone;
    _query = ts_query_new(grammar, source.bytes, (uint32_t)source.length, &errorOffset, &queryError);
    if (!_query) {
        if (error) {
            NSString *message =
                [NSString stringWithFormat:@"Invalid highlight query at byte %u (error %u).", errorOffset, queryError];
            *error = [NSError errorWithDomain:SCETreeSitterErrorDomain
                                         code:4
                                     userInfo:@{
                                         NSLocalizedDescriptionKey : message,
                                     }];
        }
        return nil;
    }
    NSMutableArray *kinds = [NSMutableArray array];
    for (uint32_t i = 0; i < ts_query_capture_count(_query); i++) {
        uint32_t length;
        const char *name = ts_query_capture_name_for_id(_query, i, &length);
        [kinds addObject:[[NSString alloc] initWithBytes:name length:length encoding:NSUTF8StringEncoding]];
    }
    _captureKinds = [kinds copy];
    NSMutableData *priorities = [NSMutableData dataWithLength:kinds.count * sizeof(NSUInteger)];
    NSUInteger *priority = priorities.mutableBytes;
    for (NSUInteger index = 0; index < kinds.count; index++) {
        priority[index] = SCEKindPriority(kinds[index]);
    }
    _capturePriorities = priorities;
    for (uint32_t pattern = 0; pattern < ts_query_pattern_count(_query); pattern++) {
        uint32_t count;
        ts_query_predicates_for_pattern(_query, pattern, &count);
        if (count) {
            if (error) {
                *error = [NSError errorWithDomain:SCETreeSitterErrorDomain
                                             code:5
                                         userInfo:@{
                                             NSLocalizedDescriptionKey :
                                                 @"Highlight queries must use structural captures without predicates.",
                                         }];
            }
            return nil;
        }
    }
    return self;
}

- (void)dealloc {
    TSParser *parser = _parser;
    TSQuery *query = _query;
    TSTree *tree = _tree;
    if (_queue) {
        dispatch_async(_queue, ^{
            SCEDeleteParserResources(parser, query, tree);
        });
    } else {
        SCEDeleteParserResources(parser, query, tree);
    }
}

- (void)highlightBuffer:(SCETextBuffer *)snapshot
             UTF16Range:(NSRange)range
              afterEdit:(SCETextEdit *)edit
             completion:(SCESyntaxHighlightCompletion)completion {
    [self enqueueRequestForBuffer:snapshot
                      UTF16Ranges:@[ [NSValue valueWithRange:range] ]
                        hasRanges:NO
                        afterEdit:edit
                       completion:completion];
}

- (void)highlightBuffer:(SCETextBuffer *)snapshot
            UTF16Ranges:(NSArray<NSValue *> *)ranges
              afterEdit:(SCETextEdit *)edit
             completion:(SCESyntaxHighlightCompletion)completion {
    NSParameterAssert(ranges.count > 0);
    [self enqueueRequestForBuffer:snapshot UTF16Ranges:ranges hasRanges:YES afterEdit:edit completion:completion];
}

- (void)enqueueRequestForBuffer:(SCETextBuffer *)snapshot
                    UTF16Ranges:(NSArray<NSValue *> *)ranges
                      hasRanges:(BOOL)hasRanges
                      afterEdit:(SCETextEdit *)edit
                     completion:(SCESyntaxHighlightCompletion)completion {
    NSMutableArray<NSValue *> *clampedRanges = [NSMutableArray arrayWithCapacity:ranges.count];
    for (NSValue *value in ranges) {
        NSRange range = value.rangeValue;
        NSUInteger start = MIN(range.location, snapshot.lengthUTF16);
        range = NSMakeRange(start, MIN(range.length, snapshot.lengthUTF16 - start));
        [clampedRanges addObject:[NSValue valueWithRange:range]];
    }
    [_stateLock lock];
    _pendingSnapshot = [snapshot copy];
    _pendingRanges = clampedRanges;
    _pendingRequestHasRanges = hasRanges;
    _pendingCompletion = [completion copy];
    _requestIdentifier++;
    if (edit) {
        [_pendingEdits addObject:edit];
    }
    if (!_scheduled) {
        _scheduled = YES;
        dispatch_async(_queue, ^{
            [self processPendingRequests];
        });
    }
    [_stateLock unlock];
}

- (void)cancelPendingRequests {
    [_stateLock lock];
    _cancellationGeneration++;
    _requestIdentifier++;
    _pendingSnapshot = nil;
    _pendingCompletion = nil;
    [_pendingEdits removeAllObjects];
    _resetOnNextRequest = YES;
    [_stateLock unlock];
}

- (BOOL)shouldCancelGeneration:(NSUInteger)cancellationGeneration revision:(NSUInteger)revision {
    [_stateLock lock];
    BOOL canceled = cancellationGeneration != _cancellationGeneration ||
                    (_pendingSnapshot && _pendingSnapshot.revision != revision);
    [_stateLock unlock];
    return canceled;
}

- (void)processPendingRequests {
    while (YES) {
        @autoreleasepool {
            [_stateLock lock];
            SCETextBuffer *snapshot = _pendingSnapshot;
            if (!snapshot) {
                _scheduled = NO;
                [_stateLock unlock];
                return;
            }
            NSArray<SCETextEdit *> *edits = [_pendingEdits copy];
            NSArray<NSValue *> *ranges = _pendingRanges;
            BOOL hasRanges = _pendingRequestHasRanges;
            SCESyntaxHighlightCompletion completion = _pendingCompletion;
            NSUInteger requestIdentifier = _requestIdentifier;
            NSUInteger cancellationGeneration = _cancellationGeneration;
            BOOL reset = _resetOnNextRequest;
            _resetOnNextRequest = NO;
            _pendingSnapshot = nil;
            _pendingCompletion = nil;
            [_pendingEdits removeAllObjects];
            [_stateLock unlock];
            SCESyntaxHighlightResult *result = [self highlightSnapshot:snapshot
                                                                ranges:ranges
                                                             hasRanges:hasRanges
                                                                 edits:edits
                                                cancellationGeneration:cancellationGeneration
                                                                 reset:reset];
            [_stateLock lock];
            BOOL current = requestIdentifier == _requestIdentifier && cancellationGeneration == _cancellationGeneration;
            [_stateLock unlock];
            if (current) {
                completion(result);
            }
        }
    }
}

- (SCESyntaxHighlightResult *)highlightSnapshot:(SCETextBuffer *)snapshot
                                         ranges:(NSArray<NSValue *> *)ranges
                                      hasRanges:(BOOL)hasRanges
                                          edits:(NSArray<SCETextEdit *> *)edits
                         cancellationGeneration:(NSUInteger)cancellationGeneration
                                          reset:(BOOL)reset {
    if (snapshot.lengthUTF16 > UINT32_MAX / sizeof(unichar)) {
        return nil;
    }
    BOOL reusable = _tree && !reset && [_treeDocumentIdentifier isEqual:snapshot.documentIdentifier];
    if (reusable && _treeRevision != snapshot.revision) {
        NSUInteger revision = _treeRevision;
        for (SCETextEdit *edit in edits) {
            if (edit.previousRevision != revision || !SCEEditFitsParser(edit)) {
                reusable = NO;
                break;
            }
            TSInputEdit input = SCEParserEdit(edit);
            ts_tree_edit(_tree, &input);
            revision = edit.revision;
        }
        reusable = reusable && revision == snapshot.revision;
    }
    if (!reusable && _tree) {
        ts_tree_delete(_tree);
        _tree = NULL;
    }
    if (!_tree || _treeRevision != snapshot.revision) {
        SCEParserInput source = {
            .snapshot = snapshot,
        };
        TSInput input = {
            .payload = &source,
            .read = SCEReadInput,
            .encoding = TSInputEncodingUTF16LE,
        };
        SCEParserCancellation cancellation = {
            .highlighter = self,
            .cancellationGeneration = cancellationGeneration,
            .revision = snapshot.revision,
        };
        TSParseOptions options = {
            .payload = &cancellation,
            .progress_callback = SCEParseShouldCancel,
        };
        BOOL incremental = _tree != NULL;
        TSTree *parsed = ts_parser_parse_with_options(_parser, _tree, input, options);
        if (_tree) {
            ts_tree_delete(_tree);
        }
        _tree = parsed;
        if (!parsed) {
            ts_parser_reset(_parser);
            return nil;
        }
        _treeRevision = snapshot.revision;
        _treeDocumentIdentifier = snapshot.documentIdentifier;
        [_stateLock lock];
        _parseCount++;
        if (incremental) {
            _incrementalParseCount++;
        }
        [_stateLock unlock];
    }
    NSMutableData *capturedData = [NSMutableData data];
    const NSUInteger *priorities = _capturePriorities.bytes;
    TSQueryCursor *cursor = ts_query_cursor_new();
    ts_query_cursor_set_match_limit(cursor, 16384);
    for (NSValue *value in ranges) {
        NSRange range = value.rangeValue;
        if (!range.length) {
            continue;
        }
        ts_query_cursor_set_byte_range(cursor, (uint32_t)(range.location * sizeof(unichar)),
                                       (uint32_t)(NSMaxRange(range) * sizeof(unichar)));
        ts_query_cursor_exec(cursor, _query, ts_tree_root_node(_tree));
        TSQueryMatch match;
        uint32_t captureIndex;
        while (ts_query_cursor_next_capture(cursor, &match, &captureIndex)) {
            TSQueryCapture capture = match.captures[captureIndex];
            SCECapturedToken token = {
                .start = ts_node_start_byte(capture.node) / sizeof(unichar),
                .end = ts_node_end_byte(capture.node) / sizeof(unichar),
                .captureIndex = capture.index,
                .priority = priorities[capture.index],
            };
            if (token.end > token.start && token.end > range.location && token.start < NSMaxRange(range)) {
                [capturedData appendBytes:&token length:sizeof(token)];
            }
            if (capturedData.length / sizeof(SCECapturedToken) > SCEMaximumCapturedTokenCount ||
                [self shouldCancelGeneration:cancellationGeneration revision:snapshot.revision]) {
                ts_query_cursor_delete(cursor);
                return nil;
            }
        }
        if (ts_query_cursor_did_exceed_match_limit(cursor)) {
            ts_query_cursor_delete(cursor);
            return nil;
        }
    }
    ts_query_cursor_delete(cursor);
    SCECapturedToken *captured = capturedData.mutableBytes;
    NSUInteger count = capturedData.length / sizeof(SCECapturedToken);
    qsort(captured, count, sizeof(SCECapturedToken), SCECompareCapturedTokens);
    NSMutableArray<SCESyntaxToken *> *tokens = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger index = 0; index < count; index++) {
        // A capture that spans several requested ranges is reported once.
        if (index && !SCECompareCapturedTokens(&captured[index - 1], &captured[index])) {
            continue;
        }
        NSRange tokenRange = NSMakeRange(captured[index].start, captured[index].end - captured[index].start);
        [tokens addObject:[[SCESyntaxToken alloc] initWithRange:tokenRange
                                                           kind:_captureKinds[captured[index].captureIndex]]];
    }
    if (!hasRanges) {
        return [[SCESyntaxHighlightResult alloc] initWithRevision:snapshot.revision
                                                     coveredRange:ranges.firstObject.rangeValue
                                                           tokens:tokens];
    }
    return [[SCESyntaxHighlightResult alloc] initWithRevision:snapshot.revision coveredRanges:ranges tokens:tokens];
}

// Regression checks inspect these private, synchronized
// counters to verify that scrolling reuses a parse and editing reuses a tree.
- (NSUInteger)parseCount {
    [_stateLock lock];
    NSUInteger count = _parseCount;
    [_stateLock unlock];
    return count;
}

- (NSUInteger)incrementalParseCount {
    [_stateLock lock];
    NSUInteger count = _incrementalParseCount;
    [_stateLock unlock];
    return count;
}

@end
