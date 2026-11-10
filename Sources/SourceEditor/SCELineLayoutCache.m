#import "SCELineLayoutCache.h"
#import "SCETextBufferInternal.h"

const NSUInteger SCELineLayoutMaximumUnfragmentedLength = 2048;
const NSUInteger SCELineLayoutFragmentLength = 1024;

enum {
    // A fragment boundary moves back at most this far from its nominal position
    // to follow a space, a tab or a grapheme cluster boundary. It is less than
    // half the fragment length, so boundaries remain in order.
    SCELineFragmentBoundarySearchLength = 64,
};

// The number of fragment CTLines a fragmented layout retains. A viewport shows
// two or three fragments of a long line.
static const NSUInteger SCELineFragmentCacheLimit = 8;

static void SCEDrawCTLine(CGContextRef context, CTLineRef line, CGFloat x, CGFloat baseline) {
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, x, baseline);
    CGContextScaleCTM(context, 1, -1);
    CGContextSetTextMatrix(context, CGAffineTransformIdentity);
    CGContextSetTextPosition(context, 0, 0);
    CTLineDraw(line, context);
    CGContextRestoreGState(context);
}

// Appends the visual spans of range, in the coordinates of line, offset by originX.
static void SCEAppendSelectionRects(CTLineRef line, NSRange range, CGFloat originX, CGFloat height,
                                    NSMutableArray<NSValue *> *rects) {
    for (id runObject in (__bridge NSArray *)CTLineGetGlyphRuns(line)) {
        CTRunRef run = (__bridge CTRunRef)runObject;
        CFRange runRange = CTRunGetStringRange(run);
        NSRange overlap = NSIntersectionRange(range, NSMakeRange(runRange.location, runRange.length));
        if (!overlap.length) {
            continue;
        }
        CFIndex count = CTRunGetGlyphCount(run);
        if (!count) {
            continue;
        }
        // Use glyph clusters, rather than one rectangle between logical ends:
        // a mixed-direction selection can have several disjoint visual spans.
        CFIndex *indices = malloc(sizeof(CFIndex) * (size_t)count);
        CGPoint *positions = malloc(sizeof(CGPoint) * (size_t)count);
        CGSize *advances = malloc(sizeof(CGSize) * (size_t)count);
        CTRunGetStringIndices(run, CFRangeMake(0, 0), indices);
        CTRunGetPositions(run, CFRangeMake(0, 0), positions);
        CTRunGetAdvances(run, CFRangeMake(0, 0), advances);
        BOOL rtl = (CTRunGetStatus(run) & kCTRunStatusRightToLeft) != 0;
        CGFloat low = CGFLOAT_MAX;
        CGFloat high = -CGFLOAT_MAX;
        for (CFIndex i = 0; i < count; i++) {
            CFIndex clusterStart = indices[i];
            CFIndex clusterEnd = runRange.location + runRange.length;
            CFIndex neighbor = i + (rtl ? -1 : 1);
            while (neighbor >= 0 && neighbor < count && indices[neighbor] == clusterStart) {
                neighbor += rtl ? -1 : 1;
            }
            if (neighbor >= 0 && neighbor < count && indices[neighbor] > clusterStart) {
                clusterEnd = indices[neighbor];
            }
            if (clusterStart < (CFIndex)NSMaxRange(overlap) && clusterEnd > (CFIndex)overlap.location) {
                low = MIN(low, MIN(positions[i].x, positions[i].x + advances[i].width));
                high = MAX(high, MAX(positions[i].x, positions[i].x + advances[i].width));
            }
        }
        free(indices);
        free(positions);
        free(advances);
        if (high >= low) {
            [rects addObject:[NSValue valueWithRect:NSMakeRect(originX + low, 0, MAX(1, high - low), height)]];
        }
    }
}

// Font fallback, tabs, shaping and fragments can split one continuous visual
// selection into several spans. Merges touching spans while preserving unselected
// gaps in a partially selected bidirectional line.
static NSArray<NSValue *> *SCEMergeSelectionRects(NSMutableArray<NSValue *> *rects) {
    [rects sortUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
        CGFloat left = NSMinX(a.rectValue);
        CGFloat right = NSMinX(b.rectValue);
        return left < right ? NSOrderedAscending : left > right ? NSOrderedDescending : NSOrderedSame;
    }];
    NSMutableArray<NSValue *> *merged = [NSMutableArray arrayWithCapacity:rects.count];
    for (NSValue *value in rects) {
        NSRect rect = value.rectValue;
        if (merged.count && NSMinX(rect) <= NSMaxX(merged.lastObject.rectValue) + 1e-6) {
            merged[merged.count - 1] = [NSValue valueWithRect:NSUnionRect(merged.lastObject.rectValue, rect)];
        } else {
            [merged addObject:value];
        }
    }
    return merged;
}

// The text and CTLine of one fragment, laid out at the fragment's position.
@interface SCELineFragment : NSObject
@property (nonatomic, readonly, copy) NSString *text;
@property (nonatomic, readonly) CTLineRef line;
@property (nonatomic, readonly) CGFloat width;

/// Takes ownership of line.
- (instancetype)initWithText:(NSString *)text line:(CTLineRef)line;
@end

@implementation SCELineFragment

- (instancetype)initWithText:(NSString *)text line:(CTLineRef)line {
    if ((self = [super init])) {
        _text = [text copy];
        _line = line;
        _width = (CGFloat)CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    }
    return self;
}

- (void)dealloc {
    CFRelease(_line);
}

@end

// A syntax token of a fragmented line, in line-local UTF-16 offsets. order is the
// token's index in the line's token array, which decides precedence.
typedef struct {
    NSUInteger start;
    NSUInteger end;
    NSUInteger order;
} SCETokenSpan;

static int SCECompareTokenSpansByStart(const void *a, const void *b) {
    const SCETokenSpan *lhs = a;
    const SCETokenSpan *rhs = b;
    if (lhs->start != rhs->start) {
        return lhs->start < rhs->start ? -1 : 1;
    }
    return lhs->order < rhs->order ? -1 : lhs->order > rhs->order ? 1 : 0;
}

static int SCECompareTokenSpansByOrder(const void *a, const void *b) {
    const SCETokenSpan *lhs = a;
    const SCETokenSpan *rhs = b;
    return lhs->order < rhs->order ? -1 : lhs->order > rhs->order ? 1 : 0;
}

// The measured geometry of the leading fragments of a long line. A new layout of
// the same line reuses the fragments whose text and boundary windows lie in its
// first unchangedLength code units, so that editing or recoloring a long line
// does not measure it again from the start.
@interface SCELineLayoutPrefix : NSObject
@property (nonatomic, readonly) NSUInteger length;
@property (nonatomic, readonly) NSUInteger fragmentCount;
@property (nonatomic, readonly) NSUInteger measuredFragmentCount;
@property (nonatomic, readonly) NSUInteger unchangedLength;
/// measuredFragmentCount + 1 fragment starts, then as many x offsets.
@property (nonatomic, readonly, copy) NSData *fragmentStarts;
@property (nonatomic, readonly, copy) NSData *fragmentOffsets;

- (instancetype)initWithLength:(NSUInteger)length
                 fragmentCount:(NSUInteger)fragmentCount
         measuredFragmentCount:(NSUInteger)measuredFragmentCount
                fragmentStarts:(NSData *)fragmentStarts
               fragmentOffsets:(NSData *)fragmentOffsets
               unchangedLength:(NSUInteger)unchangedLength;

- (SCELineLayoutPrefix *)prefixPreservingUTF16Length:(NSUInteger)unchangedLength;
@end

@implementation SCELineLayoutPrefix

- (instancetype)initWithLength:(NSUInteger)length
                 fragmentCount:(NSUInteger)fragmentCount
         measuredFragmentCount:(NSUInteger)measuredFragmentCount
                fragmentStarts:(NSData *)fragmentStarts
               fragmentOffsets:(NSData *)fragmentOffsets
               unchangedLength:(NSUInteger)unchangedLength {
    if ((self = [super init])) {
        _length = length;
        _fragmentCount = fragmentCount;
        _measuredFragmentCount = measuredFragmentCount;
        _fragmentStarts = [fragmentStarts copy];
        _fragmentOffsets = [fragmentOffsets copy];
        _unchangedLength = MIN(unchangedLength, length);
    }
    return self;
}

- (SCELineLayoutPrefix *)prefixPreservingUTF16Length:(NSUInteger)unchangedLength {
    return [[SCELineLayoutPrefix alloc] initWithLength:_length
                                         fragmentCount:_fragmentCount
                                 measuredFragmentCount:_measuredFragmentCount
                                        fragmentStarts:_fragmentStarts
                                       fragmentOffsets:_fragmentOffsets
                                       unchangedLength:MIN(_unchangedLength, unchangedLength)];
}

@end

@interface SCELineLayout ()
- (instancetype)initWithBuffer:(SCETextBuffer *)buffer
                     lineRange:(NSRange)lineRange
                    attributes:(NSDictionary *)attributes
            fragmentAttributes:(NSDictionary *)fragmentAttributes
                        tokens:(NSArray<SCESyntaxToken *> *)tokens
                         theme:(SCESyntaxTheme *)theme
                    appearance:(nullable NSAppearance *)appearance
                        prefix:(nullable SCELineLayoutPrefix *)prefix;

/// Returns the measured geometry of a fragmented line whose first unchangedLength
/// code units stay the same, or nil for a line with one fragment.
- (nullable SCELineLayoutPrefix *)prefixPreservingUTF16Length:(NSUInteger)unchangedLength;
@end

@implementation SCELineLayout {
    // An immutable snapshot that fragments read their text from. Lines with one
    // fragment release it after laying out.
    SCETextBuffer *_buffer;
    NSUInteger _lineStart;
    NSUInteger _length;
    NSDictionary *_attributes;
    NSArray<SCESyntaxToken *> *_tokens;
    SCESyntaxTheme *_theme;
    NSAppearance *_appearance;
    NSUInteger _fragmentCount;
    // Line-local start of each fragment, followed by the line length. NSNotFound
    // marks boundaries that have not been computed.
    NSUInteger *_fragmentStarts;
    // x of each fragment start, followed by the line width. Valid for indices up
    // to _measuredFragmentCount.
    CGFloat *_fragmentOffsets;
    NSUInteger _measuredFragmentCount;
    SCELineFragment *_singleFragment;
    NSMutableDictionary<NSNumber *, SCELineFragment *> *_fragments;
    NSMutableArray<NSNumber *> *_fragmentUseOrder;
    // Tokens of a fragmented line. Short tokens are sorted by start, so a fragment
    // finds its tokens by binary search; tokens longer than a fragment are few and
    // are tested individually.
    SCETokenSpan *_shortTokenSpans;
    NSUInteger _shortTokenSpanCount;
    SCETokenSpan *_longTokenSpans;
    NSUInteger _longTokenSpanCount;
}

- (instancetype)initWithBuffer:(SCETextBuffer *)buffer
                     lineRange:(NSRange)lineRange
                    attributes:(NSDictionary *)attributes
            fragmentAttributes:(NSDictionary *)fragmentAttributes
                        tokens:(NSArray<SCESyntaxToken *> *)tokens
                         theme:(SCESyntaxTheme *)theme
                    appearance:(NSAppearance *)appearance
                        prefix:(SCELineLayoutPrefix *)prefix {
    if ((self = [super init])) {
        _buffer = buffer;
        _lineStart = lineRange.location;
        _length = lineRange.length;
        _tokens = [tokens copy];
        _theme = theme;
        _appearance = appearance;
        _fragmentCount = _length > SCELineLayoutMaximumUnfragmentedLength ? _length / SCELineLayoutFragmentLength : 1;
        _attributes = _fragmentCount > 1 ? fragmentAttributes : attributes;
        _fragmentStarts = malloc((_fragmentCount + 1) * sizeof(NSUInteger));
        _fragmentOffsets = calloc(_fragmentCount + 1, sizeof(CGFloat));
        for (NSUInteger index = 0; index <= _fragmentCount; index++) {
            _fragmentStarts[index] = NSNotFound;
        }
        _fragmentStarts[0] = 0;
        _fragmentStarts[_fragmentCount] = _length;
        if (_fragmentCount > 1) {
            _fragments = [NSMutableDictionary dictionary];
            _fragmentUseOrder = [NSMutableArray array];
            [self indexTokens];
            [self adoptPrefix:prefix];
        }
        // Measure the first fragment, which also provides the width estimate.
        if (_measuredFragmentCount == 0) {
            SCELineFragment *first = [self fragmentAtIndex:0];
            if (_fragmentCount == 1) {
                _singleFragment = first;
                _buffer = nil;
            }
        }
    }
    return self;
}

- (void)dealloc {
    free(_fragmentStarts);
    free(_fragmentOffsets);
    free(_shortTokenSpans);
    free(_longTokenSpans);
}

- (NSUInteger)length {
    return _length;
}

- (CTLineRef)line {
    return _singleFragment.line;
}

- (NSUInteger)fragmentCount {
    return _fragmentCount;
}

- (NSUInteger)measuredFragmentCount {
    return _measuredFragmentCount;
}

#pragma mark Fragments

// Fragment k can be reused when its text and the windows that place both of its
// boundaries lie in unchanged text, and its end is a computed boundary rather
// than the end of either line. Unchanged text preserves every measured fragment.
- (void)adoptPrefix:(SCELineLayoutPrefix *)prefix {
    if (!prefix || !prefix.measuredFragmentCount) {
        return;
    }
    NSUInteger reusable = prefix.measuredFragmentCount;
    if (prefix.length == _length && prefix.unchangedLength == _length) {
        reusable = MIN(reusable, _fragmentCount);
    } else {
        NSUInteger stableBoundaries =
            prefix.unchangedLength >= SCELineFragmentBoundarySearchLength
                ? (prefix.unchangedLength - SCELineFragmentBoundarySearchLength) / SCELineLayoutFragmentLength
                : 0;
        reusable = MIN(MIN(reusable, stableBoundaries), MIN(_fragmentCount, prefix.fragmentCount) - 1);
    }
    if (!reusable) {
        return;
    }
    const NSUInteger *starts = prefix.fragmentStarts.bytes;
    const CGFloat *offsets = prefix.fragmentOffsets.bytes;
    for (NSUInteger index = 0; index <= reusable; index++) {
        if (index < _fragmentCount) {
            _fragmentStarts[index] = starts[index];
        }
        _fragmentOffsets[index] = offsets[index];
    }
    _measuredFragmentCount = reusable;
}

- (SCELineLayoutPrefix *)prefixPreservingUTF16Length:(NSUInteger)unchangedLength {
    if (_fragmentCount == 1) {
        return nil;
    }
    NSUInteger count = _measuredFragmentCount + 1;
    return [[SCELineLayoutPrefix alloc]
               initWithLength:_length
                fragmentCount:_fragmentCount
        measuredFragmentCount:_measuredFragmentCount
               fragmentStarts:[NSData dataWithBytes:_fragmentStarts length:count * sizeof(NSUInteger)]
              fragmentOffsets:[NSData dataWithBytes:_fragmentOffsets length:count * sizeof(CGFloat)]
              unchangedLength:unchangedLength];
}

- (void)indexTokens {
    _shortTokenSpans = malloc(MAX(1, _tokens.count) * sizeof(SCETokenSpan));
    _longTokenSpans = malloc(MAX(1, _tokens.count) * sizeof(SCETokenSpan));
    BOOL sorted = YES;
    NSUInteger order = 0;
    for (SCESyntaxToken *token in _tokens) {
        NSRange range = NSIntersectionRange(token.range, NSMakeRange(0, _length));
        if (range.length) {
            SCETokenSpan span = {range.location, NSMaxRange(range), order};
            if (range.length > SCELineLayoutFragmentLength) {
                _longTokenSpans[_longTokenSpanCount++] = span;
            } else {
                sorted =
                    sorted && (!_shortTokenSpanCount || _shortTokenSpans[_shortTokenSpanCount - 1].start <= span.start);
                _shortTokenSpans[_shortTokenSpanCount++] = span;
            }
        }
        order++;
    }
    // Highlighters usually report tokens in document order, which needs no sort.
    if (!sorted) {
        qsort(_shortTokenSpans, _shortTokenSpanCount, sizeof(SCETokenSpan), SCECompareTokenSpansByStart);
    }
}

// Computes the start of a fragment near its nominal position, index times the
// fragment length. A position after a space or tab is preferred because shaping
// and bidirectional reordering do not cross fragments; otherwise the boundary is
// the start of the grapheme cluster at the nominal position. The result depends
// only on nearby text, so fragments can be located without reading the line.
- (NSUInteger)startOfFragmentAtIndex:(NSUInteger)index {
    NSUInteger start = _fragmentStarts[index];
    if (start != NSNotFound) {
        return start;
    }
    NSUInteger nominal = index * SCELineLayoutFragmentLength;
    NSUInteger windowStart = nominal - SCELineFragmentBoundarySearchLength;
    NSUInteger windowEnd = MIN(_length, nominal + SCELineFragmentBoundarySearchLength);
    unichar characters[2 * SCELineFragmentBoundarySearchLength];
    [_buffer getUTF16Characters:characters range:NSMakeRange(_lineStart + windowStart, windowEnd - windowStart)];
    NSString *window = [[NSString alloc] initWithCharacters:characters length:windowEnd - windowStart];
    NSUInteger local = nominal - windowStart;
    for (NSUInteger candidate = local; candidate > 0; candidate--) {
        unichar previous = characters[candidate - 1];
        if ((previous == ' ' || previous == '\t') &&
            [window rangeOfComposedCharacterSequenceAtIndex:candidate].location == candidate) {
            start = windowStart + candidate;
            break;
        }
    }
    if (start == NSNotFound) {
        start = windowStart + [window rangeOfComposedCharacterSequenceAtIndex:local].location;
    }
    _fragmentStarts[index] = start;
    return start;
}

- (NSRange)rangeOfFragmentAtIndex:(NSUInteger)index {
    NSUInteger start = [self startOfFragmentAtIndex:index];
    return NSMakeRange(start, [self startOfFragmentAtIndex:index + 1] - start);
}

- (NSUInteger)fragmentIndexForUTF16Index:(NSUInteger)index {
    if (_fragmentCount == 1) {
        return 0;
    }
    NSUInteger fragment = MIN(index / SCELineLayoutFragmentLength, _fragmentCount - 1);
    if (fragment && index < [self startOfFragmentAtIndex:fragment]) {
        return fragment - 1;
    }
    if (fragment + 1 < _fragmentCount && index >= [self startOfFragmentAtIndex:fragment + 1]) {
        return fragment + 1;
    }
    return fragment;
}

// Returns the last measured fragment that starts at or before x.
- (NSUInteger)fragmentIndexForX:(CGFloat)x {
    NSUInteger low = 0;
    NSUInteger high = _measuredFragmentCount;
    while (low < high) {
        NSUInteger middle = low + (high - low) / 2;
        if (_fragmentOffsets[middle] <= x) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    return low ? low - 1 : 0;
}

- (void)applyTokenColorsToString:(NSMutableAttributedString *)string fragmentRange:(NSRange)fragmentRange {
    NSUInteger fragmentEnd = NSMaxRange(fragmentRange);
    SCETokenSpan *spans = NULL;
    NSUInteger count = 0;
    if (_fragmentCount == 1) {
        spans = malloc(MAX(1, _tokens.count) * sizeof(SCETokenSpan));
        for (NSUInteger order = 0; order < _tokens.count; order++) {
            NSRange range = NSIntersectionRange(_tokens[order].range, NSMakeRange(0, _length));
            spans[count++] = (SCETokenSpan){range.location, NSMaxRange(range), order};
        }
    } else {
        spans = malloc(MAX(1, _shortTokenSpanCount + _longTokenSpanCount) * sizeof(SCETokenSpan));
        // A short token that overlaps the fragment starts at most one fragment
        // length before it.
        NSUInteger earliest = fragmentRange.location > SCELineLayoutFragmentLength
                                  ? fragmentRange.location - SCELineLayoutFragmentLength
                                  : 0;
        NSUInteger low = 0;
        NSUInteger high = _shortTokenSpanCount;
        while (low < high) {
            NSUInteger middle = low + (high - low) / 2;
            if (_shortTokenSpans[middle].start < earliest) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        for (NSUInteger index = low; index < _shortTokenSpanCount && _shortTokenSpans[index].start < fragmentEnd;
             index++) {
            if (_shortTokenSpans[index].end > fragmentRange.location) {
                spans[count++] = _shortTokenSpans[index];
            }
        }
        for (NSUInteger index = 0; index < _longTokenSpanCount; index++) {
            if (_longTokenSpans[index].start < fragmentEnd && _longTokenSpans[index].end > fragmentRange.location) {
                spans[count++] = _longTokenSpans[index];
            }
        }
        qsort(spans, count, sizeof(SCETokenSpan), SCECompareTokenSpansByOrder);
    }
    void (^applyColors)(void) = ^{
        for (NSUInteger index = 0; index < count; index++) {
            NSUInteger start = MAX(spans[index].start, fragmentRange.location);
            NSUInteger end = MIN(spans[index].end, fragmentEnd);
            if (end <= start) {
                continue;
            }
            NSColor *color = [self->_theme foregroundColorForKind:self->_tokens[spans[index].order].kind];
            id foreground = color ? (__bridge id)color.CGColor
                                  : self->_attributes[(__bridge NSString *)kCTForegroundColorAttributeName];
            [string addAttribute:(__bridge NSString *)kCTForegroundColorAttributeName
                           value:foreground
                           range:NSMakeRange(start - fragmentRange.location, end - start)];
        }
    };
    if (_appearance) {
        [_appearance performAsCurrentDrawingAppearance:applyColors];
    } else {
        applyColors();
    }
    free(spans);
}

// Lays out a fragment at its measured position. Colors do not affect geometry,
// so a fragment created only to measure its width omits them.
- (SCELineFragment *)createFragmentAtIndex:(NSUInteger)index colored:(BOOL)colored {
    NSRange range = [self rangeOfFragmentAtIndex:index];
    NSString *text = [_buffer substringWithUTF16Range:NSMakeRange(_lineStart + range.location, range.length)];
    NSMutableAttributedString *attributed = [[NSMutableAttributedString alloc] initWithString:text
                                                                                   attributes:_attributes];
    if (colored && _tokens.count) {
        [self applyTokenColorsToString:attributed fragmentRange:range];
    }
    CTLineRef line;
    if (_fragmentCount == 1) {
        line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attributed);
    } else {
        // The offset places tab stops relative to the start of the line rather
        // than the start of the fragment.
        CTTypesetterRef typesetter = CTTypesetterCreateWithAttributedString((__bridge CFAttributedStringRef)attributed);
        line = CTTypesetterCreateLineWithOffset(typesetter, CFRangeMake(0, 0), _fragmentOffsets[index]);
        CFRelease(typesetter);
    }
    return [[SCELineFragment alloc] initWithText:text line:line];
}

- (void)recordWidthOfFragment:(SCELineFragment *)fragment atIndex:(NSUInteger)index {
    if (index == _measuredFragmentCount) {
        _fragmentOffsets[index + 1] = _fragmentOffsets[index] + fragment.width;
        _measuredFragmentCount++;
    }
}

// Returns a laid-out fragment with syntax colors. Requires that every earlier
// fragment is measured, since the fragment's position depends on them.
- (SCELineFragment *)fragmentAtIndex:(NSUInteger)index {
    NSParameterAssert(index <= _measuredFragmentCount && index < _fragmentCount);
    if (_singleFragment) {
        return _singleFragment;
    }
    NSNumber *key = @(index);
    SCELineFragment *fragment = _fragments[key];
    if (fragment) {
        [_fragmentUseOrder removeObject:key];
        [_fragmentUseOrder addObject:key];
        return fragment;
    }
    fragment = [self createFragmentAtIndex:index colored:YES];
    [self recordWidthOfFragment:fragment atIndex:index];
    if (_fragments) {
        _fragments[key] = fragment;
        [_fragmentUseOrder addObject:key];
        if (_fragmentUseOrder.count > SCELineFragmentCacheLimit) {
            [_fragments removeObjectForKey:_fragmentUseOrder.firstObject];
            [_fragmentUseOrder removeObjectAtIndex:0];
        }
    }
    return fragment;
}

// Measuring a long prefix lays out many fragments in one call, so each one
// releases its temporary text and Core Text objects before the next.
- (void)measureNextFragment {
    @autoreleasepool {
        NSUInteger index = _measuredFragmentCount;
        SCELineFragment *fragment = _fragments[@(index)] ?: [self createFragmentAtIndex:index colored:NO];
        [self recordWidthOfFragment:fragment atIndex:index];
    }
}

- (void)measureFragmentsThroughIndex:(NSUInteger)index {
    while (_measuredFragmentCount <= index && _measuredFragmentCount < _fragmentCount) {
        [self measureNextFragment];
    }
}

// Measures fragments until one starts after x or the line ends.
- (void)measureFragmentsThroughX:(CGFloat)x {
    while (_measuredFragmentCount < _fragmentCount && _fragmentOffsets[_measuredFragmentCount] <= x) {
        [self measureNextFragment];
    }
}

// Measures fragments through index unless they reach maximumX first. Returns
// whether the fragment at index is measured.
- (BOOL)measureFragmentsThroughIndex:(NSUInteger)index beforeX:(CGFloat)maximumX {
    while (_measuredFragmentCount <= index) {
        if (_fragmentOffsets[_measuredFragmentCount] >= maximumX) {
            return NO;
        }
        [self measureNextFragment];
    }
    return YES;
}

#pragma mark Geometry

- (CGFloat)width {
    [self measureFragmentsThroughIndex:_fragmentCount - 1];
    return _fragmentOffsets[_fragmentCount];
}

- (CGFloat)estimatedWidth {
    if (_measuredFragmentCount == _fragmentCount) {
        return _fragmentOffsets[_fragmentCount];
    }
    NSUInteger measuredLength = _fragmentStarts[_measuredFragmentCount];
    CGFloat measuredWidth = _fragmentOffsets[_measuredFragmentCount];
    CGFloat advance = measuredLength ? measuredWidth / measuredLength : 0;
    return measuredWidth + (_length - measuredLength) * advance;
}

- (CGFloat)xForUTF16Index:(NSUInteger)index inMeasuredFragmentAtIndex:(NSUInteger)fragmentIndex {
    NSUInteger start = _fragmentStarts[fragmentIndex];
    if (_fragmentCount > 1) {
        if (index == start) {
            return _fragmentOffsets[fragmentIndex];
        }
        if (index == _fragmentStarts[fragmentIndex + 1]) {
            return _fragmentOffsets[fragmentIndex + 1];
        }
    }
    SCELineFragment *fragment = [self fragmentAtIndex:fragmentIndex];
    return _fragmentOffsets[fragmentIndex] +
           CTLineGetOffsetForStringIndex(fragment.line, (CFIndex)(index - start), NULL);
}

- (CGFloat)xForUTF16Index:(NSUInteger)index {
    index = MIN(index, _length);
    NSUInteger fragmentIndex = [self fragmentIndexForUTF16Index:index];
    [self measureFragmentsThroughIndex:fragmentIndex];
    return [self xForUTF16Index:index inMeasuredFragmentAtIndex:fragmentIndex];
}

- (CGFloat)xForUTF16Index:(NSUInteger)index clampedToMaximumX:(CGFloat)maximumX {
    index = MIN(index, _length);
    NSUInteger fragmentIndex = [self fragmentIndexForUTF16Index:index];
    if (![self measureFragmentsThroughIndex:fragmentIndex beforeX:maximumX] ||
        _fragmentOffsets[fragmentIndex] >= maximumX) {
        return maximumX;
    }
    return MIN(maximumX, [self xForUTF16Index:index inMeasuredFragmentAtIndex:fragmentIndex]);
}

- (NSUInteger)UTF16IndexForX:(CGFloat)x {
    if (!_length) {
        return 0;
    }
    [self measureFragmentsThroughX:x];
    if (_fragmentCount > 1 && _measuredFragmentCount == _fragmentCount && x >= _fragmentOffsets[_fragmentCount]) {
        return _length;
    }
    NSUInteger fragmentIndex = [self fragmentIndexForX:x];
    SCELineFragment *fragment = [self fragmentAtIndex:fragmentIndex];
    NSUInteger start = _fragmentStarts[fragmentIndex];
    CGFloat localX = x - _fragmentOffsets[fragmentIndex];
    NSString *text = fragment.text;
    CFIndex raw = CTLineGetStringIndexForPosition(fragment.line, CGPointMake(localX, 0));
    if (raw == kCFNotFound) {
        return start;
    }
    NSUInteger local = MIN((NSUInteger)MAX(0, raw), text.length);
    if (local == text.length) {
        return start + local;
    }
    NSRange cluster = [text rangeOfComposedCharacterSequenceAtIndex:local];
    if (local == cluster.location) {
        return start + local;
    }
    CGFloat before = CTLineGetOffsetForStringIndex(fragment.line, (CFIndex)cluster.location, NULL);
    CGFloat after = CTLineGetOffsetForStringIndex(fragment.line, (CFIndex)NSMaxRange(cluster), NULL);
    return start + (fabs(localX - before) <= fabs(localX - after) ? cluster.location : NSMaxRange(cluster));
}

- (NSArray<NSValue *> *)selectionRectsForUTF16Range:(NSRange)range height:(CGFloat)height {
    return [self selectionRectsForUTF16Range:range height:height minimumX:-CGFLOAT_MAX maximumX:CGFLOAT_MAX];
}

- (NSArray<NSValue *> *)selectionRectsForUTF16Range:(NSRange)range
                                             height:(CGFloat)height
                                           minimumX:(CGFloat)minimumX
                                           maximumX:(CGFloat)maximumX {
    NSUInteger start = MIN(range.location, _length);
    NSUInteger end = start + MIN(range.length, _length - start);
    if (end <= start) {
        return @[];
    }
    NSMutableArray<NSValue *> *rects = [NSMutableArray array];
    NSUInteger lastFragment = [self fragmentIndexForUTF16Index:end - 1];
    for (NSUInteger index = [self fragmentIndexForUTF16Index:start]; index <= lastFragment; index++) {
        if (![self measureFragmentsThroughIndex:index beforeX:maximumX] || _fragmentOffsets[index] >= maximumX) {
            break;
        }
        CGFloat fragmentMinX = _fragmentOffsets[index];
        CGFloat fragmentMaxX = _fragmentOffsets[index + 1];
        if (fragmentMaxX < minimumX) {
            continue;
        }
        NSUInteger fragmentStart = _fragmentStarts[index];
        NSUInteger fragmentEnd = _fragmentStarts[index + 1];
        if (_fragmentCount > 1 && start <= fragmentStart && end >= fragmentEnd) {
            // A wholly selected fragment of a left-to-right line is one span.
            [rects addObject:[NSValue valueWithRect:NSMakeRect(fragmentMinX, 0, fragmentMaxX - fragmentMinX, height)]];
            continue;
        }
        NSUInteger overlapStart = MAX(start, fragmentStart);
        NSRange local = NSMakeRange(overlapStart - fragmentStart, MIN(end, fragmentEnd) - overlapStart);
        SCEAppendSelectionRects([self fragmentAtIndex:index].line, local, fragmentMinX, height, rects);
    }
    return SCEMergeSelectionRects(rects);
}

- (void)drawInContext:(CGContextRef)context
     atBaselineOrigin:(CGPoint)origin
             minimumX:(CGFloat)minimumX
             maximumX:(CGFloat)maximumX {
    [self measureFragmentsThroughX:maximumX];
    for (NSUInteger index = [self fragmentIndexForX:minimumX];
         index < _measuredFragmentCount && _fragmentOffsets[index] < maximumX; index++) {
        SCEDrawCTLine(context, [self fragmentAtIndex:index].line, origin.x + _fragmentOffsets[index], origin.y);
    }
}

- (CTLineRef)lineOfFragmentContainingUTF16Index:(NSUInteger)index fragmentStart:(NSUInteger *)fragmentStart {
    NSUInteger fragmentIndex = [self fragmentIndexForUTF16Index:MIN(index, _length)];
    [self measureFragmentsThroughIndex:fragmentIndex];
    if (fragmentStart) {
        *fragmentStart = _fragmentStarts[fragmentIndex];
    }
    return [self fragmentAtIndex:fragmentIndex].line;
}

@end

static const NSUInteger SCEMaximumRemappedLinesPerToken = 256;

@implementation SCELineLayoutCache {
    SCETextBuffer *_buffer;
    NSMutableDictionary<NSNumber *, SCELineLayout *> *_layouts;
    NSMutableDictionary<NSNumber *, NSArray<SCESyntaxToken *> *> *_syntaxTokens;
    NSDictionary *_attributes;
    NSDictionary *_fragmentAttributes;
    // A snapshot shared by the layouts of one revision. Fragmented layouts read
    // their text from it on demand, so later edits cannot change their text.
    SCETextBuffer *_snapshot;
    // Measured geometry of discarded long-line layouts, by line index, for the
    // next layout of the same line. Font, tab width and appearance changes clear it.
    NSMutableDictionary<NSNumber *, SCELineLayoutPrefix *> *_layoutPrefixes;
    NSUInteger _totalLayoutBuildCount;
}

- (instancetype)initWithBuffer:(SCETextBuffer *)buffer font:(NSFont *)font {
    if ((self = [super init])) {
        _buffer = buffer;
        _font = [font copy];
        _textColor = NSColor.textColor;
        _tabWidth = 4;
        _layouts = [NSMutableDictionary dictionary];
        _layoutPrefixes = [NSMutableDictionary dictionary];
        _syntaxTokens = [NSMutableDictionary dictionary];
        _syntaxTheme = SCESyntaxTheme.defaultTheme;
    }
    return self;
}

- (void)setFont:(NSFont *)font {
    _font = [font copy];
    [self removeAllLayouts];
}

- (void)setTextColor:(NSColor *)textColor {
    _textColor = [textColor copy];
    [self removeAllLayouts];
}

- (void)setTabWidth:(NSUInteger)tabWidth {
    _tabWidth = MAX(1, tabWidth);
    [self removeAllLayouts];
}

- (void)setSyntaxTheme:(SCESyntaxTheme *)syntaxTheme {
    _syntaxTheme = [syntaxTheme copy];
    [self removeAllLayouts];
}

- (void)setAppearance:(NSAppearance *)appearance {
    _appearance = appearance;
    [self removeAllLayouts];
}

- (NSUInteger)cachedLineCount {
    return _layouts.count;
}

- (NSUInteger)totalLayoutBuildCount {
    return _totalLayoutBuildCount;
}

- (void)removeAllLayouts {
    [_layouts removeAllObjects];
    [_layoutPrefixes removeAllObjects];
    _attributes = nil;
    _fragmentAttributes = nil;
    _snapshot = nil;
}

- (NSDictionary *)attributes {
    if (!_attributes) {
        CTFontRef font = (__bridge CTFontRef)_font;
        UniChar space = ' ';
        CGGlyph glyph;
        CGSize advance = CGSizeMake(_font.pointSize * 0.6, 0);
        if (CTFontGetGlyphsForCharacters(font, &space, &glyph, 1)) {
            CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal, &glyph, &advance, 1);
        }
        CGFloat tabInterval = MAX(1, advance.width) * _tabWidth;
        CFArrayRef stops = CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
        CTParagraphStyleSetting settings[] = {
            {
                kCTParagraphStyleSpecifierDefaultTabInterval,
                sizeof(tabInterval),
                &tabInterval,
            },
            {
                kCTParagraphStyleSpecifierTabStops,
                sizeof(stops),
                &stops,
            },
        };
        CTParagraphStyleRef paragraph = CTParagraphStyleCreate(settings, 2);
        // Fragments of a long line share a left-to-right base direction, so that
        // a fragment that starts with right-to-left text does not mirror its layout.
        CTWritingDirection direction = kCTWritingDirectionLeftToRight;
        CTParagraphStyleSetting fragmentSettings[] = {
            settings[0],
            settings[1],
            {
                kCTParagraphStyleSpecifierBaseWritingDirection,
                sizeof(direction),
                &direction,
            },
        };
        CTParagraphStyleRef fragmentParagraph = CTParagraphStyleCreate(fragmentSettings, 3);
        NSDictionary *attributes = @{
            (__bridge NSString *)kCTFontAttributeName : _font,
            (__bridge NSString *)kCTForegroundColorAttributeName : (__bridge id)_textColor.CGColor,
            (__bridge NSString *)kCTLigatureAttributeName : @0,
            (__bridge NSString *)kCTParagraphStyleAttributeName : (__bridge id)paragraph,
        };
        _attributes = attributes;
        NSMutableDictionary *fragmentAttributes = [attributes mutableCopy];
        fragmentAttributes[(__bridge NSString *)kCTParagraphStyleAttributeName] = (__bridge id)fragmentParagraph;
        _fragmentAttributes = [fragmentAttributes copy];
        CFRelease(fragmentParagraph);
        CFRelease(paragraph);
        CFRelease(stops);
    }
    return _attributes;
}

- (NSDictionary *)fragmentAttributes {
    [self attributes];
    return _fragmentAttributes;
}

- (SCELineLayout *)layoutForLineAtIndex:(NSUInteger)lineIndex {
    SCELineLayout *layout = _layouts[@(lineIndex)];
    if (!layout) {
        if (!_snapshot || ![_snapshot hasSameStorageAsBuffer:_buffer]) {
            _snapshot = [_buffer copy];
        }
        layout = [[SCELineLayout alloc] initWithBuffer:_snapshot
                                             lineRange:[_buffer UTF16RangeOfLine:lineIndex includingLineEnding:NO]
                                            attributes:self.attributes
                                    fragmentAttributes:self.fragmentAttributes
                                                tokens:_syntaxTokens[@(lineIndex)] ?: @[]
                                                 theme:_syntaxTheme
                                            appearance:_appearance
                                                prefix:_layoutPrefixes[@(lineIndex)]];
        [_layoutPrefixes removeObjectForKey:@(lineIndex)];
        _layouts[@(lineIndex)] = layout;
        _totalLayoutBuildCount++;
    }
    return layout;
}

- (void)invalidateForReplacementOfUTF16Range:(NSRange)range
                           replacementLength:(NSUInteger)replacementLength
                              previousBuffer:(SCETextBuffer *)previousBuffer {
    NSUInteger firstLine = [previousBuffer lineIndexForUTF16Offset:range.location];
    NSUInteger lastLine = [previousBuffer lineIndexForUTF16Offset:NSMaxRange(range)];
    NSRange oldLineRange = NSMakeRange(firstLine, lastLine - firstLine + 1);
    NSInteger delta = (NSInteger)_buffer.lineCount - (NSInteger)previousBuffer.lineCount;
    // The first edited line keeps its text before the edit, so a long line can
    // reuse the geometry measured there instead of measuring it again.
    NSUInteger unchangedLength =
        range.location - [previousBuffer UTF16RangeOfLine:firstLine includingLineEnding:NO].location;
    SCELineLayoutPrefix *editedPrefix =
        [_layouts[@(firstLine)] prefixPreservingUTF16Length:unchangedLength]
            ?: [_layoutPrefixes[@(firstLine)] prefixPreservingUTF16Length:unchangedLength];
    NSMutableDictionary *updated = [NSMutableDictionary dictionaryWithCapacity:_layouts.count];
    [_layouts enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, SCELineLayout *layout, BOOL *stop) {
        NSUInteger index = key.unsignedIntegerValue;
        if (index < oldLineRange.location) {
            updated[key] = layout;
        } else if (index >= NSMaxRange(oldLineRange)) {
            updated[@((NSUInteger)((NSInteger)index + delta))] = layout;
        }
    }];
    _layouts = updated;
    NSMutableDictionary *updatedPrefixes = [NSMutableDictionary dictionaryWithCapacity:_layoutPrefixes.count + 1];
    [_layoutPrefixes enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, SCELineLayoutPrefix *prefix, BOOL *stop) {
        NSUInteger index = key.unsignedIntegerValue;
        if (index < oldLineRange.location) {
            updatedPrefixes[key] = prefix;
        } else if (index >= NSMaxRange(oldLineRange)) {
            updatedPrefixes[@((NSUInteger)((NSInteger)index + delta))] = prefix;
        }
    }];
    if (editedPrefix) {
        updatedPrefixes[@(firstLine)] = editedPrefix;
    }
    _layoutPrefixes = updatedPrefixes;
    NSMutableDictionary *updatedTokens = [NSMutableDictionary dictionaryWithCapacity:_syntaxTokens.count];
    NSMutableArray<SCESyntaxToken *> *editedTokens = [NSMutableArray array];
    [_syntaxTokens enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, NSArray<SCESyntaxToken *> *tokens, BOOL *stop) {
        NSUInteger index = key.unsignedIntegerValue;
        if (index < oldLineRange.location) {
            updatedTokens[key] = tokens;
        } else if (index >= NSMaxRange(oldLineRange)) {
            updatedTokens[@((NSUInteger)((NSInteger)index + delta))] = tokens;
        } else {
            NSUInteger lineStart = [previousBuffer UTF16RangeOfLine:index includingLineEnding:NO].location;
            for (SCESyntaxToken *token in tokens) {
                NSRange absolute = NSMakeRange(lineStart + token.range.location, token.range.length);
                [editedTokens addObject:[[SCESyntaxToken alloc] initWithRange:absolute kind:token.kind]];
            }
        }
    }];
    _syntaxTokens = updatedTokens;
    [self addSyntaxTokens:editedTokens remappedForReplacementOfUTF16Range:range replacementLength:replacementLength];
}

// Keeps the previous highlight visible on edited lines while the highlighter
// parses the new revision. Offsets before the edit are unchanged, offsets at or
// after the end of the replaced range shift by the length change, and offsets
// inside the replaced range, including its start, move to the end of the
// replacement. Text typed inside a token or at its trailing edge therefore takes
// that token's color, while text typed at its leading edge does not. The next
// accepted highlight result replaces these provisional tokens.
- (void)addSyntaxTokens:(NSArray<SCESyntaxToken *> *)tokens
    remappedForReplacementOfUTF16Range:(NSRange)range
                     replacementLength:(NSUInteger)replacementLength {
    NSUInteger editStart = range.location;
    NSUInteger oldEditEnd = NSMaxRange(range);
    NSUInteger newEditEnd = editStart + replacementLength;
    NSUInteger (^mapOffset)(NSUInteger) = ^NSUInteger(NSUInteger offset) {
        if (offset < editStart) {
            return offset;
        }
        return offset >= oldEditEnd ? offset - range.length + replacementLength : newEditEnd;
    };
    NSMutableDictionary<NSNumber *, NSMutableArray<SCESyntaxToken *> *> *tokensByLine =
        [NSMutableDictionary dictionary];
    for (SCESyntaxToken *token in tokens) {
        NSUInteger start = mapOffset(token.range.location);
        NSUInteger end = mapOffset(NSMaxRange(token.range));
        end = MIN(end, _buffer.lengthUTF16);
        if (end <= start) {
            continue;
        }
        // Bound the work for a large paste inside a multiline token. The editor
        // prunes tokens to the viewport immediately afterward, and the highlight
        // result restores any lines skipped here.
        NSUInteger firstLine = [_buffer lineIndexForUTF16Offset:start];
        NSUInteger lineLimit = MIN(_buffer.lineCount, firstLine + SCEMaximumRemappedLinesPerToken);
        for (NSUInteger line = firstLine; line < lineLimit; line++) {
            NSRange content = [_buffer UTF16RangeOfLine:line includingLineEnding:NO];
            if (content.location >= end) {
                break;
            }
            NSRange overlap = NSIntersectionRange(content, NSMakeRange(start, end - start));
            if (!overlap.length) {
                continue;
            }
            NSMutableArray<SCESyntaxToken *> *lineTokens = tokensByLine[@(line)];
            if (!lineTokens) {
                lineTokens = [NSMutableArray arrayWithArray:_syntaxTokens[@(line)] ?: @[]];
                tokensByLine[@(line)] = lineTokens;
            }
            NSRange local = NSMakeRange(overlap.location - content.location, overlap.length);
            [lineTokens addObject:[[SCESyntaxToken alloc] initWithRange:local kind:token.kind]];
        }
    }
    [tokensByLine
        enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, NSMutableArray<SCESyntaxToken *> *lineTokens, BOOL *stop) {
            self->_syntaxTokens[key] = [lineTokens copy];
        }];
}

- (void)retainLinesInRange:(NSRange)range {
    for (NSNumber *key in [_layouts.allKeys copy]) {
        if (!NSLocationInRange(key.unsignedIntegerValue, range)) {
            [_layouts removeObjectForKey:key];
        }
    }
    for (NSNumber *key in [_layoutPrefixes.allKeys copy]) {
        if (!NSLocationInRange(key.unsignedIntegerValue, range)) {
            [_layoutPrefixes removeObjectForKey:key];
        }
    }
    for (NSNumber *key in [_syntaxTokens.allKeys copy]) {
        if (!NSLocationInRange(key.unsignedIntegerValue, range)) {
            [_syntaxTokens removeObjectForKey:key];
        }
    }
}

- (BOOL)applySyntaxTokens:(NSArray<SCESyntaxToken *> *)tokens toLineRange:(NSRange)lineRange {
    if (lineRange.location >= _buffer.lineCount) {
        return NO;
    }
    NSUInteger lineCount = MIN(lineRange.length, _buffer.lineCount - lineRange.location);
    NSMutableArray<NSValue *> *contents = [NSMutableArray arrayWithCapacity:lineCount];
    NSMutableArray<NSMutableArray<SCESyntaxToken *> *> *tokensByLine = [NSMutableArray arrayWithCapacity:lineCount];
    for (NSUInteger index = 0; index < lineCount; index++) {
        NSRange content = [_buffer UTF16RangeOfLine:lineRange.location + index includingLineEnding:NO];
        [contents addObject:[NSValue valueWithRange:content]];
        [tokensByLine addObject:[NSMutableArray array]];
    }
    // Locate each capture's first affected visible line by binary search,
    // instead of scanning the entire capture list once for every visible row.
    for (SCESyntaxToken *token in tokens) {
        if (!token.range.length || token.range.location > _buffer.lengthUTF16 ||
            token.range.length > _buffer.lengthUTF16 - token.range.location) {
            continue;
        }
        NSUInteger low = 0;
        NSUInteger high = lineCount;
        while (low < high) {
            NSUInteger middle = low + (high - low) / 2;
            if (NSMaxRange(contents[middle].rangeValue) <= token.range.location) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        for (NSUInteger index = low; index < lineCount; index++) {
            NSRange content = contents[index].rangeValue;
            if (content.location >= NSMaxRange(token.range)) {
                break;
            }
            NSRange overlap = NSIntersectionRange(content, token.range);
            if (overlap.length) {
                NSRange local = NSMakeRange(overlap.location - content.location, overlap.length);
                [tokensByLine[index] addObject:[[SCESyntaxToken alloc] initWithRange:local kind:token.kind]];
            }
        }
    }
    BOOL changed = NO;
    for (NSUInteger index = 0; index < lineCount; index++) {
        NSUInteger line = lineRange.location + index;
        NSArray<SCESyntaxToken *> *localTokens = tokensByLine[index];
        NSArray<SCESyntaxToken *> *previous = _syntaxTokens[@(line)] ?: @[];
        if (![previous isEqualToArray:localTokens]) {
            [self discardLayoutPreservingGeometryForLine:line];
            changed = YES;
        }
        if (localTokens.count) {
            _syntaxTokens[@(line)] = [localTokens copy];
        } else {
            [_syntaxTokens removeObjectForKey:@(line)];
        }
    }
    return changed;
}

// Colors do not affect geometry, so the next layout reuses every measured fragment.
- (void)discardLayoutPreservingGeometryForLine:(NSUInteger)line {
    SCELineLayout *layout = _layouts[@(line)];
    SCELineLayoutPrefix *prefix = [layout prefixPreservingUTF16Length:layout.length];
    if (prefix) {
        _layoutPrefixes[@(line)] = prefix;
    }
    [_layouts removeObjectForKey:@(line)];
}

- (void)removeAllSyntaxTokens {
    for (NSNumber *key in _syntaxTokens) {
        [self discardLayoutPreservingGeometryForLine:key.unsignedIntegerValue];
    }
    [_syntaxTokens removeAllObjects];
}

@end
