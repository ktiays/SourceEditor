@import SourceEditor;
#import <mach/mach.h>
#import <time.h>
#import "SCELargeDocumentChecks.h"
#import "../../Sources/SourceEditor/SCELineLayoutCache.h"

static NSUInteger SCELargeDocumentCheckCount;
#define LARGE_CHECK(condition, message)                                                                                \
    do {                                                                                                               \
        SCELargeDocumentCheckCount++;                                                                                  \
        if (!(condition)) {                                                                                            \
            fprintf(stderr, "FAIL large documents at line %d: %s\n", __LINE__, (message));                             \
            exit(1);                                                                                                   \
        }                                                                                                              \
    } while (0)

@interface SCEEditorView (LargeDocumentChecks)
- (void)drawTextSurface:(NSView *)surface;
- (void)drawBackgroundSurface:(NSView *)surface;
@end

static uint64_t SCELargeDocumentRandomState = 0x5ce1a7e0;

static NSUInteger SCELargeDocumentRandom(NSUInteger upper) {
    SCELargeDocumentRandomState ^= SCELargeDocumentRandomState << 13;
    SCELargeDocumentRandomState ^= SCELargeDocumentRandomState >> 7;
    SCELargeDocumentRandomState ^= SCELargeDocumentRandomState << 17;
    return upper ? (NSUInteger)(SCELargeDocumentRandomState % upper) : 0;
}

static NSURL *SCEWriteTemporaryFile(NSData *data) {
    NSString *name = [NSString stringWithFormat:@"SourceEditorChecks-%@.txt", NSUUID.UUID.UUIDString];
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
    [data writeToURL:url atomically:NO];
    return url;
}

// Compares line structure and random reads with an NSString reference.
static void SCECheckBufferMatchesString(SCETextBuffer *buffer, NSString *reference) {
    LARGE_CHECK(buffer.lengthUTF16 == reference.length, "file-backed UTF-16 length differs");
    LARGE_CHECK([buffer.string isEqualToString:reference], "file-backed text differs");
    NSUInteger line = 0;
    NSUInteger lineStart = 0;
    for (NSUInteger index = 0; index <= reference.length; index++) {
        if (index < reference.length && [reference characterAtIndex:index] != '\n') {
            continue;
        }
        NSUInteger end = index < reference.length ? index + 1 : index;
        NSUInteger contentEnd = index;
        if (index < reference.length && contentEnd > lineStart && [reference characterAtIndex:contentEnd - 1] == '\r') {
            contentEnd--;
        }
        if (line % 97 == 0 || index == reference.length) {
            LARGE_CHECK(NSEqualRanges([buffer UTF16RangeOfLine:line includingLineEnding:YES],
                                      NSMakeRange(lineStart, end - lineStart)),
                        "file-backed line range differs");
            LARGE_CHECK(NSEqualRanges([buffer UTF16RangeOfLine:line includingLineEnding:NO],
                                      NSMakeRange(lineStart, contentEnd - lineStart)),
                        "file-backed line content range differs");
            LARGE_CHECK([buffer lineIndexForUTF16Offset:lineStart] == line, "file-backed offset-to-line differs");
        }
        line++;
        lineStart = end;
    }
    LARGE_CHECK(buffer.lineCount == line, "file-backed line count differs");
    for (NSUInteger iteration = 0; iteration < 64; iteration++) {
        NSUInteger start = SCELargeDocumentRandom(reference.length + 1);
        NSUInteger length = SCELargeDocumentRandom(MIN(40000, reference.length - start) + 1);
        NSRange range = NSMakeRange(start, length);
        unichar *actual = malloc(MAX(1, length) * sizeof(unichar));
        unichar *expected = malloc(MAX(1, length) * sizeof(unichar));
        [buffer getUTF16Characters:actual range:range];
        [reference getCharacters:expected range:range];
        LARGE_CHECK(!memcmp(actual, expected, length * sizeof(unichar)), "file-backed range read differs");
        free(actual);
        free(expected);
    }
}

static void SCECheckFileBackedBuffers(void) {
    // Mixed-width UTF-8 across many 16 KiB leaves. The explicit prefixes put a
    // four-byte and a three-byte sequence across the first two leaf boundaries.
    NSMutableString *reference = [NSMutableString string];
    [reference appendString:[@"" stringByPaddingToLength:16383 withString:@"a" startingAtIndex:0]];
    [reference appendString:@"\U0001F642"];
    [reference appendString:[@"" stringByPaddingToLength:16379 withString:@"b" startingAtIndex:0]];
    [reference appendString:@"中\n"];
    NSArray<NSString *> *pieces = @[
        @"line", @" ", @"\t", @"\n", @"\r\n", @"é", @"é", @"中文", @"\U0001F468‍\U0001F469", @"אב", @"{\"key\":1}"
    ];
    while (reference.length < 400000) {
        [reference appendString:pieces[SCELargeDocumentRandom(pieces.count)]];
    }
    NSURL *url = SCEWriteTemporaryFile([reference dataUsingEncoding:NSUTF8StringEncoding]);
    NSError *error = nil;
    SCETextBuffer *buffer = [[SCETextBuffer alloc] initWithContentsOfURL:url error:&error];
    LARGE_CHECK(buffer && !error, "a UTF-8 file must open");
    SCECheckBufferMatchesString(buffer, reference);

    // Edits replace only the leaves they touch; earlier snapshots keep the file text.
    SCETextBuffer *original = [buffer copy];
    NSString *originalText = [reference copy];
    NSArray<NSString *> *insertions = @[ @"", @"x", @"\n", @"\r\n", @"中", @"\U0001F642", @"one\ntwo" ];
    for (NSUInteger iteration = 0; iteration < 3000; iteration++) {
        @autoreleasepool {
            NSUInteger start = SCELargeDocumentRandom(reference.length + 1);
            NSUInteger length = SCELargeDocumentRandom(MIN(5000, reference.length - start) + 1);
            NSString *insertion = insertions[SCELargeDocumentRandom(insertions.count)];
            [buffer replaceCharactersInUTF16Range:NSMakeRange(start, length) withString:insertion];
            [reference replaceCharactersInRange:NSMakeRange(start, length) withString:insertion];
        }
    }
    SCECheckBufferMatchesString(buffer, reference);
    SCECheckBufferMatchesString(original, originalText);

    // Sharing a buffer's nodes inserts its text without copying it.
    SCETextBuffer *combined = [[SCETextBuffer alloc] initWithString:@"head\ntail"];
    [combined replaceCharactersInUTF16Range:NSMakeRange(5, 0) withBuffer:original];
    SCECheckBufferMatchesString(combined, [NSString stringWithFormat:@"head\n%@tail", originalText]);
    [combined replaceCharactersInUTF16Range:NSMakeRange(0, combined.lengthUTF16) withBuffer:combined];
    LARGE_CHECK(combined.lengthUTF16 == originalText.length + 9, "replacing a buffer with itself must keep its text");
    [[NSFileManager defaultManager] removeItemAtURL:url error:NULL];

    // A byte order mark is not text. Each maximal ill-formed subsequence becomes
    // one U+FFFD, including a truncated sequence that starts before a leaf boundary.
    NSMutableData *bytes = [NSMutableData dataWithBytes:"\xEF\xBB\xBF"
                                                        "a\xC3"
                                                        "b"
                                                 length:6];
    const char *invalid = "\xE0\x80|\xF0\x9F\x98|\xED\xA0\x80|\xFF|\xC0\xAF|\xF4\x90\x80\x80|";
    [bytes appendBytes:invalid length:strlen(invalid)];
    NSMutableString *expected = [NSMutableString stringWithString:@"a�b"];
    [expected appendString:@"��|�|���|�|��|����|"];
    NSUInteger padding = 16384 - 1 - bytes.length;
    NSString *filler = [@"" stringByPaddingToLength:padding withString:@"x" startingAtIndex:0];
    [bytes appendData:[filler dataUsingEncoding:NSUTF8StringEncoding]];
    [expected appendString:filler];
    [bytes appendBytes:"\xF0\x9F"
                       "y\r\n"
                length:5];
    [expected appendString:@"�y\r\n"];
    url = SCEWriteTemporaryFile(bytes);
    buffer = [[SCETextBuffer alloc] initWithContentsOfURL:url error:NULL];
    SCECheckBufferMatchesString(buffer, expected);
    [[NSFileManager defaultManager] removeItemAtURL:url error:NULL];

    url = SCEWriteTemporaryFile([NSData data]);
    buffer = [[SCETextBuffer alloc] initWithContentsOfURL:url error:NULL];
    LARGE_CHECK(buffer.lengthUTF16 == 0 && buffer.lineCount == 1 && [buffer.string isEqualToString:@""],
                "an empty file must produce an empty buffer");
    [buffer replaceCharactersInUTF16Range:NSMakeRange(0, 0) withString:@"typed"];
    LARGE_CHECK([buffer.string isEqualToString:@"typed"], "an empty file buffer must accept edits");
    [[NSFileManager defaultManager] removeItemAtURL:url error:NULL];

    error = nil;
    buffer = [[SCETextBuffer alloc] initWithContentsOfURL:url error:&error];
    LARGE_CHECK(!buffer && [error.domain isEqual:NSCocoaErrorDomain] && error.code == NSFileReadNoSuchFileError,
                "a missing file must report NSFileReadNoSuchFileError");
    error = nil;
    buffer = [[SCETextBuffer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:NSTemporaryDirectory()] error:&error];
    LARGE_CHECK(!buffer && error, "a directory must not open as a document");

    // The editor adopts a file buffer like a string: selection and undo reset,
    // and later edits do not reach the opened buffer.
    NSScrollView *scroll = [SCEEditorView scrollableEditorView];
    scroll.frame = NSMakeRect(0, 0, 800, 600);
    SCEEditorView *editor = (SCEEditorView *)scroll.documentView;
    editor.string = @"draft";
    editor.selectedRange = NSMakeRange(5, 0);
    [editor insertText:@"!" replacementRange:NSMakeRange(NSNotFound, 0)];
    [editor replaceContentsWithBuffer:original];
    LARGE_CHECK(editor.lineCount == original.lineCount && NSEqualRanges(editor.selectedRange, NSMakeRange(0, 0)) &&
                    !editor.undoManager.canUndo,
                "adopting a buffer must reset selection and undo");
    [editor insertText:@"edit" replacementRange:NSMakeRange(NSNotFound, 0)];
    LARGE_CHECK([[editor.bufferSnapshot substringWithUTF16Range:NSMakeRange(0, 4)] isEqualToString:@"edit"] &&
                    [original.string isEqualToString:originalText],
                "editing an adopted buffer must not change the source buffer");
    puts("PASS file-backed buffers: leaf boundaries, edits, snapshots, shared insertion, BOM, ill-formed UTF-8, "
         "errors, editor adoption");
}

static BOOL SCERunHasColor(CTLineRef line, NSUInteger index, NSColor *expected) {
    for (id object in (__bridge NSArray *)CTLineGetGlyphRuns(line)) {
        CTRunRef run = (__bridge CTRunRef)object;
        CFRange range = CTRunGetStringRange(run);
        if (index >= (NSUInteger)range.location && index < (NSUInteger)(range.location + range.length)) {
            NSDictionary *attributes = (__bridge NSDictionary *)CTRunGetAttributes(run);
            CGColorRef color = (__bridge CGColorRef)attributes[(__bridge NSString *)kCTForegroundColorAttributeName];
            return color && CGColorEqualToColor(color, expected.CGColor);
        }
    }
    return NO;
}

static void SCECheckFragmentedLayouts(void) {
    NSFont *font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    NSMutableString *text = [NSMutableString string];
    while (text.length < 300000) {
        [text appendFormat:@"word%lu ", (unsigned long)SCELargeDocumentRandom(100000)];
    }
    SCETextBuffer *buffer = [[SCETextBuffer alloc] initWithString:text];
    SCELineLayoutCache *cache = [[SCELineLayoutCache alloc] initWithBuffer:buffer font:font];
    SCELineLayout *layout = [cache layoutForLineAtIndex:0];
    LARGE_CHECK(layout.fragmentCount > 200 && layout.line == NULL, "a long line must be laid out in fragments");
    LARGE_CHECK(layout.measuredFragmentCount == 1, "creating a long line layout must measure one fragment");
    CGFloat advance = [layout xForUTF16Index:1];
    LARGE_CHECK(fabs(layout.estimatedWidth - text.length * advance) < 1,
                "monospaced text must estimate its width from the measured advance");
    LARGE_CHECK([layout xForUTF16Index:text.length clampedToMaximumX:500] == 500 && layout.measuredFragmentCount <= 2,
                "a clamped offset query must not measure past its maximum");
    NSArray<NSValue *> *rects = [layout selectionRectsForUTF16Range:NSMakeRange(0, text.length)
                                                             height:16
                                                           minimumX:0
                                                           maximumX:800];
    LARGE_CHECK(rects.count == 1 && NSMinX(rects[0].rectValue) <= 0 && NSMaxX(rects[0].rectValue) >= 800 &&
                    layout.measuredFragmentCount <= 2,
                "a clipped selection must cover the interval and measure only nearby fragments");
    NSUInteger fragmentStart = 0;
    CTLineRef fragment = [layout lineOfFragmentContainingUTF16Index:150000 fragmentStart:&fragmentStart];
    LARGE_CHECK(fragmentStart > 140000 && fragmentStart <= 150000 && [text characterAtIndex:fragmentStart - 1] == ' ',
                "fragments must start after a space when one is near");
    LARGE_CHECK(CTLineGetStringRange(fragment).length <= (CFIndex)(SCELineLayoutFragmentLength + 64),
                "a fragment CTLine must hold one fragment of text");
    for (NSUInteger iteration = 0; iteration < 400; iteration++) {
        NSUInteger index = iteration < 40 ? fragmentStart - 20 + iteration : SCELargeDocumentRandom(text.length + 1);
        CGFloat x = [layout xForUTF16Index:index];
        LARGE_CHECK(fabs(x - index * advance) < 1e-3, "fragment positions must accumulate exact widths");
        LARGE_CHECK([layout UTF16IndexForX:x + advance * 0.3] == index &&
                        (index == text.length || [layout UTF16IndexForX:x + advance * 0.7] == index + 1),
                    "hit testing must find the nearest caret position in any fragment");
    }
    LARGE_CHECK(fabs(layout.width - text.length * advance) < 1e-3 &&
                    layout.measuredFragmentCount == layout.fragmentCount,
                "the exact width must measure every fragment");

    // Tabs advance to stops measured from the start of the line, wherever a
    // fragment begins.
    NSMutableString *tabbed = [NSMutableString string];
    while (tabbed.length < 40000) {
        [tabbed appendString:[@"" stringByPaddingToLength:1 + SCELargeDocumentRandom(9)
                                               withString:@"t"
                                          startingAtIndex:0]];
        [tabbed appendString:@"\t"];
    }
    buffer = [[SCETextBuffer alloc] initWithString:tabbed];
    cache = [[SCELineLayoutCache alloc] initWithBuffer:buffer font:font];
    layout = [cache layoutForLineAtIndex:0];
    CGFloat interval = advance * cache.tabWidth;
    CGFloat previous = 0;
    for (NSUInteger index = 0; index < tabbed.length; index++) {
        CGFloat x = [layout xForUTF16Index:index + 1];
        LARGE_CHECK(x > previous, "positions in a tabbed line must increase");
        if ([tabbed characterAtIndex:index] == '\t') {
            CGFloat stops = x / interval;
            LARGE_CHECK(fabs(stops - round(stops)) < 1e-6, "a tab must end at a line-relative tab stop");
        }
        previous = x;
    }

    // Without spaces, fragments start at grapheme cluster boundaries, and every
    // cluster boundary round-trips through hit testing.
    NSArray<NSString *> *clusters = @[ @"中", @"文", @"\U0001F642", @"é", @"\U0001F468‍\U0001F469" ];
    NSMutableString *mixed = [NSMutableString string];
    while (mixed.length < 30000) {
        [mixed appendString:clusters[SCELargeDocumentRandom(clusters.count)]];
    }
    buffer = [[SCETextBuffer alloc] initWithString:mixed];
    cache = [[SCELineLayoutCache alloc] initWithBuffer:buffer font:font];
    layout = [cache layoutForLineAtIndex:0];
    previous = -1;
    for (NSUInteger index = 0; index < mixed.length;) {
        NSUInteger start = 0;
        [layout lineOfFragmentContainingUTF16Index:index fragmentStart:&start];
        LARGE_CHECK([mixed rangeOfComposedCharacterSequenceAtIndex:start].location == start,
                    "fragments must start at grapheme cluster boundaries");
        CGFloat x = [layout xForUTF16Index:index];
        LARGE_CHECK(x > previous && [layout UTF16IndexForX:x] == index,
                    "cluster boundaries must round-trip across fragments");
        previous = x;
        index = NSMaxRange([mixed rangeOfComposedCharacterSequenceAtIndex:index]);
    }

    // Syntax colors reach distant fragments, and later tokens take precedence
    // even when they are not in document order.
    buffer = [[SCETextBuffer alloc] initWithString:text];
    cache = [[SCELineLayoutCache alloc] initWithBuffer:buffer font:font];
    SCESyntaxTheme *theme = [[SCESyntaxTheme alloc] initWithForegroundColors:@{
        SCESyntaxTokenString : NSColor.redColor,
        SCESyntaxTokenNumber : NSColor.blueColor,
    }];
    cache.syntaxTheme = theme;
    [cache applySyntaxTokens:@[
        [[SCESyntaxToken alloc] initWithRange:NSMakeRange(200010, 4) kind:SCESyntaxTokenNumber],
        [[SCESyntaxToken alloc] initWithRange:NSMakeRange(199000, 3000) kind:SCESyntaxTokenString],
        [[SCESyntaxToken alloc] initWithRange:NSMakeRange(200012, 1) kind:SCESyntaxTokenNumber],
        [[SCESyntaxToken alloc] initWithRange:NSMakeRange(250000, 3) kind:SCESyntaxTokenNumber],
    ]
                 toLineRange:NSMakeRange(0, 1)];
    layout = [cache layoutForLineAtIndex:0];
    fragment = [layout lineOfFragmentContainingUTF16Index:200010 fragmentStart:&fragmentStart];
    LARGE_CHECK(SCERunHasColor(fragment, 200010 - fragmentStart, NSColor.redColor) &&
                    SCERunHasColor(fragment, 200012 - fragmentStart, NSColor.blueColor),
                "fragment colors must follow token order across long and short tokens");
    fragment = [layout lineOfFragmentContainingUTF16Index:250001 fragmentStart:&fragmentStart];
    LARGE_CHECK(SCERunHasColor(fragment, 250001 - fragmentStart, NSColor.blueColor),
                "distant fragments must receive their syntax colors");
    puts("PASS fragmented layout: bounded measurement, exact positions, hit testing, line-relative tabs, cluster "
         "boundaries, token precedence");
}

// Replaces text in a one-line cache document as the editor does.
static void SCEReplaceText(SCETextBuffer *buffer, SCELineLayoutCache *cache, NSMutableString *reference, NSRange range,
                           NSString *text) {
    SCETextBuffer *previous = [buffer copy];
    [buffer replaceCharactersInUTF16Range:range withString:text];
    [reference replaceCharactersInRange:range withString:text];
    [cache invalidateForReplacementOfUTF16Range:range replacementLength:text.length previousBuffer:previous];
}

static void SCECheckLongLineGeometryReuse(void) {
    NSFont *font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    NSMutableString *text = [NSMutableString string];
    while (text.length < 300000) {
        [text appendFormat:@"word%lu ", (unsigned long)SCELargeDocumentRandom(100000)];
    }
    SCETextBuffer *buffer = [[SCETextBuffer alloc] initWithString:text];
    SCELineLayoutCache *cache = [[SCELineLayoutCache alloc] initWithBuffer:buffer font:font];
    SCELineLayout *layout = [cache layoutForLineAtIndex:0];
    CGFloat advance = [layout xForUTF16Index:1];
    [layout width];
    BOOL (^positionsAreExact)(SCELineLayout *) = ^BOOL(SCELineLayout *candidate) {
        for (NSUInteger iteration = 0; iteration < 50; iteration++) {
            NSUInteger index = SCELargeDocumentRandom(text.length + 1);
            if (fabs([candidate xForUTF16Index:index] - index * advance) >= 1e-3) {
                return NO;
            }
        }
        return fabs(candidate.width - text.length * advance) < 1e-3;
    };

    // Fragments before an edit keep their measured geometry.
    SCEReplaceText(buffer, cache, text, NSMakeRange(295000, 3), @"inserted");
    SCELineLayout *edited = [cache layoutForLineAtIndex:0];
    LARGE_CHECK(edited != layout && edited.measuredFragmentCount >= 295000 / SCELineLayoutFragmentLength - 2,
                "an edit must keep the geometry of the fragments before it");
    LARGE_CHECK(positionsAreExact(edited), "reused geometry must place text exactly after an edit");

    // New colors keep every measured fragment.
    [cache applySyntaxTokens:@[ [[SCESyntaxToken alloc] initWithRange:NSMakeRange(1000, 4) kind:SCESyntaxTokenNumber] ]
                 toLineRange:NSMakeRange(0, 1)];
    SCELineLayout *recolored = [cache layoutForLineAtIndex:0];
    LARGE_CHECK(recolored != edited && recolored.measuredFragmentCount == recolored.fragmentCount,
                "recoloring must keep the measured geometry");

    // An edit near the start leaves nothing to reuse.
    SCEReplaceText(buffer, cache, text, NSMakeRange(10, 0), @"\t");
    edited = [cache layoutForLineAtIndex:0];
    LARGE_CHECK(edited.measuredFragmentCount == 1, "an edit in the first fragment must discard later geometry");
    SCEReplaceText(buffer, cache, text, NSMakeRange(10, 1), @"");
    [[cache layoutForLineAtIndex:0] width];

    // Consecutive edits without a layout in between keep the shorter prefix.
    SCEReplaceText(buffer, cache, text, NSMakeRange(200000, 0), @"abc");
    SCEReplaceText(buffer, cache, text, NSMakeRange(100000, 5), @"");
    edited = [cache layoutForLineAtIndex:0];
    LARGE_CHECK(edited.measuredFragmentCount > 1 &&
                    edited.measuredFragmentCount <= 100000 / SCELineLayoutFragmentLength,
                "a second edit must truncate the stored geometry");
    LARGE_CHECK(positionsAreExact(edited), "truncated geometry must place text exactly");
    puts("PASS long-line geometry reuse: edits keep earlier fragments, recoloring keeps all, prefixes truncate");
}

static NSUInteger SCECountInk(SCEEditorView *editor, BOOL text, size_t width, size_t height) {
    uint8_t *pixels = calloc(height, width * 4);
    CGColorSpaceRef colors = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmap = CGBitmapContextCreate(pixels, width, height, 8, width * 4, colors,
                                                kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colors);
    CGContextTranslateCTM(bitmap, 0, height);
    CGContextScaleCTM(bitmap, 1, -1);
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:bitmap flipped:YES];
    if (text) {
        [editor drawTextSurface:editor.subviews[1]];
    } else {
        [editor drawBackgroundSurface:editor.subviews[0]];
    }
    [NSGraphicsContext restoreGraphicsState];
    CGContextRelease(bitmap);
    NSUInteger ink = 0;
    for (size_t index = 0; index < width * height; index++) {
        ink += pixels[index * 4 + 3] != 0;
    }
    free(pixels);
    return ink;
}

static void SCECheckLongLineEditor(void) {
    NSMutableString *text = [NSMutableString stringWithString:@"first\n"];
    while (text.length < 2000000) {
        [text appendFormat:@"{\"id\":%lu,\"name\":\"item\"},", (unsigned long)text.length];
    }
    [text appendString:@"\nlast"];
    NSScrollView *scroll = [SCEEditorView scrollableEditorView];
    scroll.frame = NSMakeRect(0, 0, 800, 600);
    SCEEditorView *editor = (SCEEditorView *)scroll.documentView;
    editor.string = text;
    SCELineLayoutCache *cache = [editor valueForKey:@"layoutCache"];
    SCELineLayout *layout = [cache layoutForLineAtIndex:1];
    LARGE_CHECK(layout.fragmentCount > 1000 && layout.measuredFragmentCount <= 2,
                "showing a long line must measure only the visible fragments");
    LARGE_CHECK(NSWidth(editor.frame) > layout.estimatedWidth * 0.9,
                "the document width must include the estimated width of a long line");
    LARGE_CHECK(SCECountInk(editor, YES, 800, 600) > 0 && layout.measuredFragmentCount <= 2,
                "drawing a long line must lay out only the visible fragments");
    [editor selectAll:nil];
    LARGE_CHECK(SCECountInk(editor, NO, 800, 600) > 0 && layout.measuredFragmentCount <= 2,
                "painting a selection must measure only the visible fragments");

    // Moving to the end of the long line measures it exactly and scrolls there.
    editor.selectedRange = NSMakeRange(6, 0);
    [editor doCommandBySelector:@selector(moveToEndOfLine:)];
    CGFloat exactWidth = layout.width;
    LARGE_CHECK(NSWidth(editor.frame) >= exactWidth, "the document must widen to the exact end of the line");
    NSRect visible = scroll.contentView.bounds;
    LARGE_CHECK(NSMaxX(visible) > exactWidth * 0.99, "moving to the end of the line must scroll horizontally");
    LARGE_CHECK(SCECountInk(editor, YES, 800, 600) > 0, "the end of a long line must draw");

    // Navigation reads a window around the caret. A word longer than the window
    // still moves as one word, and clusters deep in the line stay intact.
    NSString *word = [@"" stringByPaddingToLength:5000 withString:@"w" startingAtIndex:0];
    NSString *family = @"\U0001F468‍\U0001F469‍\U0001F467";
    NSString *padding = [@"" stringByPaddingToLength:100000 withString:@"p " startingAtIndex:0];
    editor.string = [NSString stringWithFormat:@"%@%@ %@%@", padding, word, family, padding];
    editor.selectedRange = NSMakeRange(padding.length, 0);
    [editor doCommandBySelector:@selector(moveWordRight:)];
    LARGE_CHECK(editor.selectedRange.location == padding.length + word.length,
                "a word longer than the navigation window must move as one word");
    editor.selectedRange = NSMakeRange(padding.length + word.length + 1, 0);
    [editor doCommandBySelector:@selector(moveRight:)];
    LARGE_CHECK(editor.selectedRange.location == padding.length + word.length + 1 + family.length,
                "moving across a joined emoji sequence in a long line must skip the whole cluster");
    [editor doCommandBySelector:@selector(moveLeft:)];
    LARGE_CHECK(editor.selectedRange.location == padding.length + word.length + 1,
                "moving back across a joined emoji sequence must return to its start");

    // Return reads only the indentation and the whitespace around the caret. Each
    // run below is longer than one read chunk, on a line far longer than both.
    editor.languageConfiguration = SCELanguageConfiguration.languageConfigurationForJSON;
    editor.bracketCompletionMode = SCEBracketCompletionModeOnNewline;
    NSString *tabs = [@"" stringByPaddingToLength:130 withString:@"\t" startingAtIndex:0];
    NSString *spaces = [@"" stringByPaddingToLength:300 withString:@" " startingAtIndex:0];
    NSString *indented = [NSString stringWithFormat:@"%@%@value %@", tabs, spaces, padding];
    editor.string = indented;
    editor.selectedRange = NSMakeRange(indented.length, 0);
    [editor doCommandBySelector:@selector(insertNewline:)];
    NSString *expectedIndentation = [@"" stringByPaddingToLength:130 * editor.tabWidth + 300
                                                      withString:@" "
                                                 startingAtIndex:0];
    NSString *expectedText = [NSString stringWithFormat:@"%@\n%@", indented, expectedIndentation];
    LARGE_CHECK([editor.string isEqualToString:expectedText],
                "Return must carry indentation longer than one read chunk");
    NSString *opened = [padding stringByAppendingFormat:@"{%@", spaces];
    editor.string = opened;
    editor.selectedRange = NSMakeRange(opened.length, 0);
    [editor doCommandBySelector:@selector(insertNewline:)];
    LARGE_CHECK([editor.string isEqualToString:[opened stringByAppendingString:@"\n    \n}"]] &&
                    editor.selectedRange.location == opened.length + 5,
                "Return must find an opener before whitespace longer than one read chunk");
    NSString *enclosed = [padding stringByAppendingFormat:@"{%@}", spaces];
    editor.string = enclosed;
    editor.selectedRange = NSMakeRange(padding.length + 1, 0);
    [editor doCommandBySelector:@selector(insertNewline:)];
    LARGE_CHECK([editor.string isEqualToString:[padding stringByAppendingString:@"{\n    \n}"]],
                "Return must find a closer after whitespace longer than one read chunk");
    puts("PASS long-line editor: viewport-bounded layout, drawing, selection, estimated and exact widths, scrolling, "
         "bounded navigation and Return reads");
}

NSUInteger SCECheckLargeDocuments(void) {
    SCECheckFileBackedBuffers();
    SCECheckFragmentedLayouts();
    SCECheckLongLineGeometryReuse();
    SCECheckLongLineEditor();
    return SCELargeDocumentCheckCount;
}

static double SCECurrentMilliseconds(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6;
}

static double SCEFootprintMegabytes(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
    return info.phys_footprint / 1048576.0;
}

void SCEBenchmarkLargeDocuments(void) {
    NSMutableData *data = [NSMutableData dataWithCapacity:64 << 20];
    const char *line = "    let value = compute(input) // \xE4\xB8\xAD\xE6\x96\x87 native text\n";
    while (data.length < (64 << 20)) {
        [data appendBytes:line length:strlen(line)];
    }
    NSURL *url = SCEWriteTemporaryFile(data);
    data = nil;
    double footprint = SCEFootprintMegabytes();
    double start = SCECurrentMilliseconds();
    SCETextBuffer *mapped = [[SCETextBuffer alloc] initWithContentsOfURL:url error:NULL];
    double mappedMS = SCECurrentMilliseconds() - start;
    double mappedMB = SCEFootprintMegabytes() - footprint;
    footprint = SCEFootprintMegabytes();
    start = SCECurrentMilliseconds();
    SCETextBuffer *decoded;
    @autoreleasepool {
        decoded = [[SCETextBuffer alloc] initWithString:[NSString stringWithContentsOfURL:url
                                                                                 encoding:NSUTF8StringEncoding
                                                                                    error:NULL]];
    }
    double decodedMS = SCECurrentMilliseconds() - start;
    double decodedMB = SCEFootprintMegabytes() - footprint;
    LARGE_CHECK(mapped.lengthUTF16 == decoded.lengthUTF16 && mapped.lineCount == decoded.lineCount,
                "benchmark buffers must agree");
    [[NSFileManager defaultManager] removeItemAtURL:url error:NULL];
    printf("FILE BENCH (debug build): 64 MiB UTF-8, %lu lines: mapped %.0f ms / +%.0f MB, decoded %.0f ms / +%.0f MB\n",
           (unsigned long)mapped.lineCount, mappedMS, mappedMB, decodedMS, decodedMB);

    NSMutableString *text = [NSMutableString string];
    while (text.length < 8000000) {
        [text appendFormat:@"{\"id\":%lu,\"name\":\"item\"},", (unsigned long)text.length];
    }
    SCETextBuffer *buffer = [[SCETextBuffer alloc] initWithString:text];
    SCELineLayoutCache *cache =
        [[SCELineLayoutCache alloc] initWithBuffer:buffer
                                              font:[NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular]];
    start = SCECurrentMilliseconds();
    SCELineLayout *layout = [cache layoutForLineAtIndex:0];
    double createMS = SCECurrentMilliseconds() - start;
    start = SCECurrentMilliseconds();
    for (NSUInteger iteration = 0; iteration < 100; iteration++) {
        [layout xForUTF16Index:iteration * 7];
        [layout UTF16IndexForX:iteration * 13];
    }
    double queryMS = (SCECurrentMilliseconds() - start) / 200;
    start = SCECurrentMilliseconds();
    CGFloat width = layout.width;
    double measureMS = SCECurrentMilliseconds() - start;
    start = SCECurrentMilliseconds();
    [layout xForUTF16Index:text.length - 100];
    double farQueryMS = SCECurrentMilliseconds() - start;
    printf("LONG LINE BENCH (debug build): %.1f Mi units, width %.0f pt: create %.2f ms, near query %.3f ms, "
           "measure all %.0f ms, far query after measuring %.3f ms\n",
           text.length / 1048576.0, width, createMS, queryMS, measureMS, farQueryMS);
}
