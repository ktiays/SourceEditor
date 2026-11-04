#import "SCETextSearchMatching.h"

const NSUInteger SCETextSearchDefaultMaximumMatchCount = 100000;

// One code point that belongs to a word, consistent with the editor's word
// selection: letters, combining marks, numbers, and the underscore.
static NSString *const SCEWordCharacterClass = @"[\\p{L}\\p{M}\\p{N}_]";

@implementation SCETextSearchQuery {
    // Compiled lazily and reused; NSRegularExpression is thread-safe.
    NSRegularExpression *_regularExpression;
    NSError *_compilationError;
    dispatch_once_t _compilationOnce;
}

- (instancetype)initWithPattern:(NSString *)pattern options:(SCETextSearchOptions)options {
    if ((self = [super init])) {
        _pattern = [pattern copy] ?: @"";
        _options = options;
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
