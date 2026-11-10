@import SourceEditor;
#import "SCESyntaxChecks.h"
#import "../../Sources/SourceEditor/SCELineLayoutCache.h"

static NSUInteger SCESyntaxCheckCount;
#define SYNTAX_CHECK(condition, message)                                                                               \
    do {                                                                                                               \
        SCESyntaxCheckCount++;                                                                                         \
        if (!(condition)) {                                                                                            \
            fprintf(stderr, "FAIL syntax core at line %d: %s\n", __LINE__, message);                                   \
            exit(1);                                                                                                   \
        }                                                                                                              \
    } while (0)

@interface SCEControlledRequest : NSObject
@property (nonatomic, strong) SCETextBuffer *snapshot;
@property (nonatomic) NSRange range;
// The ranges of a multiple-range request, or nil.
@property (nonatomic, copy) NSArray<NSValue *> *ranges;
@property (nonatomic, strong) SCETextEdit *edit;
@property (nonatomic, copy) SCESyntaxHighlightCompletion completion;
@end

@implementation SCEControlledRequest
@end

@interface SCEControlledHighlighter : NSObject <SCESyntaxHighlighter>
@property (nonatomic, strong) NSMutableArray<SCEControlledRequest *> *requests;
@property (nonatomic) NSUInteger cancellations;
@end

@implementation SCEControlledHighlighter

- (instancetype)init {
    if ((self = [super init])) {
        _requests = [NSMutableArray array];
    }
    return self;
}

- (void)highlightBuffer:(SCETextBuffer *)snapshot
             UTF16Range:(NSRange)range
              afterEdit:(SCETextEdit *)edit
             completion:(SCESyntaxHighlightCompletion)completion {
    SCEControlledRequest *request = [[SCEControlledRequest alloc] init];
    request.snapshot = snapshot;
    request.range = range;
    request.edit = edit;
    request.completion = completion;
    [_requests addObject:request];
}

- (void)cancelPendingRequests {
    _cancellations++;
}

@end

// Records multiple-range requests as well.
@interface SCEControlledRangeHighlighter : SCEControlledHighlighter
@end

@implementation SCEControlledRangeHighlighter

- (void)highlightBuffer:(SCETextBuffer *)snapshot
            UTF16Ranges:(NSArray<NSValue *> *)ranges
              afterEdit:(SCETextEdit *)edit
             completion:(SCESyntaxHighlightCompletion)completion {
    SCEControlledRequest *request = [[SCEControlledRequest alloc] init];
    request.snapshot = snapshot;
    request.ranges = ranges;
    NSUInteger start = ranges.firstObject.rangeValue.location;
    request.range = NSMakeRange(start, NSMaxRange(ranges.lastObject.rangeValue) - start);
    request.edit = edit;
    request.completion = completion;
    [self.requests addObject:request];
}

@end

// Runs the main run loop until every block already submitted to the main queue,
// such as the editor's result handler, has run. The main queue is FIFO, so a
// sentinel submitted afterward runs last. A fixed run-loop interval is not
// enough: other run-loop work can occupy it before the queue is serviced.
static void SCEDrainMainQueue(void) {
    __block BOOL drained = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        drained = YES;
    });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!drained && deadline.timeIntervalSinceNow > 0) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
    }
}

static void SCEDeliverHighlight(SCEControlledRequest *request, NSArray<SCESyntaxToken *> *tokens) {
    if (request.ranges) {
        request.completion([[SCESyntaxHighlightResult alloc] initWithRevision:request.snapshot.revision
                                                                coveredRanges:request.ranges
                                                                       tokens:tokens]);
    } else {
        request.completion([[SCESyntaxHighlightResult alloc] initWithRevision:request.snapshot.revision
                                                                 coveredRange:request.range
                                                                       tokens:tokens]);
    }
    SCEDrainMainQueue();
}

// Returns a keyword token every stride UTF-16 units within the requested ranges.
static NSArray<SCESyntaxToken *> *SCETokensInRequest(SCEControlledRequest *request, NSUInteger stride) {
    NSMutableArray<SCESyntaxToken *> *tokens = [NSMutableArray array];
    for (NSValue *value in request.ranges ?: @[ [NSValue valueWithRange:request.range] ]) {
        NSRange range = value.rangeValue;
        for (NSUInteger offset = range.location; offset + 4 <= NSMaxRange(range); offset += stride) {
            [tokens addObject:[[SCESyntaxToken alloc] initWithRange:NSMakeRange(offset, 4) kind:SCESyntaxTokenKeyword]];
        }
    }
    return tokens;
}

static SCESyntaxToken *SCEToken(NSUInteger location, NSUInteger length, SCESyntaxTokenKind kind) {
    return [[SCESyntaxToken alloc] initWithRange:NSMakeRange(location, length) kind:kind];
}

static NSArray<NSValue *> *SCERanges(NSRange range) {
    return @[ [NSValue valueWithRange:range] ];
}

static void SCECheckPartialLineTokens(void) {
    NSMutableString *text = [NSMutableString stringWithCapacity:100010];
    while (text.length < 100000) {
        [text appendString:@"word123 "];
    }
    [text appendString:@"\nshort\n"];
    SCETextBuffer *buffer = [[SCETextBuffer alloc] initWithString:text];
    SCELineLayoutCache *cache =
        [[SCELineLayoutCache alloc] initWithBuffer:buffer
                                              font:[NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular]];
    SCESyntaxTokenKind string = SCESyntaxTokenString;
    SCESyntaxTokenKind keyword = SCESyntaxTokenKeyword;
    [cache applySyntaxTokens:@[ SCEToken(50, 100, string), SCEToken(180, 10, keyword) ]
               toUTF16Ranges:SCERanges(NSMakeRange(100, 100))];
    NSDictionary<NSNumber *, NSArray<SCESyntaxToken *> *> *tokens = [cache valueForKey:@"syntaxTokens"];
    SYNTAX_CHECK([tokens[@0] isEqualToArray:(@[ SCEToken(100, 50, string), SCEToken(180, 10, keyword) ])],
                 "tokens of a partly covered line must be clipped to the covered part");
    [cache applySyntaxTokens:@[ SCEToken(310, 10, keyword) ] toUTF16Ranges:SCERanges(NSMakeRange(300, 100))];
    tokens = [cache valueForKey:@"syntaxTokens"];
    SYNTAX_CHECK(
        [tokens[@0]
            isEqualToArray:(@[ SCEToken(100, 50, string), SCEToken(180, 10, keyword), SCEToken(310, 10, keyword) ])],
        "a later window of the same line must keep earlier colors outside it");
    [cache applySyntaxTokens:@[] toUTF16Ranges:SCERanges(NSMakeRange(140, 45))];
    tokens = [cache valueForKey:@"syntaxTokens"];
    SYNTAX_CHECK(
        [tokens[@0]
            isEqualToArray:(@[ SCEToken(100, 40, string), SCEToken(185, 5, keyword), SCEToken(310, 10, keyword) ])],
        "a window must replace earlier colors only inside it");
    [cache applySyntaxTokens:@[ SCEToken(90000, 5, keyword) ] toUTF16Ranges:SCERanges(NSMakeRange(90000, 100))];
    tokens = [cache valueForKey:@"syntaxTokens"];
    SYNTAX_CHECK([tokens[@0] isEqualToArray:@[ SCEToken(90000, 5, keyword) ]],
                 "colors far from a new window must be discarded");
    NSRange shortLine = [buffer UTF16RangeOfLine:1 includingLineEnding:YES];
    [cache applySyntaxTokens:@[ SCEToken(90000, 5, keyword), SCEToken(shortLine.location, 2, keyword) ]
               toUTF16Ranges:@[ [NSValue valueWithRange:NSMakeRange(90000, 10)], [NSValue valueWithRange:shortLine] ]];
    tokens = [cache valueForKey:@"syntaxTokens"];
    SYNTAX_CHECK([tokens[@1] isEqualToArray:@[ SCEToken(0, 2, keyword) ]] &&
                     [tokens[@0] isEqualToArray:@[ SCEToken(90000, 5, keyword) ]],
                 "a multiple-range result must color each covered line");
    puts("PASS partial-line tokens: clipping, windows that keep earlier colors, distance pruning, multiple ranges");
}

static void SCECheckViewportHighlighting(void) {
    NSScrollView *scroll = [SCEEditorView scrollableEditorView];
    scroll.frame = NSMakeRect(0, 0, 600, 400);
    SCEEditorView *editor = (SCEEditorView *)scroll.documentView;
    NSMutableString *text = [NSMutableString string];
    for (NSUInteger line = 0; line < 3000; line++) {
        [text appendFormat:@"line %04lu value\n", (unsigned long)line];
    }
    editor.string = text;
    SCEControlledRangeHighlighter *highlighter = [[SCEControlledRangeHighlighter alloc] init];
    editor.syntaxHighlighter = highlighter;
    SYNTAX_CHECK(highlighter.requests.count == 1, "attaching a highlighter must request only the viewport first");
    SCEControlledRequest *visibleRequest = highlighter.requests[0];
    SCEDeliverHighlight(visibleRequest, SCETokensInRequest(visibleRequest, 16));
    SYNTAX_CHECK(highlighter.requests.count == 2, "viewport colors must start a prefetch of the region around it");
    SCEControlledRequest *prefetch = highlighter.requests[1];
    SYNTAX_CHECK(!prefetch.edit && prefetch.range.location <= visibleRequest.range.location &&
                     NSMaxRange(prefetch.range) > NSMaxRange(visibleRequest.range) + 400,
                 "the prefetch must contain the viewport and extend below it");
    SCEDeliverHighlight(prefetch, SCETokensInRequest(prefetch, 16));
    SYNTAX_CHECK(highlighter.requests.count == 2, "a prefetched viewport must not request again");

    // Lines scrolled into view from the prefetched region already have colors.
    CGFloat lineHeight = [[editor valueForKey:@"lineHeight"] doubleValue];
    [editor scrollPoint:NSMakePoint(0, 20 * lineHeight)];
    SCELineLayoutCache *cache = [editor valueForKey:@"layoutCache"];
    NSDictionary<NSNumber *, NSArray<SCESyntaxToken *> *> *tokens = [cache valueForKey:@"syntaxTokens"];
    NSUInteger bottomLine = (NSUInteger)((20 * lineHeight + 400) / lineHeight);
    SYNTAX_CHECK(tokens[@(bottomLine)].count > 0, "lines scrolled into view must already have prefetched colors");
    SCEControlledRequest *latest = highlighter.requests.lastObject;
    SYNTAX_CHECK(latest == prefetch || (!latest.edit && latest.range.location >= prefetch.range.location &&
                                        NSMaxRange(latest.range) > NSMaxRange(prefetch.range)),
                 "scrolling within prefetched lines may only move the prefetched region");

    // A result for the current revision is applied even after a later request.
    [editor scrollPoint:NSMakePoint(0, 2000 * lineHeight)];
    SCEControlledRequest *far = highlighter.requests.lastObject;
    [editor scrollPoint:NSMakePoint(0, 2003 * lineHeight)];
    SYNTAX_CHECK(highlighter.requests.lastObject != far, "scrolling again must issue a newer request");
    SCEDeliverHighlight(far, SCETokensInRequest(far, 16));
    tokens = [cache valueForKey:@"syntaxTokens"];
    SYNTAX_CHECK(tokens[@2010].count > 0, "a superseded result for the current revision must be applied");
    editor.syntaxHighlighter = nil;

    // A long line is requested only around the viewport, in its own range.
    NSScrollView *longScroll = [SCEEditorView scrollableEditorView];
    longScroll.frame = NSMakeRect(0, 0, 600, 400);
    SCEEditorView *longEditor = (SCEEditorView *)longScroll.documentView;
    NSMutableString *longText = [NSMutableString string];
    while (longText.length < 300000) {
        [longText appendString:@"word123 "];
    }
    [longText appendString:@"\nshort\nlines\n"];
    longEditor.string = longText;
    SCEControlledRangeHighlighter *longHighlighter = [[SCEControlledRangeHighlighter alloc] init];
    longEditor.syntaxHighlighter = longHighlighter;
    SCEControlledRequest *longRequest = longHighlighter.requests.lastObject;
    NSRange window = longRequest.ranges.firstObject.rangeValue;
    SYNTAX_CHECK(longRequest.ranges.count == 2 && window.location == 0 && window.length < 20000 &&
                     longRequest.ranges[1].rangeValue.location == 300001,
                 "a long line must be requested only near the viewport, separately from short lines");
    SCEDeliverHighlight(longRequest, SCETokensInRequest(longRequest, 50));
    SCELineLayoutCache *longCache = [longEditor valueForKey:@"layoutCache"];
    tokens = [longCache valueForKey:@"syntaxTokens"];
    SYNTAX_CHECK(tokens[@0].count > 0 && NSMaxRange(tokens[@0].lastObject.range) <= NSMaxRange(window) &&
                     tokens[@1].count > 0,
                 "colors must reach the requested part of a long line and the short lines");
    [longEditor scrollPoint:NSMakePoint(600000, 0)];
    longRequest = longHighlighter.requests.lastObject;
    window = longRequest.ranges.firstObject.rangeValue;
    SYNTAX_CHECK(window.location > 50000 && window.length < 20000,
                 "horizontal scrolling must request the newly visible part of a long line");
    SCEDeliverHighlight(longRequest, SCETokensInRequest(longRequest, 50));
    tokens = [longCache valueForKey:@"syntaxTokens"];
    BOOL colored = NO;
    for (SCESyntaxToken *token in tokens[@0]) {
        colored = colored || NSLocationInRange(token.range.location, window);
    }
    SYNTAX_CHECK(colored, "the newly visible part of a long line must receive colors");
    puts("PASS viewport highlighting: viewport first, prefetch, scrolling with colors, superseded results, long lines");
}

static BOOL SCEHasColor(SCELineLayout *layout, NSColor *expected) {
    for (id object in (__bridge NSArray *)CTLineGetGlyphRuns(layout.line)) {
        NSDictionary *attributes = (__bridge NSDictionary *)CTRunGetAttributes((__bridge CTRunRef)object);
        CGColorRef color = (__bridge CGColorRef)attributes[(__bridge NSString *)kCTForegroundColorAttributeName];
        if (color && CGColorEqualToColor(color, expected.CGColor)) {
            return YES;
        }
    }
    return NO;
}

static BOOL SCEHasColorAt(SCELineLayout *layout, NSUInteger index, NSColor *expected) {
    for (id object in (__bridge NSArray *)CTLineGetGlyphRuns(layout.line)) {
        CTRunRef run = (__bridge CTRunRef)object;
        CFRange range = CTRunGetStringRange(run);
        if (index < (NSUInteger)range.location || index >= (NSUInteger)(range.location + range.length)) {
            continue;
        }
        NSDictionary *attributes = (__bridge NSDictionary *)CTRunGetAttributes(run);
        CGColorRef color = (__bridge CGColorRef)attributes[(__bridge NSString *)kCTForegroundColorAttributeName];
        return color && CGColorEqualToColor(color, expected.CGColor);
    }
    return NO;
}

NSUInteger SCECheckSyntaxCore(void) {
    SCETextBuffer *buffer = [[SCETextBuffer alloc] initWithString:@"const value = 42;\nnext\n"];
    SCETextBuffer *copy = [buffer copy];
    SYNTAX_CHECK([copy.documentIdentifier isEqual:buffer.documentIdentifier],
                 "snapshots must preserve document identity");
    SYNTAX_CHECK(![buffer.documentIdentifier isEqual:[[SCETextBuffer alloc] init].documentIdentifier],
                 "independent documents need independent identities");
    unichar actual[12];
    unichar expected[12];
    NSRange readRange = NSMakeRange(3, 12);
    [buffer getUTF16Characters:actual range:readRange];
    [buffer.string getCharacters:expected range:readRange];
    SYNTAX_CHECK(!memcmp(actual, expected, sizeof(actual)), "direct rope character reads must match NSString");
    [buffer getUTF16Characters:NULL range:NSMakeRange(buffer.lengthUTF16, 0)];

    SCELineLayoutCache *cache =
        [[SCELineLayoutCache alloc] initWithBuffer:buffer
                                              font:[NSFont monospacedSystemFontOfSize:14 weight:NSFontWeightRegular]];
    cache.syntaxTheme = [[SCESyntaxTheme alloc] initWithForegroundColors:@{
        SCESyntaxTokenKeyword : NSColor.redColor,
    }];
    SCELineLayout *plain = [cache layoutForLineAtIndex:0];
    SCELineLayout *unchanged = [cache layoutForLineAtIndex:1];
    SCESyntaxToken *keyword = [[SCESyntaxToken alloc] initWithRange:NSMakeRange(0, 5) kind:SCESyntaxTokenKeyword];
    SYNTAX_CHECK([cache applySyntaxTokens:@[ keyword ] toLineRange:NSMakeRange(0, 2)],
                 "new syntax colors must invalidate affected layouts");
    SCELineLayout *colored = [cache layoutForLineAtIndex:0];
    SYNTAX_CHECK(colored != plain && SCEHasColor(colored, NSColor.redColor),
                 "semantic tokens must reach Core Text foreground attributes");
    SYNTAX_CHECK(fabs(plain.width - colored.width) < 1e-8, "coloring must preserve layout geometry");
    SYNTAX_CHECK([cache layoutForLineAtIndex:1] == unchanged,
                 "unaffected line layouts must survive a highlight result");
    SYNTAX_CHECK(![cache applySyntaxTokens:@[ keyword ] toLineRange:NSMakeRange(0, 2)],
                 "identical highlighting must not invalidate layouts");
    SYNTAX_CHECK([cache layoutForLineAtIndex:0] == colored, "identical highlighting must reuse its CTLine");
    [cache removeAllSyntaxTokens];
    SYNTAX_CHECK(!SCEHasColor([cache layoutForLineAtIndex:0], NSColor.redColor),
                 "detaching syntax must restore plain colors");

    cache.syntaxTheme = [[SCESyntaxTheme alloc] initWithForegroundColors:@{
        SCESyntaxTokenString : NSColor.redColor,
    }];
    SCESyntaxToken *outer = [[SCESyntaxToken alloc] initWithRange:NSMakeRange(0, 5) kind:SCESyntaxTokenString];
    SCESyntaxToken *inner = [[SCESyntaxToken alloc] initWithRange:NSMakeRange(1, 3) kind:SCESyntaxTokenVariable];
    [cache applySyntaxTokens:@[ outer, inner ] toLineRange:NSMakeRange(0, 1)];
    SYNTAX_CHECK(SCEHasColorAt([cache layoutForLineAtIndex:0], 0, NSColor.redColor) &&
                     !SCEHasColorAt([cache layoutForLineAtIndex:0], 2, NSColor.redColor),
                 "unconfigured inner token kinds must reset an outer scope to the plain foreground");

    SCESyntaxToken *name = [[SCESyntaxToken alloc] initWithRange:NSMakeRange(18, 4) kind:SCESyntaxTokenVariable];
    [cache applySyntaxTokens:@[ keyword, name ] toLineRange:NSMakeRange(0, 2)];
    SCETextBuffer *beforeTyping = [buffer copy];
    [buffer replaceCharactersInUTF16Range:NSMakeRange(2, 0) withString:@"x"];
    [cache invalidateForReplacementOfUTF16Range:NSMakeRange(2, 0) replacementLength:1 previousBuffer:beforeTyping];
    NSDictionary<NSNumber *, NSArray<SCESyntaxToken *> *> *pending = [cache valueForKey:@"syntaxTokens"];
    SYNTAX_CHECK(pending[@0].count == 1 && NSEqualRanges(pending[@0][0].range, NSMakeRange(0, 6)),
                 "text typed inside a token must keep and extend its previous color");
    SYNTAX_CHECK(pending[@1].count == 1 && NSEqualRanges(pending[@1][0].range, NSMakeRange(0, 4)),
                 "tokens on lines after the edit must move with their lines");
    // Deleting the line ending joins both lines; each token keeps its color at its new column.
    SCETextBuffer *beforeJoin = [buffer copy];
    [buffer replaceCharactersInUTF16Range:NSMakeRange(18, 1) withString:@""];
    [cache invalidateForReplacementOfUTF16Range:NSMakeRange(18, 1) replacementLength:0 previousBuffer:beforeJoin];
    pending = [cache valueForKey:@"syntaxTokens"];
    NSMutableSet<NSValue *> *joinedRanges = [NSMutableSet set];
    for (SCESyntaxToken *token in pending[@0]) {
        [joinedRanges addObject:[NSValue valueWithRange:token.range]];
    }
    NSSet<NSValue *> *expectedRanges = [NSSet
        setWithObjects:[NSValue valueWithRange:NSMakeRange(0, 6)], [NSValue valueWithRange:NSMakeRange(18, 4)], nil];
    SYNTAX_CHECK(pending[@0].count == 2 && [joinedRanges isEqualToSet:expectedRanges] && pending[@1] == nil,
                 "joined lines must carry both lines' tokens into the merged line");
    [cache removeAllSyntaxTokens];

    SCEEditorView *editor = [[SCEEditorView alloc] initWithFrame:NSMakeRect(0, 0, 600, 400)];
    editor.string = @"const value = 42;\n";
    editor.syntaxTheme = [[SCESyntaxTheme alloc] initWithForegroundColors:@{
        SCESyntaxTokenKeyword : NSColor.redColor,
    }];
    SYNTAX_CHECK(editor.syntaxHighlighter == nil, "the editor must default to a standalone plain editor");
    SCEControlledHighlighter *highlighter = [[SCEControlledHighlighter alloc] init];
    editor.syntaxHighlighter = highlighter;
    SCEControlledRequest *first = highlighter.requests.lastObject;
    SYNTAX_CHECK(first && first.range.length == editor.string.length,
                 "attaching a highlighter must request the visible text");
    SCEDeliverHighlight(first, @[ keyword ]);
    SCELineLayoutCache *editorCache = [editor valueForKey:@"layoutCache"];
    NSDictionary *styles = [editorCache valueForKey:@"syntaxTokens"];
    SYNTAX_CHECK([styles[@0] count] == 1, "current results must be applied");
    editor.selectedRange = NSMakeRange(0, 0);
    [editor insertText:@"// " replacementRange:NSMakeRange(NSNotFound, 0)];
    SCEControlledRequest *latest = highlighter.requests.lastObject;
    SYNTAX_CHECK(latest != first && latest.edit.previousRevision == first.snapshot.revision,
                 "editing must forward exact incremental metadata");
    styles = [editorCache valueForKey:@"syntaxTokens"];
    SYNTAX_CHECK([styles[@0] count] == 1 && NSEqualRanges([styles[@0][0] range], NSMakeRange(3, 5)),
                 "edited lines must keep previous colors, shifted past text inserted before a token");
    SYNTAX_CHECK(SCEHasColorAt([editorCache layoutForLineAtIndex:0], 3, NSColor.redColor) &&
                     !SCEHasColorAt([editorCache layoutForLineAtIndex:0], 0, NSColor.redColor),
                 "provisional colors must reach the rebuilt layout while the highlight is pending");
    SCEDeliverHighlight(first, @[ keyword ]);
    styles = [editorCache valueForKey:@"syntaxTokens"];
    SYNTAX_CHECK(NSEqualRanges([styles[@0][0] range], NSMakeRange(3, 5)), "a stale result must not recolor newer text");
    latest.completion(nil);
    SCEDrainMainQueue();
    styles = [editorCache valueForKey:@"syntaxTokens"];
    SYNTAX_CHECK([styles[@0] count] == 1, "a nil result must keep the current colors");
    SCESyntaxToken *comment = [[SCESyntaxToken alloc] initWithRange:NSMakeRange(0, latest.snapshot.lengthUTF16)
                                                               kind:SCESyntaxTokenComment];
    SCEDeliverHighlight(latest, @[ comment ]);
    styles = [editorCache valueForKey:@"syntaxTokens"];
    SYNTAX_CHECK([styles[@0] count] == 1 &&
                     [((SCESyntaxToken *)styles[@0][0]).kind isEqualToString:SCESyntaxTokenComment],
                 "latest results must replace provisional presentation");
    NSUInteger requestCount = highlighter.requests.count;
    editor.syntaxTheme = [[SCESyntaxTheme alloc] initWithForegroundColors:@{
        SCESyntaxTokenComment : NSColor.blueColor,
    }];
    SYNTAX_CHECK(highlighter.requests.count == requestCount, "theme changes must not reparse text");
    SCESyntaxTheme *editorTheme = [[SCESyntaxTheme alloc] initWithForegroundColors:@{}
                                                                      editorColors:@{
                                                                          SCEEditorColorText : NSColor.greenColor,
                                                                          SCEEditorColorBackground : NSColor.blackColor
                                                                      }];
    SYNTAX_CHECK([editorTheme editorColorForKey:SCEEditorColorBackground] == NSColor.blackColor &&
                     [editorTheme editorColorForKey:SCEEditorColorCaret] == nil,
                 "a theme must report only the editor colors it sets");
    editor.syntaxTheme = editorTheme;
    NSColor *green = [NSColor.greenColor colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
    SYNTAX_CHECK([editorCache.textColor isEqual:green], "a theme's text color must reach plain text");
    NSTextInsertionIndicator *caret = [editor valueForKey:@"caretIndicator"];
    SYNTAX_CHECK([caret.color isEqual:NSColor.controlAccentColor], "the caret must follow the accent color by default");
    editor.syntaxTheme = [[SCESyntaxTheme alloc] initWithForegroundColors:@{}
                                                             editorColors:@{SCEEditorColorCaret : NSColor.orangeColor}];
    SYNTAX_CHECK([caret.color isEqual:NSColor.orangeColor], "a theme's caret color must override the accent color");
    editor.syntaxTheme = editorTheme;
    editor.syntaxTheme = [[SCESyntaxTheme alloc] initWithForegroundColors:@{
        SCESyntaxTokenComment : NSColor.blueColor,
    }];
    SYNTAX_CHECK(![editorCache.textColor isEqual:green], "removing a theme's text color must restore the default");
    editor.syntaxHighlighter = nil;
    SYNTAX_CHECK(highlighter.cancellations == 1, "detaching a highlighter must cancel its work");
    SCEDeliverHighlight(latest, @[ comment ]);
    styles = [editorCache valueForKey:@"syntaxTokens"];
    SYNTAX_CHECK(styles.count == 0 && !SCEHasColor([editorCache layoutForLineAtIndex:0], NSColor.blueColor),
                 "late completion after detach must stay plain");
    [editor insertText:@"plain" replacementRange:NSMakeRange(NSNotFound, 0)];
    SYNTAX_CHECK([editor.string hasPrefix:@"// plain"], "editing must continue after removing the highlighter");

    SCETextBuffer *coordinates = [[SCETextBuffer alloc] initWithString:@"a\U0001f642\r\nbc"];
    SCETextBuffer *before = [coordinates copy];
    [coordinates replaceCharactersInUTF16Range:NSMakeRange(1, 4) withString:@"\u4e2d\nx"];
    SCETextEdit *edit = [[SCETextEdit alloc] initWithRange:NSMakeRange(1, 4)
                                       insertedLengthUTF16:3
                                              beforeBuffer:before
                                               afterBuffer:coordinates];
    SYNTAX_CHECK(edit.startLine == 0 && edit.startColumnUTF16 == 1 && edit.oldEndLine == 1 &&
                     edit.oldEndColumnUTF16 == 0 && edit.newEndLine == 1 && edit.newEndColumnUTF16 == 1,
                 "edit coordinates must count UTF-16 units and preserve CRLF rows");
    puts(
        "PASS syntax core: engine-independent injection, Core Text colors, cache reuse, stale-result rejection, detach, UTF-16 edits");
    SCECheckPartialLineTokens();
    SCECheckViewportHighlighting();
    return SCESyntaxCheckCount;
}
