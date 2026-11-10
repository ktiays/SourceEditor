#import "SCETextSearchMatching.h"

const NSUInteger SCETextSearchDefaultMaximumMatchCount = 100000;

// One code point that belongs to a word, consistent with the editor's word
// selection: letters, combining marks, numbers, and the underscore.
static NSString *const SCEWordCharacterClass = @"[\\p{L}\\p{M}\\p{N}_]";

// Returns whether an ICU regular expression might match a line feed, or might
// match differently when each line is searched as a separate string. Matching
// within single lines is equivalent when the expression cannot consume a line
// feed: line starts then behave like the start of the input for ^, \b, and
// lookbehind, and the searched text keeps each line's ending for $ and
// lookahead. The scan is conservative and may report YES for expressions that
// stay within lines, such as \p{L} or a negated class that excludes \n.
static BOOL SCERegularExpressionCanMatchAcrossLines(NSString *pattern) {
    NSUInteger length = pattern.length;
    for (NSUInteger index = 0; index < length; index++) {
        unichar character = [pattern characterAtIndex:index];
        if (character == '\n') {
            return YES;
        }
        if (character == '\\') {
            if (++index == length) {
                return YES;
            }
            // Escapes that may match a line feed (\n, \s, \v, \R, \W, \D, \H,
            // \X, \p, \P), that name arbitrary code points (\x, \u, \U, \N, \c,
            // \0), or that anchor to the whole input (\A, \Z, \z, \G).
            unichar escaped = [pattern characterAtIndex:index];
            if (escaped == '\n' || (escaped < 128 && strchr("nsvRWDHXpPxuUNc0AZzG", (char)escaped))) {
                return YES;
            }
        } else if (character == '[' && index + 1 < length) {
            // Negated classes and POSIX-style classes such as [:space:] may match
            // a line feed.
            unichar next = [pattern characterAtIndex:index + 1];
            if (next == '^' || next == ':') {
                return YES;
            }
        } else if (character == '(' && index + 1 < length && [pattern characterAtIndex:index + 1] == '?') {
            // Inline flags such as (?s) or (?is:...) can let the dot match a line feed.
            for (NSUInteger flag = index + 2; flag < length; flag++) {
                unichar letter = [pattern characterAtIndex:flag];
                if (letter == 's') {
                    return YES;
                }
                if (letter != '-' && !((letter >= 'a' && letter <= 'z') || (letter >= 'A' && letter <= 'Z'))) {
                    break;
                }
            }
        }
    }
    return NO;
}

@implementation SCETextSearchQuery {
    BOOL _canMatchAcrossLines;
    // Compiled lazily and reused; NSRegularExpression is thread-safe.
    NSRegularExpression *_regularExpression;
    NSError *_compilationError;
    dispatch_once_t _compilationOnce;
}

- (instancetype)initWithPattern:(NSString *)pattern options:(SCETextSearchOptions)options {
    if ((self = [super init])) {
        _pattern = [pattern copy] ?: @"";
        _options = options;
        // Word boundary lookarounds use word characters only, so whole-word
        // matching does not change whether a match can cross lines.
        _canMatchAcrossLines = options & SCETextSearchOptionRegularExpression
                                   ? SCERegularExpressionCanMatchAcrossLines(_pattern)
                                   : [_pattern rangeOfString:@"\n"].location != NSNotFound;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    return self;
}

- (BOOL)isEqual:(id)object {
    if (self == object) {
        return YES;
    }
    if (![object isKindOfClass:SCETextSearchQuery.class]) {
        return NO;
    }
    SCETextSearchQuery *other = object;
    return other.options == _options && [other.pattern isEqualToString:_pattern];
}

- (NSUInteger)hash {
    return _pattern.hash ^ _options;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p; pattern = \"%@\"; options = %lu>", self.class, self, _pattern,
                                      (unsigned long)_options];
}

- (NSRegularExpression *)compiledRegularExpressionWithError:(NSError **)error {
    dispatch_once(&_compilationOnce, ^{
        NSString *pattern = self->_options & SCETextSearchOptionRegularExpression
                                ? self->_pattern
                                : [NSRegularExpression escapedPatternForString:self->_pattern];
        if (self->_options & SCETextSearchOptionWholeWord) {
            pattern = [NSString
                stringWithFormat:@"(?<!%@)(?:%@)(?!%@)", SCEWordCharacterClass, pattern, SCEWordCharacterClass];
        }
        NSRegularExpressionOptions options = NSRegularExpressionAnchorsMatchLines;
        if (!(self->_options & SCETextSearchOptionCaseSensitive)) {
            options |= NSRegularExpressionCaseInsensitive;
        }
        NSError *compilationError = nil;
        self->_regularExpression = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                             options:options
                                                                               error:&compilationError];
        self->_compilationError = compilationError;
    });
    if (!_regularExpression && error) {
        *error = _compilationError;
    }
    return _regularExpression;
}

- (NSData *)rangeDataOfMatchesInString:(NSString *)string
                          maximumCount:(NSUInteger)maximumCount
                           isCancelled:(BOOL (^)(void))isCancelled
                                 error:(NSError **)error {
    if (error) {
        *error = nil;
    }
    NSMutableData *ranges = [NSMutableData data];
    if (!_pattern.length || !maximumCount) {
        return ranges;
    }
    NSRegularExpression *expression = [self compiledRegularExpressionWithError:error];
    if (!expression) {
        return nil;
    }
    __block BOOL cancelled = NO;
    __block NSUInteger count = 0;
    // Progress reports allow cancellation during long stretches without matches.
    [expression enumerateMatchesInString:string
                                 options:isCancelled ? NSMatchingReportProgress : 0
                                   range:NSMakeRange(0, string.length)
                              usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) {
                                  if (isCancelled && isCancelled()) {
                                      cancelled = YES;
                                      *stop = YES;
                                      return;
                                  }
                                  // Empty matches, such as a bare ^, have nothing to highlight or select.
                                  if (!result || !result.range.length) {
                                      return;
                                  }
                                  NSRange range = result.range;
                                  [ranges appendBytes:&range length:sizeof(range)];
                                  if (++count >= maximumCount) {
                                      *stop = YES;
                                  }
                              }];
    return cancelled ? nil : ranges;
}

- (BOOL)canMatchAcrossLines {
    return _canMatchAcrossLines;
}

- (NSData *)rangeDataOfMatchesInBuffer:(SCETextBuffer *)buffer
                            UTF16Range:(NSRange)range
                          maximumCount:(NSUInteger)maximumCount
                           isCancelled:(BOOL (^)(void))isCancelled
                                 error:(NSError **)error {
    // A contiguous copy lets the regular expression engine read the characters
    // directly instead of copying them from a non-contiguous string again.
    unichar *characters = malloc(MAX(1, range.length) * sizeof(unichar));
    if (!characters) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOMEM userInfo:nil];
        }
        return nil;
    }
    [buffer getUTF16Characters:characters range:range];
    NSString *text = [[NSString alloc] initWithCharactersNoCopy:characters length:range.length freeWhenDone:YES];
    NSData *data = [self rangeDataOfMatchesInString:text maximumCount:maximumCount isCancelled:isCancelled error:error];
    if (!data || !range.location) {
        return data;
    }
    NSMutableData *shifted = [data mutableCopy];
    NSRange *ranges = shifted.mutableBytes;
    NSUInteger count = shifted.length / sizeof(NSRange);
    for (NSUInteger index = 0; index < count; index++) {
        ranges[index].location += range.location;
    }
    return shifted;
}

- (NSArray<NSValue *> *)rangesOfMatchesInBuffer:(SCETextBuffer *)buffer
                                   maximumCount:(NSUInteger)maximumCount
                                          error:(NSError **)error {
    NSData *data = [self rangeDataOfMatchesInString:buffer.string
                                       maximumCount:maximumCount
                                        isCancelled:nil
                                              error:error];
    if (!data) {
        return nil;
    }
    const NSRange *ranges = data.bytes;
    NSUInteger count = data.length / sizeof(NSRange);
    NSMutableArray<NSValue *> *values = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger index = 0; index < count; index++) {
        [values addObject:[NSValue valueWithRange:ranges[index]]];
    }
    return values;
}

@end
