@import SourceEditor;
#import "../../Sources/SourceEditor/SCEViewport.h"
#import "../../Sources/SourceEditor/SCELineLayoutCache.h"
#import "../../Sources/SourceEditor/SCESelectionPath.h"
#import "../../Sources/SourceEditor/SCEBracketScope.h"
#import <time.h>
#import "SCESyntaxChecks.h"
#import "SCEInteractionChecks.h"
#import "SCEEditingChecks.h"

@interface SCEEditorView (SelectionRenderingChecks)
- (void)drawBackgroundSurface:(NSView *)surface;
@end

static NSUInteger SCECheckCount;
#define CHECK(condition, message)                                                                                      \
    do {                                                                                                               \
        SCECheckCount++;                                                                                               \
        if (!(condition)) {                                                                                            \
            fprintf(stderr, "FAIL at line %d: %s\n", __LINE__, (message));                                             \
            exit(1);                                                                                                   \
        }                                                                                                              \
    } while (0)

static uint64_t SCERandomState = 0x684931ba;

static NSUInteger SCERandom(NSUInteger upper) {
    SCERandomState ^= SCERandomState << 13;
    SCERandomState ^= SCERandomState >> 7;
    SCERandomState ^= SCERandomState << 17;
    return upper ? (NSUInteger)(SCERandomState % upper) : 0;
}

static NSArray<NSValue *> *SCEReferenceLines(NSString *text) {
    NSMutableArray *ranges = [NSMutableArray array];
    NSUInteger start = 0;
    for (NSUInteger i = 0; i < text.length; i++) {
        if ([text characterAtIndex:i] == '\n') {
            [ranges addObject:[NSValue valueWithRange:NSMakeRange(start, i + 1 - start)]];
            start = i + 1;
        }
    }
    [ranges addObject:[NSValue valueWithRange:NSMakeRange(start, text.length - start)]];
    return ranges;
}

static void SCECheckBuffer(SCETextBuffer *buffer, NSString *reference) {
    CHECK([buffer.string isEqualToString:reference], "rope text differs from NSString");
    CHECK(buffer.lengthUTF16 == reference.length, "UTF-16 length differs");
    NSArray<NSValue *> *lines = SCEReferenceLines(reference);
    CHECK(buffer.lineCount == lines.count, "line count differs");
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSRange expected = lines[i].rangeValue;
        CHECK(NSEqualRanges([buffer UTF16RangeOfLine:i includingLineEnding:YES], expected), "line range differs");
        NSRange content = expected;
        if (content.length && [reference characterAtIndex:NSMaxRange(content) - 1] == '\n') {
            content.length--;
            if (content.length && [reference characterAtIndex:NSMaxRange(content) - 1] == '\r') {
                content.length--;
            }
        }
        CHECK(NSEqualRanges([buffer UTF16RangeOfLine:i includingLineEnding:NO], content), "content range differs");
    }
    for (NSUInteger i = 0; i < 20; i++) {
        NSUInteger offset = SCERandom(reference.length + 1);
        NSUInteger line = 0;
        for (NSUInteger j = 0; j < offset; j++) {
            if ([reference characterAtIndex:j] == '\n') {
                line++;
            }
        }
        CHECK([buffer lineIndexForUTF16Offset:offset] == line, "offset-to-line mapping differs");
        NSUInteger end = offset + SCERandom(reference.length - offset + 1);
        NSRange range = NSMakeRange(offset, end - offset);
        CHECK([[buffer substringWithUTF16Range:range] isEqualToString:[reference substringWithRange:range]],
              "range read differs");
    }
}

static void SCECheckRope(void) {
    // CJK characters, combining marks, and joined emoji retain their original UTF-16 lengths.
    NSMutableString *reference = [NSMutableString string];
    for (NSUInteger i = 0; i < 1200; i++) {
        [reference appendString:@"line\t\u4e2d\u6587\U0001f468\u200d\U0001f469\u200d\U0001f467\u200d\U0001f466\r\n"];
    }
    SCETextBuffer *buffer = [[SCETextBuffer alloc] initWithString:reference];
    SCECheckBuffer(buffer, reference);
    NSArray *insertions = @[
        @"", @"a", @"\n", @"\r\n", @"\u4e2d\u6587", @"e\u0301",
        @"\U0001f468\u200d\U0001f469\u200d\U0001f467\u200d\U0001f466", @"one\ntwo\n", @"\t"
    ];
    for (NSUInteger i = 0; i < 12000; i++) {
        @autoreleasepool {
            NSUInteger start = SCERandom(reference.length + 1);
            NSUInteger count = SCERandom(MIN(80, reference.length - start) + 1);
            NSString *text = insertions[SCERandom(insertions.count)];
            NSRange range = NSMakeRange(start, count);
            SCETextBuffer *snapshot = [buffer copy];
            NSString *before = i % 100 == 0 ? [reference copy] : nil;
            [buffer replaceCharactersInUTF16Range:range withString:text];
            [reference replaceCharactersInRange:range withString:text];
            if (before) {
                CHECK([snapshot.string isEqualToString:before], "editing changed an older snapshot");
                SCECheckBuffer(buffer, reference);
            }
        }
    }
    // Exercise many tree rotations without allowing the reference to shrink.
    for (NSUInteger i = 0; i < 3000; i++) {
        NSString *text = @"abcdefghijklmnopqrstuvwxyz\n";
        NSUInteger start = SCERandom(reference.length + 1);
        [buffer replaceCharactersInUTF16Range:NSMakeRange(start, 0) withString:text];
        [reference insertString:text atIndex:start];
    }
    SCECheckBuffer(buffer, reference);
    [buffer replaceCharactersInUTF16Range:NSMakeRange(0, buffer.lengthUTF16) withString:@""];
    SCECheckBuffer(buffer, @"");
    BOOL raised = NO;
    @try {
        [buffer substringWithUTF16Range:NSMakeRange(NSUIntegerMax, 2)];
    } @catch (NSException *exception) {
        raised = [exception.name isEqual:NSRangeException];
    }
    CHECK(raised, "invalid ranges must be rejected without overflow");
    puts("PASS rope: randomized edits, line index, snapshots, empty and invalid ranges");
}

static void SCECommand(SCEEditorView *editor, SEL selector) {
    [editor doCommandBySelector:selector];
}

static void SCECheckEditing(void) {
    SCEEditorView *editor = [[SCEEditorView alloc] initWithFrame:NSMakeRect(0, 0, 600, 400)];
    editor.string = @"A\U0001f468\u200d\U0001f469\u200d\U0001f467\u200d\U0001f466e\u0301Z";
    editor.selectedRange = NSMakeRange(editor.string.length - 1, 0);
    SCECommand(editor, @selector(deleteBackward:));
    CHECK([editor.string isEqualToString:@"A\U0001f468\u200d\U0001f469\u200d\U0001f467\u200d\U0001f466Z"],
          "backspace must remove a combining cluster");
    SCECommand(editor, @selector(deleteBackward:));
    CHECK([editor.string isEqualToString:@"AZ"], "backspace must remove an entire emoji ZWJ sequence");
    [editor undo:nil];
    CHECK([editor.string isEqualToString:@"A\U0001f468\u200d\U0001f469\u200d\U0001f467\u200d\U0001f466Z"],
          "undo must restore emoji");
    [editor redo:nil];
    CHECK([editor.string isEqualToString:@"AZ"], "redo must replay deletion");
    editor.string = @"a\r\nb";
    editor.selectedRange = NSMakeRange(3, 0);
    SCECommand(editor, @selector(deleteBackward:));
    CHECK([editor.string isEqualToString:@"ab"], "CRLF must delete as one cluster");
    editor.string = @"abcdef\nx\nabcdef";
    editor.selectedRange = NSMakeRange(5, 0);
    SCECommand(editor, @selector(moveDown:));
    CHECK(editor.selectedRange.location == 8, "vertical move must clamp on a short line");
    SCECommand(editor, @selector(moveDown:));
    CHECK(editor.selectedRange.location == 14, "vertical move must preserve preferred x");
    SCECommand(editor, @selector(moveLeftAndModifySelection:));
    CHECK(NSEqualRanges(editor.selectedRange, NSMakeRange(13, 1)), "shift-left selection differs");
    SCECommand(editor, @selector(moveRightAndModifySelection:));
    CHECK(NSEqualRanges(editor.selectedRange, NSMakeRange(14, 0)), "shift selection must contract");
    editor.string = @"    if (ready) {\r\n}";
    editor.selectedRange = NSMakeRange(16, 0);
    SCECommand(editor, @selector(insertNewline:));
    CHECK([editor.string hasPrefix:@"    if (ready) {\r\n    "], "newline must preserve CRLF and indentation");
    editor.editable = NO;
    NSString *before = editor.string;
    [editor insertText:@"blocked" replacementRange:NSMakeRange(NSNotFound, 0)];
    SCECommand(editor, @selector(deleteBackward:));
    CHECK([editor.string isEqualToString:before], "read-only mode must reject edits");
    editor.selectedRange = NSMakeRange(0, 0);
    SCECommand(editor, @selector(moveRight:));
    CHECK(NSEqualRanges(editor.selectedRange, NSMakeRange(1, 0)), "read-only mode must move the caret");
    SCECommand(editor, @selector(moveWordRightAndModifySelection:));
    CHECK(editor.selectedRange.location == 1 && editor.selectedRange.length > 0,
          "read-only mode must extend the selection");
    // Leave the general pasteboard untouched; a read-only cut returns before copying.
    [editor paste:nil];
    [editor cut:nil];
    CHECK([editor.string isEqualToString:before], "read-only mode must reject paste and cut");
    puts("PASS editing: graphemes, CRLF, undo/redo, navigation, indentation, read-only mode");
}

static void SCECheckComposition(void) {
    // Escaped Chinese and Japanese text exercises input-method composition and undo.
    SCEEditorView *editor = [[SCEEditorView alloc] initWithFrame:NSMakeRect(0, 0, 600, 400)];
    editor.string = @"left right";
    editor.selectedRange = NSMakeRange(5, 5);
    [editor setMarkedText:@"n" selectedRange:NSMakeRange(1, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
    [editor setMarkedText:@"ni" selectedRange:NSMakeRange(2, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK([editor.string isEqualToString:@"left ni"], "preedit must replace the preceding preedit");
    CHECK(NSEqualRanges(editor.markedRange, NSMakeRange(5, 2)), "marked range differs");
    CHECK(!editor.undoManager.canUndo, "intermediate preedits must not add undo steps");
    [editor insertText:@"\u4f60" replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK([editor.string isEqualToString:@"left \u4f60"] && !editor.hasMarkedText, "committed text differs");
    [editor undo:nil];
    CHECK([editor.string isEqualToString:@"left right"], "one undo must restore the original selected text");
    CHECK(NSEqualRanges(editor.selectedRange, NSMakeRange(5, 5)), "composition undo must restore selection");
    CHECK(!editor.undoManager.canUndo, "a composition must create exactly one undo step");
    [editor redo:nil];
    CHECK([editor.string isEqualToString:@"left \u4f60"], "composition redo differs");
    editor.string = @"original";
    editor.selectedRange = NSMakeRange(0, 8);
    [editor setMarkedText:@"\u62fc\u97f3" selectedRange:NSMakeRange(2, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
    SCECommand(editor, @selector(cancelOperation:));
    CHECK([editor.string isEqualToString:@"original"] && !editor.hasMarkedText, "cancel must restore replaced content");
    CHECK(!editor.undoManager.canUndo, "cancelled composition must not add an undo step");
    editor.selectedRange = NSMakeRange(0, 0);
    [editor setMarkedText:@"\u65e5\u672c\u8a9e"
            selectedRange:NSMakeRange(3, 0)
         replacementRange:NSMakeRange(NSNotFound, 0)];
    [editor unmarkText];
    [editor undo:nil];
    CHECK([editor.string isEqualToString:@"original"], "unmark must commit one undoable composition");
    NSRange actual;
    NSAttributedString *substring = [editor attributedSubstringForProposedRange:NSMakeRange(0, NSUIntegerMax)
                                                                    actualRange:&actual];
    CHECK([substring.string isEqualToString:@"original"] && actual.length == 8,
          "input-context range must clamp without overflow");
    puts("PASS input protocol: preedit, replacement, commit, cancel, single-step undo, range queries");
}

static void SCECheckSelectionPainting(void) {
    SCEEditorView *editor = [[SCEEditorView alloc] initWithFrame:NSMakeRect(0, 0, 400, 200)];
    editor.showsLineNumbers = NO;
    editor.font = [NSFont monospacedSystemFontOfSize:13.3 weight:NSFontWeightRegular];
    editor.string = @"- (void)loadView {\t// \u4e2d\u6587\U0001f642\n    \n}\n";
    [editor selectAll:nil];
    CGFloat lineHeight = [[editor valueForKey:@"lineHeight"] doubleValue];
    const CGFloat phases[] = {
        0.25,
        0.75,
    };
    for (NSUInteger scale = 1; scale <= 2; scale++) {
        for (NSUInteger phaseIndex = 0; phaseIndex < 2; phaseIndex++) {
            CGFloat phase = phases[phaseIndex];
            [editor setValue:[NSValue valueWithRect:NSMakeRect(phase, phase, 400, 200)] forKey:@"viewportRect"];
            size_t width = 400 * scale;
            size_t height = 200 * scale;
            size_t stride = width * 4;
            uint8_t *pixels = calloc(height, stride);
            CGColorSpaceRef colors = CGColorSpaceCreateDeviceRGB();
            CGContextRef bitmap = CGBitmapContextCreate(pixels, width, height, 8, stride, colors,
                                                        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
            CGColorSpaceRelease(colors);
            CGContextScaleCTM(bitmap, scale, scale);
            CGContextSetShouldAntialias(bitmap, YES);
            [NSGraphicsContext saveGraphicsState];
            NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:bitmap flipped:NO];
            [editor drawBackgroundSurface:editor.subviews.firstObject];
            [NSGraphicsContext restoreGraphicsState];
            // The first three complete selected lines form one solid region.
            // Include internal run, text/newline and row boundaries in the scan.
            // Exclude the intentionally rounded exterior, but still scan every
            // internal run/newline boundary and both horizontal row junctions.
            size_t left = (size_t)ceil((12 - phase + 8) * scale);
            size_t right = (size_t)floor((400 - 8) * scale);
            size_t bottom = (size_t)ceil((12 - phase + 8) * scale);
            size_t top = (size_t)floor((12 + 3 * lineHeight - phase - 8) * scale);
            const uint8_t *expected = pixels + (bottom + 2) * stride + left * 4;
            BOOL solid = YES;
            for (size_t y = bottom; y < top && solid; y++) {
                for (size_t x = left; x < right; x++) {
                    const uint8_t *pixel = pixels + y * stride + x * 4;
                    if (memcmp(pixel, expected, 4) != 0) {
                        fprintf(stderr,
                                "Selection seam at scale %lu phase %.2f pixel (%zu, %zu): %u/%u/%u/%u vs %u/%u/%u/%u\n",
                                (unsigned long)scale, phase, x, y, pixel[0], pixel[1], pixel[2], pixel[3], expected[0],
                                expected[1], expected[2], expected[3]);
                        solid = NO;
                        break;
                    }
                }
            }
            CGContextRelease(bitmap);
            free(pixels);
            CHECK(solid, "multiline selection must have no seams at run, newline or row boundaries");
        }
    }
    SCETextBuffer *buffer = [[SCETextBuffer alloc] initWithString:@"a\u4e2d\U0001f642\tend"];
    SCELineLayoutCache *cache = [[SCELineLayoutCache alloc] initWithBuffer:buffer font:editor.font];
    SCELineLayout *line = [cache layoutForLineAtIndex:0];
    CHECK([line selectionRectsForUTF16Range:NSMakeRange(0, buffer.lengthUTF16) height:22].count == 1,
          "adjacent font fallback and tab runs must merge into one visual span");
    buffer = [[SCETextBuffer alloc] initWithString:@"abc \u05d0\u05d1\u05d2 def"];
    cache = [[SCELineLayoutCache alloc] initWithBuffer:buffer font:editor.font];
    NSArray<NSValue *> *spans = [[cache layoutForLineAtIndex:0] selectionRectsForUTF16Range:NSMakeRange(0, 5)
                                                                                     height:22];
    CHECK(spans.count == 2 && NSMaxX(spans[0].rectValue) < NSMinX(spans[1].rectValue),
          "merging selection spans must preserve unselected bidirectional text gaps");
    puts("PASS selection: seamless whole-path fill at 1x/2x fractional offsets, merged runs, disjoint bidi spans");
}

// Independent reference: match each bracket kind over the whole window with a
// stack, then take the multiline pair enclosing the range whose opener is nearest.
static NSRange SCEReferenceBracketScope(NSString *text, NSRange range, NSUInteger limit) {
    NSUInteger offset = range.location;
    NSUInteger end = NSMaxRange(range);
    NSUInteger lower = offset > limit ? offset - limit : 0;
    NSUInteger upper = MIN(text.length, end + limit);
    NSString *opens = @"([{";
    NSString *closes = @")]}";
    NSMutableArray<NSMutableArray<NSNumber *> *> *stacks =
        [NSMutableArray arrayWithObjects:[NSMutableArray array], [NSMutableArray array], [NSMutableArray array], nil];
    NSRange best = NSMakeRange(NSNotFound, 0);
    for (NSUInteger i = lower; i < upper; i++) {
        unichar ch = [text characterAtIndex:i];
        NSUInteger kind = [opens rangeOfString:[NSString stringWithCharacters:&ch length:1]].location;
        if (kind != NSNotFound) {
            [stacks[kind] addObject:@(i)];
            continue;
        }
        kind = [closes rangeOfString:[NSString stringWithCharacters:&ch length:1]].location;
        if (kind == NSNotFound || !stacks[kind].count) {
            continue;
        }
        NSUInteger open = stacks[kind].lastObject.unsignedIntegerValue;
        [stacks[kind] removeLastObject];
        if (!(open < offset && i >= end)) {
            continue;
        }
        NSUInteger newlines = 0;
        for (NSUInteger j = open; j < i; j++) {
            newlines += [text characterAtIndex:j] == '\n';
        }
        if (newlines >= 2 && (best.location == NSNotFound || open > best.location)) {
            best = NSMakeRange(open, i + 1 - open);
        }
    }
    return best;
}

static void SCECheckScopeGuide(void) {
    NSString *swift = @"HStack(spacing: 0) {\n"
                       "    ForEach(tabs, id: \\.self) { tab in\n"
                       "        let isSelected = tab == selection\n"
                       "        Button {\n"
                       "            selection = tab\n"
                       "        } label: {\n"
                       "            Text(title(tab))\n"
                       "                .font(.system(size: 12))\n"
                       "        }\n"
                       "        .buttonStyle(.plain)\n"
                       "    }\n"
                       "}\n";
    SCETextBuffer *buffer = [[SCETextBuffer alloc] initWithString:swift];
    NSRange (^scope)(NSString *) = ^NSRange(NSString *marker) {
        NSRange found = [swift rangeOfString:marker];
        return SCEEnclosingMultilineBracketRange(buffer, found.location, SCEBracketScopeDefaultScanLimit);
    };
    NSUInteger forEachOpen = [swift rangeOfString:@"{ tab in"].location;
    NSUInteger forEachClose = [swift rangeOfString:@"    }\n}"].location + 4;
    NSRange forEach = NSMakeRange(forEachOpen, forEachClose + 1 - forEachOpen);
    CHECK(NSEqualRanges(scope(@"let isSelected"), forEach), "caret inside a block must find that block");
    CHECK(NSEqualRanges(scope(@"Selected ="), forEach), "caret mid-line must find the enclosing block");
    CHECK(NSEqualRanges(scope(@"plain)"), forEach), "a single-line () pair must not hide the block");
    NSUInteger buttonOpen = [swift rangeOfString:@"Button {"].location + 7;
    NSUInteger buttonClose = [swift rangeOfString:@"} label"].location;
    NSRange button = NSMakeRange(buttonOpen, buttonClose + 1 - buttonOpen);
    CHECK(NSEqualRanges(scope(@"selection = tab"), button), "a block with one inner line has a scope");
    CHECK(NSEqualRanges(scope(@"} label"), button), "caret before a closing brace belongs to that scope");
    CHECK(NSEqualRanges(scope(@"label: {"), forEach), "caret after a closing brace belongs to the outer scope");
    SCETextBuffer *adjacent = [[SCETextBuffer alloc] initWithString:@"{\n  a {\n  }\n}"];
    CHECK(SCEEnclosingMultilineBracketRange(adjacent, 8, SCEBracketScopeDefaultScanLimit).location == 0,
          "brackets on adjacent lines enclose no line, so the outer scope is used");
    NSUInteger labelOpen = [swift rangeOfString:@"label: {"].location + 7;
    NSRange label = SCEEnclosingMultilineBracketRange(buffer, labelOpen + 1, SCEBracketScopeDefaultScanLimit);
    CHECK(label.location == labelOpen && [swift characterAtIndex:NSMaxRange(label) - 1] == '}',
          "caret right after an opening brace belongs to that scope");
    CHECK(SCEEnclosingMultilineBracketRange(buffer, 0, SCEBracketScopeDefaultScanLimit).location == NSNotFound,
          "top level has no scope");
    CHECK(SCEEnclosingMultilineBracketRange(buffer, swift.length, SCEBracketScopeDefaultScanLimit).location ==
              NSNotFound,
          "end of document has no scope");
    CHECK(SCEEnclosingMultilineBracketRange(buffer, [swift rangeOfString:@"let"].location, 8).location == NSNotFound,
          "brackets beyond the scan limit must be ignored");
    SCETextBuffer *unclosed = [[SCETextBuffer alloc] initWithString:@"{\n  call(\n  x\n  y\n}"];
    CHECK(SCEEnclosingMultilineBracketRange(unclosed, 13, SCEBracketScopeDefaultScanLimit).location == 0,
          "an unclosed ( must not hide the enclosing { scope");

    // A selection shows only the innermost pair that encloses all of it.
    NSRange (^selectionScope)(NSString *, NSString *) = ^NSRange(NSString *first, NSString *last) {
        NSUInteger start = [swift rangeOfString:first].location;
        NSUInteger end = NSMaxRange([swift rangeOfString:last]);
        return SCEEnclosingMultilineBracketRangeForRange(buffer, NSMakeRange(start, end - start),
                                                         SCEBracketScopeDefaultScanLimit);
    };
    CHECK(NSEqualRanges(selectionScope(@"selection = tab", @"selection = tab"), button),
          "a selection within one line must use the scope of that line");
    CHECK(NSEqualRanges(selectionScope(@"let isSelected", @"selection = tab"), forEach),
          "a selection that leaves a nested block must use the pair enclosing both ends");
    CHECK(NSEqualRanges(selectionScope(@"selection = tab", @".font"), forEach),
          "a selection spanning sibling blocks must use their common enclosing pair");
    CHECK(NSEqualRanges(selectionScope(@"\n            selection", @"selection = tab\n"), button),
          "a selection of a block's interior must use that block");
    CHECK(NSEqualRanges(selectionScope(@"{\n            selection", @"tab\n        }"), forEach),
          "a selection that includes a block's brackets must use the enclosing pair");
    CHECK(
        SCEEnclosingMultilineBracketRangeForRange(buffer, NSMakeRange(0, swift.length), SCEBracketScopeDefaultScanLimit)
                .location == NSNotFound,
        "selecting the whole document has no enclosing scope");

    // Random bracket sequences cross text-reading chunk boundaries in both directions.
    NSString *alphabet = @"(){}[]\n\nab ";
    for (NSUInteger round = 0; round < 300; round++) {
        NSUInteger length = round < 20 ? 9000 + SCERandom(4000) : SCERandom(400);
        NSMutableString *text = [NSMutableString stringWithCapacity:length];
        for (NSUInteger i = 0; i < length; i++) {
            unichar ch = [alphabet characterAtIndex:SCERandom(alphabet.length)];
            [text appendString:[NSString stringWithCharacters:&ch length:1]];
        }
        SCETextBuffer *randomBuffer = [[SCETextBuffer alloc] initWithString:text];
        for (NSUInteger probe = 0; probe < 20; probe++) {
            NSUInteger offset = SCERandom(text.length + 1);
            NSUInteger length = probe % 2 == 0 ? 0 : SCERandom(MIN(text.length - offset, 600) + 1);
            NSRange range = NSMakeRange(offset, length);
            NSUInteger limit = probe % 4 == 0 ? 1 + SCERandom(6000) : SCEBracketScopeDefaultScanLimit;
            NSRange actual = length ? SCEEnclosingMultilineBracketRangeForRange(randomBuffer, range, limit)
                                    : SCEEnclosingMultilineBracketRange(randomBuffer, offset, limit);
            NSRange expected = SCEReferenceBracketScope(text, range, limit);
            if (!NSEqualRanges(actual, expected)) {
                fprintf(stderr, "text length %lu range %s limit %lu: got %s, expected %s\n", (unsigned long)text.length,
                        NSStringFromRange(range).UTF8String, (unsigned long)limit, NSStringFromRange(actual).UTF8String,
                        NSStringFromRange(expected).UTF8String);
            }
            CHECK(NSEqualRanges(actual, expected), "bracket scope must match the stack reference");
        }
    }

    SCEEditorView *editor = [[SCEEditorView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    editor.showsLineNumbers = NO;
    editor.string = swift;
    editor.selectedRange = NSMakeRange([swift rangeOfString:@"let"].location, 0);
    CHECK(NSEqualRanges(editor.scopeGuideBracketRange, forEach), "editor must expose the caret's scope");
    NSUInteger selectionStart = [swift rangeOfString:@"selection = tab"].location;
    editor.selectedRange = NSMakeRange(selectionStart, 15);
    CHECK(NSEqualRanges(editor.scopeGuideBracketRange, button), "editor must expose a one-line selection's scope");
    editor.selectedRange = NSMakeRange(selectionStart, NSMaxRange([swift rangeOfString:@".font"]) - selectionStart);
    CHECK(NSEqualRanges(editor.scopeGuideBracketRange, forEach),
          "extending the selection out of a block must move the guide to the enclosing pair");
    editor.selectedRange = NSMakeRange(0, 0);
    [editor insertText:@"\n" replacementRange:NSMakeRange(0, 0)];
    editor.selectedRange = NSMakeRange([swift rangeOfString:@"let"].location + 1, 0);
    CHECK(NSEqualRanges(editor.scopeGuideBracketRange, NSMakeRange(forEach.location + 1, forEach.length)),
          "scope must follow edits");

    // Only the guide differs between the two renderings, in one thin column
    // that spans exactly the lines inside the brackets.
    CGFloat lineHeight = [[editor valueForKey:@"lineHeight"] doubleValue];
    [editor setValue:[NSValue valueWithRect:NSMakeRect(0, 0, 400, 300)] forKey:@"viewportRect"];
    CGFloat indentX = [[editor valueForKey:@"scopeGuideX"] doubleValue];
    const size_t scale = 2;
    const size_t width = 400 * scale;
    const size_t height = 300 * scale;
    uint8_t *renders[2];
    for (NSUInteger pass = 0; pass < 2; pass++) {
        editor.showsScopeGuide = pass == 0;
        renders[pass] = calloc(height, width * 4);
        CGColorSpaceRef colors = CGColorSpaceCreateDeviceRGB();
        CGContextRef bitmap = CGBitmapContextCreate(renders[pass], width, height, 8, width * 4, colors,
                                                    kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGColorSpaceRelease(colors);
        CGContextScaleCTM(bitmap, scale, scale);
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:bitmap flipped:NO];
        [editor drawBackgroundSurface:editor.subviews.firstObject];
        [NSGraphicsContext restoreGraphicsState];
        CGContextRelease(bitmap);
    }
    CHECK(editor.scopeGuideBracketRange.location == NSNotFound, "a hidden guide must report no scope");
    // Each row's intensity is the summed channel difference between the renderings.
    size_t minX = SIZE_MAX, maxX = 0, firstRow = SIZE_MAX, lastRow = 0;
    NSUInteger *rowIntensity = calloc(height, sizeof(NSUInteger));
    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            const uint8_t *shown = renders[0] + (y * width + x) * 4;
            const uint8_t *hidden = renders[1] + (y * width + x) * 4;
            if (memcmp(shown, hidden, 4) != 0) {
                minX = MIN(minX, x);
                maxX = MAX(maxX, x);
                firstRow = MIN(firstRow, y);
                lastRow = MAX(lastRow, y);
                for (size_t channel = 0; channel < 3; channel++) {
                    rowIntensity[y] += (NSUInteger)abs((int)shown[channel] - (int)hidden[channel]);
                }
            }
        }
    }
    free(renders[0]);
    free(renders[1]);
    size_t expectedX = (size_t)round((12 + indentX) * scale);
    CHECK(indentX > 0 && minX == expectedX && maxX == expectedX + scale - 1,
          "guide must be one point wide at the opening line's indentation");
    // The guide fades in and out over its first and last few points, so its
    // faintest end rows may match the background exactly.
    size_t spanRows = (size_t)round(8 * lineHeight * scale);
    size_t rows = firstRow == SIZE_MAX ? 0 : lastRow + 1 - firstRow;
    CHECK(rows <= spanRows && rows + 2 * scale >= spanRows, "guide must span the lines inside the brackets");
    NSUInteger middle = rowIntensity[(firstRow + lastRow) / 2];
    CHECK(middle > 0 && rowIntensity[firstRow] * 3 < middle && rowIntensity[lastRow] * 3 < middle,
          "guide ends must fade instead of stopping abruptly");
    size_t fadeRows = (size_t)(6 * scale);
    // The current-line highlight behind part of the guide changes its contrast slightly.
    CHECK(rowIntensity[firstRow + fadeRows] * 10 >= middle * 9 && rowIntensity[lastRow - fadeRows] * 10 >= middle * 9,
          "guide must reach full strength within the fade length");
    free(rowIntensity);
    puts("PASS scope guide: innermost multiline bracket pair, stack-reference fuzzing, edits, guide pixels");
}

typedef struct {
    CGPoint points[4];
} SCEInspectedCubic;

typedef struct {
    CGPoint current;
    CGPoint start;
    NSUInteger contours;
    NSUInteger closes;
    NSUInteger cubicCount;
    SCEInspectedCubic cubics[128];
} SCEPathInspection;

static void SCEInspectPath(void *info, const CGPathElement *element) {
    SCEPathInspection *state = info;
    switch (element->type) {
        case kCGPathElementMoveToPoint:
            state->current = element->points[0];
            state->start = state->current;
            state->contours++;
            break;
        case kCGPathElementAddLineToPoint:
            state->current = element->points[0];
            break;
        case kCGPathElementAddQuadCurveToPoint:
            state->current = element->points[1];
            break;
        case kCGPathElementAddCurveToPoint:
            if (state->cubicCount < 128) {
                SCEInspectedCubic *curve = &state->cubics[state->cubicCount];
                curve->points[0] = state->current;
                memcpy(&curve->points[1], element->points, sizeof(CGPoint) * 3);
            }
            state->cubicCount++;
            state->current = element->points[2];
            break;
        case kCGPathElementCloseSubpath:
            state->current = state->start;
            state->closes++;
            break;
    }
}

static CGPoint SCEPointDifference(CGPoint a, CGPoint b) {
    return CGPointMake(a.x - b.x, a.y - b.y);
}

static CGPoint SCESecondDifference(CGPoint a, CGPoint b, CGPoint c) {
    return CGPointMake(a.x - 2 * b.x + c.x, a.y - 2 * b.y + c.y);
}

static CGFloat SCECross(CGPoint a, CGPoint b) {
    return a.x * b.y - a.y * b.x;
}

static BOOL SCEPointsNear(CGPoint a, CGPoint b) {
    return hypot(a.x - b.x, a.y - b.y) < 1e-8;
}

static void SCECheckSelectionContours(void) {
    NSArray<NSValue *> *steps = @[
        [NSValue valueWithRect:NSMakeRect(60, 10, 80, 20)],
        [NSValue valueWithRect:NSMakeRect(10, 30, 130, 20)],
        [NSValue valueWithRect:NSMakeRect(10, 50, 70, 20)],
    ];
    CGPathRef path = SCECreateSelectionPath(steps, 4);
    SCEPathInspection inspection = {
        0,
    };
    CGPathApply(path, &inspection, SCEInspectPath);
    CHECK(inspection.contours == 1 && inspection.closes == 1 && inspection.cubicCount == 16,
          "a stepped selection must have one closed contour with every convex and concave corner rounded");
    CHECK(!CGPathContainsPoint(path, NULL, CGPointMake(60.1, 10.1), NO), "outer corner must cut away its sharp tip");
    CHECK(CGPathContainsPoint(path, NULL, CGPointMake(59.9, 29.9), NO),
          "upper concave junction must round into its notch");
    CHECK(CGPathContainsPoint(path, NULL, CGPointMake(80.1, 50.1), NO),
          "lower concave junction must round into its notch");
    CHECK(CGPathContainsPoint(path, NULL, CGPointMake(100, 30), NO), "joined rows must remain solid");
    for (NSUInteger i = 0; i < inspection.cubicCount; i += 2) {
        CGPoint *a = inspection.cubics[i].points;
        CGPoint *b = inspection.cubics[i + 1].points;
        CHECK(fabs(SCECross(SCEPointDifference(a[1], a[0]), SCESecondDifference(a[2], a[1], a[0]))) < 1e-8,
              "corner curvature must start at zero on the incoming straight edge");
        CHECK(fabs(SCECross(SCEPointDifference(b[3], b[2]), SCESecondDifference(b[3], b[2], b[1]))) < 1e-8,
              "corner curvature must end at zero on the outgoing straight edge");
        CHECK(SCEPointsNear(SCEPointDifference(a[3], a[2]), SCEPointDifference(b[1], b[0])),
              "corner halves must have equal first derivatives");
        CHECK(SCEPointsNear(SCESecondDifference(a[3], a[2], a[1]), SCESecondDifference(b[2], b[1], b[0])),
              "corner halves must have equal second derivatives for continuous curvature");
    }
    CGPathRelease(path);
    NSArray<NSValue *> *ring = @[
        [NSValue valueWithRect:NSMakeRect(0, 0, 100, 10)],
        [NSValue valueWithRect:NSMakeRect(0, 90, 100, 10)],
        [NSValue valueWithRect:NSMakeRect(0, 10, 10, 80)],
        [NSValue valueWithRect:NSMakeRect(90, 10, 10, 80)],
    ];
    path = SCECreateSelectionPath(ring, 4);
    inspection = (SCEPathInspection){
        0,
    };
    CGPathApply(path, &inspection, SCEInspectPath);
    CHECK(inspection.contours == 2 && inspection.closes == 2,
          "selection holes need separately oriented closed contours");
    CHECK(!CGPathContainsPoint(path, NULL, CGPointMake(50, 50), NO) &&
              CGPathContainsPoint(path, NULL, CGPointMake(50, 5), NO),
          "rounding must preserve unselected holes");
    CGPathRelease(path);
    path = SCECreateSelectionPath(
        @[ [NSValue valueWithRect:NSMakeRect(0, 0, 20, 20)], [NSValue valueWithRect:NSMakeRect(20, 20, 20, 20)] ], 4);
    inspection = (SCEPathInspection){
        0,
    };
    CGPathApply(path, &inspection, SCEInspectPath);
    CHECK(inspection.contours == 2 && inspection.closes == 2,
          "diagonal point contacts must not weld disconnected selections");
    CGPathRelease(path);
    path = SCECreateSelectionPath(@[ [NSValue valueWithRect:NSMakeRect(0, 0, 1, 22)] ], 4);
    CHECK(CGRectEqualToRect(CGPathGetBoundingBox(path), CGRectMake(0, 0, 1, 22)) &&
              CGPathContainsPoint(path, NULL, CGPointMake(0.5, 11), NO),
          "narrow selections must clamp their corners without collapsing");
    CGPathRelease(path);
    // Compare unrounded contour topology to the rectangle union independently
    // of path tracing. Cover partial row overlaps, gaps and multiple components.
    for (NSUInteger trial = 0; trial < 80; trial++) {
        NSMutableArray<NSValue *> *rects = [NSMutableArray array];
        for (NSUInteger row = 0; row < 8; row++) {
            for (NSUInteger span = 0; span < 2; span++) {
                NSRect rect = NSMakeRect(SCERandom(80), row * 10, 1 + SCERandom(40), 10);
                [rects addObject:[NSValue valueWithRect:rect]];
            }
        }
        path = SCECreateSelectionPath(rects, 0);
        for (NSUInteger sample = 0; sample < 160; sample++) {
            CGPoint point = CGPointMake(SCERandom(120) + 0.37, SCERandom(80) + 0.37);
            BOOL inUnion = NO;
            for (NSValue *value in rects) {
                if (CGRectContainsPoint(value.rectValue, point)) {
                    inUnion = YES;
                    break;
                }
            }
            CHECK(CGPathContainsPoint(path, NULL, point, NO) == inUnion,
                  "traced selection contour differs from the source rectangle union");
        }
        CGPathRelease(path);
    }
    puts(
        "PASS selection contours: G2 corners, concave junctions, holes, point contacts, narrow spans, randomized union topology");
}

static void SCECheckLayoutAndViewport(void) {
    NSRange visible = [SCEViewport lineRangeForVisibleRect:CGRectMake(0, 1000000, 800, 600)
                                                 lineCount:1000000
                                                lineHeight:22
                                                  topInset:12
                                                  overscan:6];
    CHECK(visible.length < 50 && visible.location > 40000, "viewport must bound work by visible rows");
    SCETextBuffer *buffer = [[SCETextBuffer alloc] initWithString:@"abc\nkeep\nlast"];
    SCELineLayoutCache *cache =
        [[SCELineLayoutCache alloc] initWithBuffer:buffer
                                              font:[NSFont monospacedSystemFontOfSize:14 weight:NSFontWeightRegular]];
    SCELineLayout *keep = [cache layoutForLineAtIndex:1];
    SCETextBuffer *beforeLineInsertion = [buffer copy];
    [buffer replaceCharactersInUTF16Range:NSMakeRange(1, 0) withString:@"\n"];
    [cache invalidateForReplacementOfUTF16Range:NSMakeRange(1, 0)
                              replacementLength:1
                                 previousBuffer:beforeLineInsertion];
    CHECK([cache layoutForLineAtIndex:2] == keep, "unaffected line layout must survive line insertion");
    [cache retainLinesInRange:NSMakeRange(0, 1)];
    CHECK(cache.cachedLineCount == 0, "offscreen cache entries must be evicted");
    SCETextBuffer *unicode =
        [[SCETextBuffer alloc] initWithString:@"a\U0001f468\u200d\U0001f469\u200d\U0001f467\u200d\U0001f466e\u0301\tZ"];
    SCELineLayoutCache *unicodeCache = [[SCELineLayoutCache alloc] initWithBuffer:unicode font:cache.font];
    SCELineLayout *line = [unicodeCache layoutForLineAtIndex:0];
    NSString *text = unicode.string;
    NSUInteger offset = 0;
    while (offset < text.length) {
        CGFloat x = [line xForUTF16Index:offset];
        CHECK([line UTF16IndexForX:x] == offset, "Core Text coordinate round trip differs at a cluster boundary");
        offset = NSMaxRange([text rangeOfComposedCharacterSequenceAtIndex:offset]);
    }
    CGFloat beforeTab = [line xForUTF16Index:text.length - 2];
    CGFloat afterTab = [line xForUTF16Index:text.length - 1];
    CHECK(afterTab > beforeTab, "tab must advance to a tab stop");
    CHECK([line selectionRectsForUTF16Range:NSMakeRange(0, text.length) height:22].count > 0,
          "selection must produce visual rectangles");

    NSMutableString *large = [NSMutableString stringWithCapacity:3000000];
    for (NSUInteger i = 0; i < 100000; i++) {
        [large appendFormat:@"line %lu: native text rendering\n", (unsigned long)i];
    }
    NSScrollView *scroll = [SCEEditorView scrollableEditorView];
    scroll.frame = NSMakeRect(0, 0, 800, 600);
    SCEEditorView *editor = (SCEEditorView *)scroll.documentView;
    editor.string = large;
    SCELineLayoutCache *editorCache = [editor valueForKey:@"layoutCache"];
    CHECK(editorCache.cachedLineCount < 100, "large document must not lay out all lines");
    NSUInteger builds = editorCache.totalLayoutBuildCount;
    editor.selectedRange = NSMakeRange(2, 0);
    editor.selectedRange = NSMakeRange(3, 2);
    CHECK(editorCache.totalLayoutBuildCount == builds, "changing selection must not rebuild text layouts");
    [editor insertText:@"!" replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK(editorCache.totalLayoutBuildCount <= builds + 2, "local edit must invalidate only its affected line");
    [scroll.contentView scrollToPoint:NSMakePoint(0, 500000)];
    [scroll reflectScrolledClipView:scroll.contentView];
    CHECK(editorCache.cachedLineCount < 100, "scrolling must keep the line cache bounded");
    for (NSView *surface in editor.subviews) {
        CHECK(NSHeight(surface.frame) <= NSHeight(scroll.contentView.bounds) + 1,
              "layer surfaces must remain viewport-sized");
    }

    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 800, 600)
                                                   styleMask:NSWindowStyleMaskTitled
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.releasedWhenClosed = NO;
    window.contentView = scroll;
    editor.string = @"abc\u4e2d\u6587\nnext";
    NSRange actual;
    NSRect screen = [editor firstRectForCharacterRange:NSMakeRange(3, 0) actualRange:&actual];
    NSUInteger hit = [editor characterIndexForPoint:NSMakePoint(NSMinX(screen), NSMidY(screen))];
    CHECK(hit == 3 && actual.location == 3, "IME screen coordinate round trip differs");
    [window makeFirstResponder:editor];
    editor.string = @"";
    NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                      location:NSZeroPoint
                                 modifierFlags:0
                                     timestamp:0
                                  windowNumber:window.windowNumber
                                       context:nil
                                    characters:@"\u4e2d\U0001f642"
                   charactersIgnoringModifiers:@"\u4e2d\U0001f642"
                                     isARepeat:NO
                                       keyCode:0];
    [editor keyDown:event];
    CHECK([editor.string isEqualToString:@"\u4e2d\U0001f642"], "Unicode key events must reach native text insertion");
    editor.string = large;
    editor.selectedRange = NSMakeRange(large.length, 0);
    [editor selectAll:nil];
    [editor insertText:@"one\ntwo" replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK(NSMaxY(editor.subviews.firstObject.frame) <= NSHeight(editor.frame) + 1,
          "deleting the document tail must clamp the viewport");

    editor.string = @"if (ready) {\n    run()\n}";
    editor.selectedRange = NSMakeRange(17, 0);
    CHECK([window makeFirstResponder:editor] && window.firstResponder == editor, "the editor must accept focus");
    CHECK(editor.scopeGuideBracketRange.location != NSNotFound, "a focusable editor must show its scope guide");
    editor.focusable = NO;
    CHECK(window.firstResponder != editor, "becoming non-focusable must resign first responder");
    // NSWindow reports success after taking first responder itself, so check the responder instead.
    [window makeFirstResponder:editor];
    CHECK(![editor acceptsFirstResponder] && window.firstResponder != editor,
          "a non-focusable editor must refuse first responder");
    CHECK(editor.scopeGuideBracketRange.location == NSNotFound, "a non-focusable editor must hide its scope guide");
    NSRect wordRect = [window convertRectFromScreen:[editor firstRectForCharacterRange:NSMakeRange(18, 0)
                                                                           actualRange:NULL]];
    NSEvent *doubleClick = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                              location:NSMakePoint(NSMinX(wordRect) + 1, NSMidY(wordRect))
                                         modifierFlags:0
                                             timestamp:0
                                          windowNumber:window.windowNumber
                                               context:nil
                                           eventNumber:0
                                            clickCount:2
                                              pressure:1];
    [editor mouseDown:doubleClick];
    if (!NSEqualRanges(editor.selectedRange, NSMakeRange(17, 3))) {
        NSLog(@"Double-click selected %@", NSStringFromRange(editor.selectedRange));
    }
    CHECK(NSEqualRanges(editor.selectedRange, NSMakeRange(17, 3)) && window.firstResponder != editor,
          "a non-focusable editor must keep mouse selection without taking focus");
    editor.focusable = YES;
    CHECK([window makeFirstResponder:editor], "restoring focusability must accept focus again");
    [window close];
    puts("PASS layout: cache reuse, Unicode hit testing, tabs, viewport bounds, 100k lines, IME screen coordinates, "
         "non-focusable mode");
}

static NSArray<NSValue *> *SCESearch(NSString *text, NSString *pattern, SCETextSearchOptions options) {
    SCETextBuffer *buffer = [[SCETextBuffer alloc] initWithString:text];
    SCETextSearchQuery *query = [[SCETextSearchQuery alloc] initWithPattern:pattern options:options];
    return [query rangesOfMatchesInBuffer:buffer maximumCount:SCETextSearchDefaultMaximumMatchCount error:NULL];
}

static BOOL SCERangesEqual(NSArray<NSValue *> *ranges, NSArray<NSValue *> *expected) {
    return [ranges isEqualToArray:expected];
}

#define SCE_RANGE(location, length) [NSValue valueWithRange:NSMakeRange((location), (length))]

// Runs the main run loop until background search results are applied.
static BOOL SCEWaitForSearchResults(SCEEditorView *editor) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (editor.isSearchPending && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return !editor.isSearchPending;
}

static uint8_t *SCERenderBackground(SCEEditorView *editor, size_t width, size_t height) {
    uint8_t *pixels = calloc(height, width * 4);
    CGColorSpaceRef colors = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmap = CGBitmapContextCreate(pixels, width, height, 8, width * 4, colors,
                                                kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colors);
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:bitmap flipped:NO];
    [editor drawBackgroundSurface:editor.subviews.firstObject];
    [NSGraphicsContext restoreGraphicsState];
    CGContextRelease(bitmap);
    return pixels;
}

static void SCECheckSearchQueries(void) {
    NSString *text = @"Find find FIND\nfinder _find find_ refind";
    CHECK(SCERangesEqual(SCESearch(text, @"find", 0),
                         @[
                             SCE_RANGE(0, 4), SCE_RANGE(5, 4), SCE_RANGE(10, 4), SCE_RANGE(15, 4), SCE_RANGE(23, 4),
                             SCE_RANGE(28, 4), SCE_RANGE(36, 4)
                         ]),
          "literal search must ignore case by default");
    CHECK(SCERangesEqual(SCESearch(text, @"find", SCETextSearchOptionCaseSensitive),
                         @[ SCE_RANGE(5, 4), SCE_RANGE(15, 4), SCE_RANGE(23, 4), SCE_RANGE(28, 4), SCE_RANGE(36, 4) ]),
          "case-sensitive search must match letter case");
    CHECK(SCERangesEqual(SCESearch(text, @"find", SCETextSearchOptionWholeWord),
                         @[ SCE_RANGE(0, 4), SCE_RANGE(5, 4), SCE_RANGE(10, 4) ]),
          "whole-word search must treat letters and underscores as word characters");
    CHECK(SCERangesEqual(SCESearch(@"a.b axb", @"a.b", 0), @[ SCE_RANGE(0, 3) ]),
          "literal search must escape regular expression metacharacters");
    CHECK(SCERangesEqual(SCESearch(@"a.b axb", @"a.b", SCETextSearchOptionRegularExpression),
                         @[ SCE_RANGE(0, 3), SCE_RANGE(4, 3) ]),
          "regular expression search must interpret metacharacters");
    CHECK(SCERangesEqual(SCESearch(@"one\r\ntwo\nthree", @"^t\\w+$", SCETextSearchOptionRegularExpression),
                         @[ SCE_RANGE(5, 3), SCE_RANGE(9, 5) ]),
          "anchors must match at LF and CRLF line boundaries");
    CHECK(SCESearch(@"abc", @"^", SCETextSearchOptionRegularExpression).count == 0, "empty matches must be skipped");
    CHECK(SCESearch(@"abc", @"", 0).count == 0, "an empty pattern must produce no matches");
    // A combining acute accent after "e" continues the word, so whole-word
    // search must not match the base letter alone.
    CHECK(SCESearch(@"café cafe", @"cafe", SCETextSearchOptionWholeWord).count == 1,
          "whole-word search must treat combining marks as word characters");
    // A non-BMP emoji occupies two UTF-16 code units before the match.
    CHECK(SCERangesEqual(SCESearch(@"\U0001f642 value", @"value", 0), @[ SCE_RANGE(3, 5) ]),
          "match ranges must count UTF-16 code units");
    NSError *error = nil;
    SCETextSearchQuery *invalid = [[SCETextSearchQuery alloc] initWithPattern:@"(unclosed"
                                                                      options:SCETextSearchOptionRegularExpression];
    CHECK(![invalid rangesOfMatchesInBuffer:[[SCETextBuffer alloc] initWithString:@"text"]
                               maximumCount:10
                                      error:&error] &&
              error,
          "an invalid regular expression must return nil and an error");
    SCETextSearchQuery *letters = [[SCETextSearchQuery alloc] initWithPattern:@"a" options:0];
    CHECK([letters rangesOfMatchesInBuffer:[[SCETextBuffer alloc] initWithString:@"aaaaa"] maximumCount:3 error:NULL]
                  .count == 3,
          "match collection must stop at the maximum count");
    CHECK([letters isEqual:[[SCETextSearchQuery alloc] initWithPattern:@"a" options:0]] &&
              ![letters isEqual:[[SCETextSearchQuery alloc] initWithPattern:@"a"
                                                                    options:SCETextSearchOptionCaseSensitive]],
          "query equality must compare pattern and options");
    puts("PASS search queries: case, whole words, regular expressions, line anchors, UTF-16 ranges, errors, limits");
}

static void SCECheckEditorSearch(void) {
    SCEEditorView *editor = [[SCEEditorView alloc] initWithFrame:NSMakeRect(0, 0, 400, 200)];
    editor.showsLineNumbers = NO;
    editor.string = @"alpha beta\nbeta gamma\ndelta beta";
    editor.selectedRange = NSMakeRange(7, 0);
    __block NSUInteger notifications = 0;
    id observer = [NSNotificationCenter.defaultCenter addObserverForName:SCEEditorSearchResultsDidChangeNotification
                                                                  object:editor
                                                                   queue:nil
                                                              usingBlock:^(NSNotification *note) {
                                                                  notifications++;
                                                              }];
    editor.searchQuery = [[SCETextSearchQuery alloc] initWithPattern:@"beta" options:0];
    CHECK(editor.isSearchPending && editor.numberOfSearchMatches == 0, "a new query must start a pending search");
    CHECK(SCEWaitForSearchResults(editor), "background search must complete");
    CHECK(notifications == 1, "applying background results must post one notification");
    CHECK(SCERangesEqual(editor.searchMatchRanges, @[ SCE_RANGE(6, 4), SCE_RANGE(11, 4), SCE_RANGE(28, 4) ]),
          "editor matches differ from the query result");
    CHECK(editor.currentSearchMatchIndex == NSNotFound, "a caret must not be reported as a current match");
    CHECK([editor selectNextSearchMatch] && NSEqualRanges(editor.selectedRange, NSMakeRange(11, 4)),
          "next match must start after a caret inside a match");
    CHECK(editor.currentSearchMatchIndex == 1, "the selected match must be the current match");
    CHECK([editor selectNextSearchMatch] && NSEqualRanges(editor.selectedRange, NSMakeRange(28, 4)),
          "next match must follow the current match");
    CHECK([editor selectNextSearchMatch] && NSEqualRanges(editor.selectedRange, NSMakeRange(6, 4)),
          "next match must wrap to the first match");
    CHECK([editor selectPreviousSearchMatch] && NSEqualRanges(editor.selectedRange, NSMakeRange(28, 4)),
          "previous match must wrap to the last match");
    CHECK([editor selectPreviousSearchMatch] && NSEqualRanges(editor.selectedRange, NSMakeRange(11, 4)),
          "previous match must precede the current match");

    // Insert two characters at the start of line 1: earlier matches stay,
    // later matches move, and the intersecting match is removed.
    editor.selectedRange = NSMakeRange(12, 0);
    [editor insertText:@"XY" replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK(editor.isSearchPending, "an edit must mark search results as pending");
    CHECK(SCERangesEqual(editor.searchMatchRanges, @[ SCE_RANGE(6, 4), SCE_RANGE(30, 4) ]),
          "matches must move with the text until new results arrive");
    CHECK(SCEWaitForSearchResults(editor), "search after an edit must complete");
    CHECK(SCERangesEqual(editor.searchMatchRanges, @[ SCE_RANGE(6, 4), SCE_RANGE(30, 4) ]),
          "search after an edit must not match the split word");
    [editor insertText:@"beta " replacementRange:NSMakeRange(0, 0)];
    CHECK([editor selectNextSearchMatch] && NSEqualRanges(editor.selectedRange, NSMakeRange(11, 4)),
          "navigation must search synchronously while results are pending");
    CHECK(!editor.isSearchPending && editor.numberOfSearchMatches == 3, "synchronous search must apply results");

    editor.searchQuery = [[SCETextSearchQuery alloc] initWithPattern:@"[" options:SCETextSearchOptionRegularExpression];
    CHECK(SCEWaitForSearchResults(editor) && editor.searchError && editor.numberOfSearchMatches == 0,
          "an invalid pattern must report an error without matches");
    CHECK(![editor selectNextSearchMatch], "navigation without matches must fail");
    notifications = 0;
    editor.searchQuery = nil;
    CHECK(notifications == 1 && !editor.searchError && !editor.isSearchPending, "clearing the query must reset state");

    // Highlight rendering: only the line containing the match changes.
    editor.string = @"none\nnone\nthe target\n";
    editor.selectedRange = NSMakeRange(0, 0);
    CGFloat lineHeight = [[editor valueForKey:@"lineHeight"] doubleValue];
    uint8_t *plain = SCERenderBackground(editor, 400, 200);
    editor.searchQuery = [[SCETextSearchQuery alloc] initWithPattern:@"target" options:0];
    CHECK(SCEWaitForSearchResults(editor), "highlight search must complete");
    uint8_t *highlighted = SCERenderBackground(editor, 400, 200);
    size_t changed = 0;
    BOOL contained = YES;
    // Bitmap rows run from the bottom of the unflipped context; the editor's
    // y coordinate grows downward from the top.
    CGFloat lineTop = 12 + 2 * lineHeight;
    for (size_t row = 0; row < 200; row++) {
        for (size_t x = 0; x < 400; x++) {
            size_t offset = (row * 400 + x) * 4;
            if (memcmp(plain + offset, highlighted + offset, 4) != 0) {
                changed++;
                CGFloat y = 200 - (CGFloat)row;
                if (y < floor(lineTop) || y > ceil(lineTop + lineHeight) + 1) {
                    contained = NO;
                }
            }
        }
    }
    free(plain);
    free(highlighted);
    CHECK(changed > 0, "search matches must be highlighted");
    CHECK(contained, "match highlights must stay within the matching line");
    editor.string = @"replaced";
    CHECK(editor.numberOfSearchMatches == 0 && editor.isSearchPending, "replacing the document must clear matches");
    CHECK(SCEWaitForSearchResults(editor) && editor.numberOfSearchMatches == 0, "new document search differs");
    [NSNotificationCenter.defaultCenter removeObserver:observer];
    puts("PASS editor search: background results, navigation and wrapping, edits, errors, highlight rendering");
}

static int SCECompareDoubles(const void *a, const void *b) {
    double lhs = *(const double *)a;
    double rhs = *(const double *)b;
    return lhs < rhs ? -1 : lhs > rhs ? 1 : 0;
}

static void SCEBenchmark(void) {
    NSMutableString *text = [NSMutableString stringWithCapacity:4000000];
    for (NSUInteger i = 0; i < 100000; i++) {
        [text appendString:@"    let value = compute(input) // native\n"];
    }
    uint64_t start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    SCETextBuffer *buffer = [[SCETextBuffer alloc] initWithString:text];
    double loadMS = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e6;
    double samples[500];
    for (NSUInteger i = 0; i < 500; i++) {
        @autoreleasepool {
            NSUInteger location = SCERandom(buffer.lengthUTF16 + 1);
            uint64_t tick = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
            [buffer replaceCharactersInUTF16Range:NSMakeRange(location, 0) withString:@"x"];
            [buffer replaceCharactersInUTF16Range:NSMakeRange(location, 1) withString:@""];
            samples[i] = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - tick) / 1e6;
        }
    }
    qsort(samples, 500, sizeof(double), SCECompareDoubles);
    CHECK([buffer.string isEqualToString:text], "benchmark edits must round-trip");
    printf(
        "BUFFER BENCH (unoptimized debug build): %.1f Mi UTF-16 units, 100k lines, build %.2f ms, insert+delete p50 %.3f ms / p95 %.3f ms\n",
        text.length / 1048576.0, loadMS, samples[250], samples[475]);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        SCECheckRope();
        SCECheckEditing();
        SCECheckComposition();
        SCECheckSelectionContours();
        SCECheckSelectionPainting();
        SCECheckScopeGuide();
        SCECheckLayoutAndViewport();
        SCECheckSearchQueries();
        SCECheckEditorSearch();
        SCECheckCount += SCECheckEditorInteractions();
        SCECheckCount += SCECheckSyntaxCore();
        SCECheckCount += SCECheckConfiguredEditing();
        SCEBenchmark();
        printf("All %lu checks passed.\n", (unsigned long)SCECheckCount);
    }
    return 0;
}
