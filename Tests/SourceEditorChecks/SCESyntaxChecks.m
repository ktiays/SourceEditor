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
    request.completion([[SCESyntaxHighlightResult alloc] initWithRevision:request.snapshot.revision
                                                             coveredRange:request.range
                                                                   tokens:tokens]);
    SCEDrainMainQueue();
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
    return SCESyntaxCheckCount;
}
