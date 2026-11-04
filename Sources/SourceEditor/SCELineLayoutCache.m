#import "SCELineLayoutCache.h"

@interface SCELineLayout ()
- (instancetype)initWithText:(NSString *)text
                  attributes:(NSDictionary *)attributes
                      tokens:(NSArray<SCESyntaxToken *> *)tokens
                       theme:(SCESyntaxTheme *)theme
                  appearance:(nullable NSAppearance *)appearance;
@end

@implementation SCELineLayout {
    CTLineRef _line;
    NSString *_text;
    CGFloat _width;
}

- (instancetype)initWithText:(NSString *)text
                  attributes:(NSDictionary *)attributes
                      tokens:(NSArray<SCESyntaxToken *> *)tokens
                       theme:(SCESyntaxTheme *)theme
                  appearance:(NSAppearance *)appearance {
    if ((self = [super init])) {
        _text = [text copy];
        NSMutableAttributedString *attributed = [[NSMutableAttributedString alloc] initWithString:text
                                                                                       attributes:attributes];
        void (^applyColors)(void) = ^{
            for (SCESyntaxToken *token in tokens) {
                NSColor *color = [theme foregroundColorForKind:token.kind];
                id foreground = color ? (__bridge id)color.CGColor
                                      : attributes[(__bridge NSString *)kCTForegroundColorAttributeName];
                [attributed addAttribute:(__bridge NSString *)kCTForegroundColorAttributeName
                                   value:foreground
                                   range:token.range];
            }
        };
        if (appearance) {
            [appearance performAsCurrentDrawingAppearance:applyColors];
        } else {
            applyColors();
        }
        _line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attributed);
        _width = (CGFloat)CTLineGetTypographicBounds(_line, NULL, NULL, NULL);
    }
    return self;
}

- (void)dealloc {
    if (_line) {
        CFRelease(_line);
    }
}

- (CTLineRef)line {
    return _line;
}

- (NSString *)text {
    return _text;
}

- (CGFloat)width {
    return _width;
}

- (CGFloat)xForUTF16Index:(NSUInteger)index {
    return CTLineGetOffsetForStringIndex(_line, (CFIndex)MIN(index, _text.length), NULL);
}

- (NSUInteger)UTF16IndexForX:(CGFloat)x {
    if (!_text.length) {
        return 0;
    }
    CFIndex raw = CTLineGetStringIndexForPosition(_line, CGPointMake(x, 0));
    if (raw == kCFNotFound) {
        return 0;
    }
    NSUInteger index = MIN((NSUInteger)MAX(0, raw), _text.length);
    if (index == _text.length) {
        return index;
    }
    NSRange cluster = [_text rangeOfComposedCharacterSequenceAtIndex:index];
    if (index == cluster.location) {
        return index;
    }
    CGFloat before = [self xForUTF16Index:cluster.location];
    CGFloat after = [self xForUTF16Index:NSMaxRange(cluster)];
    return fabs(x - before) <= fabs(x - after) ? cluster.location : NSMaxRange(cluster);
}

- (NSArray<NSValue *> *)selectionRectsForUTF16Range:(NSRange)range height:(CGFloat)height {
    if (!range.length) {
        return @[];
    }
    NSMutableArray<NSValue *> *rects = [NSMutableArray array];
    for (id runObject in (__bridge NSArray *)CTLineGetGlyphRuns(_line)) {
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
            [rects addObject:[NSValue valueWithRect:NSMakeRect(low, 0, MAX(1, high - low), height)]];
        }
    }
    // Font fallback, tabs and shaping can split one continuous visual selection
    // into several runs. Merge touching spans before rendering while preserving
    // unselected gaps in a partially selected bidirectional line.
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

@end

@implementation SCELineLayoutCache {
    SCETextBuffer *_buffer;
    NSMutableDictionary<NSNumber *, SCELineLayout *> *_layouts;
    NSMutableDictionary<NSNumber *, NSArray<SCESyntaxToken *> *> *_syntaxTokens;
    NSDictionary *_attributes;
    NSUInteger _totalLayoutBuildCount;
}

- (instancetype)initWithBuffer:(SCETextBuffer *)buffer font:(NSFont *)font {
    if ((self = [super init])) {
        _buffer = buffer;
        _font = [font copy];
        _textColor = NSColor.textColor;
        _tabWidth = 4;
        _layouts = [NSMutableDictionary dictionary];
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
    _attributes = nil;
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
        _attributes = @{
            (__bridge NSString *)kCTFontAttributeName : _font,
            (__bridge NSString *)kCTForegroundColorAttributeName : (__bridge id)_textColor.CGColor,
            (__bridge NSString *)kCTLigatureAttributeName : @0,
            (__bridge NSString *)kCTParagraphStyleAttributeName : (__bridge id)paragraph,
        };
        CFRelease(paragraph);
        CFRelease(stops);
    }
    return _attributes;
}

- (SCELineLayout *)layoutForLineAtIndex:(NSUInteger)lineIndex {
    SCELineLayout *layout = _layouts[@(lineIndex)];
    if (!layout) {
        NSString *text = [_buffer substringWithUTF16Range:[_buffer UTF16RangeOfLine:lineIndex includingLineEnding:NO]];
        layout = [[SCELineLayout alloc] initWithText:text
                                          attributes:self.attributes
                                              tokens:_syntaxTokens[@(lineIndex)] ?: @[]
                                               theme:_syntaxTheme
                                          appearance:_appearance];
        _layouts[@(lineIndex)] = layout;
        _totalLayoutBuildCount++;
    }
    return layout;
}

- (void)invalidateLinesInRange:(NSRange)oldLineRange lineDelta:(NSInteger)delta {
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
    NSMutableDictionary *updatedTokens = [NSMutableDictionary dictionaryWithCapacity:_syntaxTokens.count];
    [_syntaxTokens enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, NSArray<SCESyntaxToken *> *tokens, BOOL *stop) {
        NSUInteger index = key.unsignedIntegerValue;
        if (index < oldLineRange.location) {
            updatedTokens[key] = tokens;
        } else if (index >= NSMaxRange(oldLineRange)) {
            updatedTokens[@((NSUInteger)((NSInteger)index + delta))] = tokens;
        }
    }];
    _syntaxTokens = updatedTokens;
}

- (void)retainLinesInRange:(NSRange)range {
    for (NSNumber *key in [_layouts.allKeys copy]) {
        if (!NSLocationInRange(key.unsignedIntegerValue, range)) {
            [_layouts removeObjectForKey:key];
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
            [_layouts removeObjectForKey:@(line)];
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

- (void)removeAllSyntaxTokens {
    for (NSNumber *key in _syntaxTokens) {
        [_layouts removeObjectForKey:key];
    }
    [_syntaxTokens removeAllObjects];
}

@end
