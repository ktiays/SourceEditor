@import SourceEditor;
#import "SESyntaxChecks.h"
#import "../../Sources/SourceEditor/SELineLayoutCache.h"

static NSUInteger SESyntaxCheckCount;
#define SYNTAX_CHECK(condition, message)                                                                               \
    do {                                                                                                               \
        SESyntaxCheckCount++;                                                                                          \
        if (!(condition)) {                                                                                            \
            fprintf(stderr, "FAIL syntax core at line %d: %s\n", __LINE__, message);                                   \
            exit(1);                                                                                                   \
        }                                                                                                              \
    } while (0)

@interface SEControlledRequest : NSObject
@property (nonatomic, strong) SETextBuffer *snapshot;
@property (nonatomic) NSRange range;
@property (nonatomic, strong) SETextEdit *edit;
@property (nonatomic, copy) SESyntaxHighlightCompletion completion;
@end

@implementation SEControlledRequest
@end

@interface SEControlledHighlighter : NSObject <SESyntaxHighlighter>
@property (nonatomic, strong) NSMutableArray<SEControlledRequest *> *requests;
@property (nonatomic) NSUInteger cancellations;
@end

@implementation SEControlledHighlighter

- (instancetype)init {
    if ((self = [super init]))
        _requests = [NSMutableArray array];
    return self;
}

- (void)highlightBuffer:(SETextBuffer *)snapshot
             UTF16Range:(NSRange)range
              afterEdit:(SETextEdit *)edit
             completion:(SESyntaxHighlightCompletion)completion {
    SEControlledRequest *request = [[SEControlledRequest alloc] init];
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

static void SEDeliverHighlight(SEControlledRequest *request, NSArray<SESyntaxToken *> *tokens) {
    request.completion([[SESyntaxHighlightResult alloc] initWithRevision:request.snapshot.revision
                                                            coveredRange:request.range
                                                                  tokens:tokens]);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);
}

static BOOL SEHasColor(SELineLayout *layout, NSColor *expected) {
    for (id object in (__bridge NSArray *)CTLineGetGlyphRuns(layout.line)) {
        NSDictionary *attributes = (__bridge NSDictionary *)CTRunGetAttributes((__bridge CTRunRef)object);
        CGColorRef color = (__bridge CGColorRef)attributes[(__bridge NSString *)kCTForegroundColorAttributeName];
        if (color && CGColorEqualToColor(color, expected.CGColor))
            return YES;
    }
    return NO;
}

static BOOL SEHasColorAt(SELineLayout *layout, NSUInteger index, NSColor *expected) {
    for (id object in (__bridge NSArray *)CTLineGetGlyphRuns(layout.line)) {
        CTRunRef run = (__bridge CTRunRef)object;
        CFRange range = CTRunGetStringRange(run);
        if (index < (NSUInteger)range.location || index >= (NSUInteger)(range.location + range.length))
            continue;
        NSDictionary *attributes = (__bridge NSDictionary *)CTRunGetAttributes(run);
        CGColorRef color = (__bridge CGColorRef)attributes[(__bridge NSString *)kCTForegroundColorAttributeName];
        return color && CGColorEqualToColor(color, expected.CGColor);
    }
    return NO;
}

NSUInteger SECheckSyntaxCore(void) {
    SETextBuffer *buffer = [[SETextBuffer alloc] initWithString:@"const value = 42;\nnext\n"];
    SETextBuffer *copy = [buffer copy];
    SYNTAX_CHECK(
        [copy.documentIdentifier isEqual:buffer.documentIdentifier], "snapshots must preserve document identity");
    SYNTAX_CHECK(![buffer.documentIdentifier isEqual:[[SETextBuffer alloc] init].documentIdentifier],
        "independent documents need independent identities");
    unichar actual[12];
    unichar expected[12];
    NSRange readRange = NSMakeRange(3, 12);
    [buffer getUTF16Characters:actual range:readRange];
    [buffer.string getCharacters:expected range:readRange];
    SYNTAX_CHECK(!memcmp(actual, expected, sizeof(actual)), "direct Rope character reads must match NSString");
    [buffer getUTF16Characters:NULL range:NSMakeRange(buffer.lengthUTF16, 0)];

    SELineLayoutCache *cache =
        [[SELineLayoutCache alloc] initWithBuffer:buffer
                                             font:[NSFont monospacedSystemFontOfSize:14 weight:NSFontWeightRegular]];
    cache.syntaxTheme = [[SESyntaxTheme alloc] initWithForegroundColors:@{
        SESyntaxTokenKeyword : NSColor.redColor,
    }];
    SELineLayout *plain = [cache layoutForLineAtIndex:0];
    SELineLayout *unchanged = [cache layoutForLineAtIndex:1];
    SESyntaxToken *keyword = [[SESyntaxToken alloc] initWithRange:NSMakeRange(0, 5) kind:SESyntaxTokenKeyword];
    SYNTAX_CHECK([cache applySyntaxTokens:@[ keyword ] toLineRange:NSMakeRange(0, 2)],
        "new syntax colors must invalidate affected layouts");
    SELineLayout *colored = [cache layoutForLineAtIndex:0];
    SYNTAX_CHECK(colored != plain && SEHasColor(colored, NSColor.redColor),
        "semantic tokens must reach Core Text foreground attributes");
    SYNTAX_CHECK(fabs(plain.width - colored.width) < 1e-8, "coloring must preserve layout geometry");
    SYNTAX_CHECK(
        [cache layoutForLineAtIndex:1] == unchanged, "unaffected line layouts must survive a highlight result");
    SYNTAX_CHECK(![cache applySyntaxTokens:@[ keyword ] toLineRange:NSMakeRange(0, 2)],
        "identical highlighting must not invalidate layouts");
    SYNTAX_CHECK([cache layoutForLineAtIndex:0] == colored, "identical highlighting must reuse its CTLine");
    [cache removeAllSyntaxTokens];
    SYNTAX_CHECK(
        !SEHasColor([cache layoutForLineAtIndex:0], NSColor.redColor), "detaching syntax must restore plain colors");

    cache.syntaxTheme = [[SESyntaxTheme alloc] initWithForegroundColors:@{
        SESyntaxTokenString : NSColor.redColor,
    }];
    SESyntaxToken *outer = [[SESyntaxToken alloc] initWithRange:NSMakeRange(0, 5) kind:SESyntaxTokenString];
    SESyntaxToken *inner = [[SESyntaxToken alloc] initWithRange:NSMakeRange(1, 3) kind:SESyntaxTokenVariable];
    [cache applySyntaxTokens:@[ outer, inner ] toLineRange:NSMakeRange(0, 1)];
    SYNTAX_CHECK(SEHasColorAt([cache layoutForLineAtIndex:0], 0, NSColor.redColor)
            && !SEHasColorAt([cache layoutForLineAtIndex:0], 2, NSColor.redColor),
        "unconfigured inner token kinds must reset an outer scope to the plain foreground");

    SEEditorView *editor = [[SEEditorView alloc] initWithFrame:NSMakeRect(0, 0, 600, 400)];
    editor.string = @"const value = 42;\n";
    SYNTAX_CHECK(editor.syntaxHighlighter == nil, "the editor must default to a standalone plain editor");
    SEControlledHighlighter *provider = [[SEControlledHighlighter alloc] init];
    editor.syntaxHighlighter = provider;
    SEControlledRequest *first = provider.requests.lastObject;
    SYNTAX_CHECK(
        first && first.range.length == editor.string.length, "attaching a provider must request the visible text");
    SEDeliverHighlight(first, @[ keyword ]);
    SELineLayoutCache *editorCache = [editor valueForKey:@"layoutCache"];
    NSDictionary *styles = [editorCache valueForKey:@"syntaxTokens"];
    SYNTAX_CHECK([styles[@0] count] == 1, "current results must be applied");
    editor.selectedRange = NSMakeRange(0, 0);
    [editor insertText:@"// " replacementRange:NSMakeRange(NSNotFound, 0)];
    SEControlledRequest *latest = provider.requests.lastObject;
    SYNTAX_CHECK(latest != first && latest.edit.previousRevision == first.snapshot.revision,
        "editing must forward exact incremental metadata");
    SEDeliverHighlight(first, @[ keyword ]);
    styles = [editorCache valueForKey:@"syntaxTokens"];
    SYNTAX_CHECK(styles.count == 0, "a stale result must not recolor newer text");
    SESyntaxToken *comment = [[SESyntaxToken alloc] initWithRange:NSMakeRange(0, latest.snapshot.lengthUTF16)
                                                             kind:SESyntaxTokenComment];
    SEDeliverHighlight(latest, @[ comment ]);
    styles = [editorCache valueForKey:@"syntaxTokens"];
    SYNTAX_CHECK([styles[@0] count] == 1, "latest results must replace stale presentation");
    NSUInteger requestCount = provider.requests.count;
    editor.syntaxTheme = [[SESyntaxTheme alloc] initWithForegroundColors:@{
        SESyntaxTokenComment : NSColor.blueColor,
    }];
    SYNTAX_CHECK(provider.requests.count == requestCount, "theme changes must not reparse text");
    editor.syntaxHighlighter = nil;
    SYNTAX_CHECK(provider.cancellations == 1, "detaching a provider must cancel its work");
    SEDeliverHighlight(latest, @[ comment ]);
    styles = [editorCache valueForKey:@"syntaxTokens"];
    SYNTAX_CHECK(styles.count == 0 && !SEHasColor([editorCache layoutForLineAtIndex:0], NSColor.blueColor),
        "late completion after detach must stay plain");
    [editor insertText:@"plain" replacementRange:NSMakeRange(NSNotFound, 0)];
    SYNTAX_CHECK([editor.string hasPrefix:@"// plain"], "editing must continue after removing the highlighter");

    SETextBuffer *coordinates = [[SETextBuffer alloc] initWithString:@"a🙂\r\nbc"];
    SETextBuffer *before = [coordinates copy];
    [coordinates replaceCharactersInUTF16Range:NSMakeRange(1, 4) withString:@"中\nx"];
    SETextEdit *edit = [[SETextEdit alloc] initWithRange:NSMakeRange(1, 4)
                                     insertedLengthUTF16:3
                                                  before:before
                                                   after:coordinates];
    SYNTAX_CHECK(edit.startLine == 0 && edit.startColumnUTF16 == 1 && edit.oldEndLine == 1
            && edit.oldEndColumnUTF16 == 0 && edit.newEndLine == 1 && edit.newEndColumnUTF16 == 1,
        "edit coordinates must count UTF-16 units and preserve CRLF rows");
    puts(
        "PASS syntax core: engine-independent injection, Core Text colors, cache reuse, stale-result rejection, detach, UTF-16 edits");
    return SESyntaxCheckCount;
}
