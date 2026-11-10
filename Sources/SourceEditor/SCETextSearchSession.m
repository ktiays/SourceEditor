#import "SCETextSearchSession.h"
#import "SCETextSearchMatching.h"

// Background chunks span about this many UTF-16 code units, rounded down to whole
// lines. A chunk always contains at least one line.
static const NSUInteger SCETextSearchChunkLength = 1 << 17;

// Unsearched text in the priority range or in edited lines is searched on the
// main thread, without a round trip through a background queue, while its total
// length is at most this many UTF-16 code units.
static const NSUInteger SCETextSearchSynchronousLength = 1 << 15;

NSUInteger SCEIndexOfFirstRangeStartingAtOrAfter(const NSRange *ranges, NSUInteger count, NSUInteger offset) {
    NSUInteger low = 0;
    NSUInteger high = count;
    while (low < high) {
        NSUInteger middle = low + (high - low) / 2;
        if (ranges[middle].location < offset) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    return low;
}

NSUInteger SCEIndexOfFirstRangeEndingAfter(const NSRange *ranges, NSUInteger count, NSUInteger offset) {
    NSUInteger low = 0;
    NSUInteger high = count;
    while (low < high) {
        NSUInteger middle = low + (high - low) / 2;
        if (NSMaxRange(ranges[middle]) <= offset) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    return low;
}

// Cancellation state shared between the main thread and background searches of
// one generation. Every edit starts a new generation.
@interface SCETextSearchCancellation : NSObject
@property (atomic, getter=isCancelled) BOOL cancelled;
@end

@implementation SCETextSearchCancellation
@end

@implementation SCETextSearchSession {
    SCETextBuffer *_buffer;
    // Packed NSRange values in document order.
    NSMutableData *_matches;
    // For queries that stay within lines: the lines whose matches are unknown.
    // Unsearched lines hold no matches.
    NSMutableIndexSet *_unsearchedLines;
    // Unsearched lines that background tasks of the current generation search.
    NSMutableIndexSet *_scheduledLines;
    BOOL _searchesWholeDocument;
    // For queries that can cross lines: whether the matches predate the text.
    BOOL _wholeDocumentStale;
    BOOL _wholeDocumentScheduled;
    BOOL _matchLimitReached;
    BOOL _invalidated;
    BOOL _backgroundSearchScheduled;
    BOOL _notificationScheduled;
    BOOL _hasChangedLines;
    NSRange _changedLineRange;
    NSUInteger _runningTaskCount;
    NSUInteger _maximumRunningTaskCount;
    SCETextSearchCancellation *_cancellation;
}

- (instancetype)initWithQuery:(SCETextSearchQuery *)query
                       buffer:(SCETextBuffer *)buffer
            priorityLineRange:(NSRange)priorityLineRange
                     delegate:(id<SCETextSearchSessionDelegate>)delegate {
    if (!(self = [super init])) {
        return nil;
    }
    _query = [query copy];
    _buffer = buffer;
    _delegate = delegate;
    _priorityLineRange = priorityLineRange;
    _matches = [NSMutableData data];
    _unsearchedLines = [NSMutableIndexSet indexSet];
    _scheduledLines = [NSMutableIndexSet indexSet];
    _cancellation = [[SCETextSearchCancellation alloc] init];
    // Leave one processor for the main thread.
    NSUInteger processors = NSProcessInfo.processInfo.activeProcessorCount;
    _maximumRunningTaskCount = MAX(1, MIN(8, processors > 1 ? processors - 1 : 1));
    if (!_query.pattern.length) {
        return self;
    }
    NSError *error = nil;
    if (![_query compiledRegularExpressionWithError:&error]) {
        _error = error;
        return self;
    }
    if (_query.canMatchAcrossLines) {
        _searchesWholeDocument = YES;
        _wholeDocumentStale = YES;
        if (buffer.lengthUTF16 <= SCETextSearchSynchronousLength) {
            [self searchWholeDocumentSynchronously];
        }
    } else {
        [_unsearchedLines addIndexesInRange:NSMakeRange(0, buffer.lineCount)];
        [self searchUnsearchedLinesInRange:priorityLineRange maximumLength:SCETextSearchSynchronousLength];
    }
    [self setNeedsBackgroundSearch];
    return self;
}

- (void)dealloc {
    _cancellation.cancelled = YES;
}

- (void)invalidate {
    _invalidated = YES;
    [self cancelBackgroundTasks];
}

// MARK: State

- (const NSRange *)matchRanges {
    return _matches.bytes;
}

- (NSUInteger)numberOfMatches {
    return _matches.length / sizeof(NSRange);
}

- (BOOL)hasUnsearchedText {
    return _searchesWholeDocument ? _wholeDocumentStale : _unsearchedLines.count > 0;
}

- (BOOL)isSearching {
    if (_invalidated || _error || !self.hasUnsearchedText) {
        return NO;
    }
    // A whole-document search replaces every match, so the limit does not stop it.
    return _searchesWholeDocument || self.numberOfMatches < SCETextSearchDefaultMaximumMatchCount;
}

- (BOOL)isTruncated {
    return _matchLimitReached || (!_searchesWholeDocument && self.hasUnsearchedText &&
                                  self.numberOfMatches >= SCETextSearchDefaultMaximumMatchCount);
}

- (void)setPriorityLineRange:(NSRange)priorityLineRange {
    _priorityLineRange = priorityLineRange;
    if (_invalidated || _error || _searchesWholeDocument) {
        return;
    }
    if ([self searchUnsearchedLinesInRange:priorityLineRange maximumLength:SCETextSearchSynchronousLength]) {
        [self setNeedsNotificationForLineRange:priorityLineRange];
    }
}

// MARK: Matching

- (NSRange)UTF16RangeOfLineRange:(NSRange)lines {
    NSUInteger start = [_buffer UTF16RangeOfLine:lines.location includingLineEnding:YES].location;
    NSUInteger end = NSMaxRange([_buffer UTF16RangeOfLine:NSMaxRange(lines) - 1 includingLineEnding:YES]);
    return NSMakeRange(start, end - start);
}

// Inserts the matches of lines, which must all be unsearched, and marks them searched.
- (void)insertMatchData:(NSData *)data
    intoUnsearchedLineRange:(NSRange)lines
                 UTF16Range:(NSRange)range
               maximumCount:(NSUInteger)maximumCount {
    NSUInteger index = SCEIndexOfFirstRangeStartingAtOrAfter(self.matchRanges, self.numberOfMatches, range.location);
    [_matches replaceBytesInRange:NSMakeRange(index * sizeof(NSRange), 0) withBytes:data.bytes length:data.length];
    [_unsearchedLines removeIndexesInRange:lines];
    if (data.length / sizeof(NSRange) >= maximumCount) {
        _matchLimitReached = YES;
    }
}

- (void)searchLineRangeSynchronously:(NSRange)lines {
    NSRange range = [self UTF16RangeOfLineRange:lines];
    NSData *data = [_query rangeDataOfMatchesInBuffer:_buffer
                                           UTF16Range:range
                                         maximumCount:SCETextSearchDefaultMaximumMatchCount
                                          isCancelled:nil
                                                error:NULL];
    [self insertMatchData:data ?: [NSData data]
        intoUnsearchedLineRange:lines
                     UTF16Range:range
                   maximumCount:SCETextSearchDefaultMaximumMatchCount];
}

// Searches the unsearched runs of lines in document order while their combined
// length stays within maximumLength. Returns whether any run was searched.
- (BOOL)searchUnsearchedLinesInRange:(NSRange)lines maximumLength:(NSUInteger)maximumLength {
    NSUInteger lineCount = _buffer.lineCount;
    if (lines.location >= lineCount || !lines.length || !_unsearchedLines.count) {
        return NO;
    }
    lines.length = MIN(lines.length, lineCount - lines.location);
    NSMutableArray<NSValue *> *runs = [NSMutableArray array];
    __block NSUInteger remainingLength = maximumLength;
    [_unsearchedLines enumerateRangesInRange:lines
                                     options:0
                                  usingBlock:^(NSRange run, BOOL *stop) {
                                      NSUInteger length = [self UTF16RangeOfLineRange:run].length;
                                      if (length > remainingLength) {
                                          *stop = YES;
                                          return;
                                      }
                                      remainingLength -= length;
                                      [runs addObject:[NSValue valueWithRange:run]];
                                  }];
    for (NSValue *run in runs) {
        [self searchLineRangeSynchronously:run.rangeValue];
    }
    return runs.count > 0;
}

- (void)searchWholeDocumentSynchronously {
    [self cancelBackgroundTasks];
    NSData *data = [_query rangeDataOfMatchesInBuffer:_buffer
                                           UTF16Range:NSMakeRange(0, _buffer.lengthUTF16)
                                         maximumCount:SCETextSearchDefaultMaximumMatchCount
                                          isCancelled:nil
                                                error:NULL];
    _matches = data ? [data mutableCopy] : [NSMutableData data];
    _wholeDocumentStale = NO;
    _matchLimitReached = self.numberOfMatches >= SCETextSearchDefaultMaximumMatchCount;
}

// Returns the unsearched lines from start to the end of its run in lines, limited
// to about SCETextSearchChunkLength UTF-16 code units.
- (NSRange)chunkOfLines:(NSIndexSet *)lines startingAtLine:(NSUInteger)start {
    __block NSUInteger runEnd = start + 1;
    [lines enumerateRangesInRange:NSMakeRange(start, _buffer.lineCount - start)
                          options:0
                       usingBlock:^(NSRange run, BOOL *stop) {
                           runEnd = NSMaxRange(run);
                           *stop = YES;
                       }];
    NSUInteger startOffset = [_buffer UTF16RangeOfLine:start includingLineEnding:YES].location;
    NSUInteger end = runEnd;
    if (_buffer.lengthUTF16 - startOffset > SCETextSearchChunkLength) {
        NSUInteger limit = [_buffer lineIndexForUTF16Offset:startOffset + SCETextSearchChunkLength];
        end = MIN(end, MAX(start + 1, limit));
    }
    return NSMakeRange(start, end - start);
}

// Returns the unsearched lines from the start of the run in lines that contains
// last through last, limited to about SCETextSearchChunkLength UTF-16 code units.
- (NSRange)chunkOfLines:(NSIndexSet *)lines endingAtLine:(NSUInteger)last {
    __block NSUInteger runStart = last;
    [lines enumerateRangesInRange:NSMakeRange(0, last + 1)
                          options:NSEnumerationReverse
                       usingBlock:^(NSRange run, BOOL *stop) {
                           runStart = run.location;
                           *stop = YES;
                       }];
    NSUInteger endOffset = NSMaxRange([_buffer UTF16RangeOfLine:last includingLineEnding:YES]);
    NSUInteger start = runStart;
    if (endOffset > SCETextSearchChunkLength) {
        NSUInteger limit = [_buffer lineIndexForUTF16Offset:endOffset - SCETextSearchChunkLength] + 1;
        start = MAX(start, MIN(last, limit));
    }
    return NSMakeRange(start, last - start + 1);
}

// MARK: Editing

- (void)removeMatchesInIndexRange:(NSRange)indexes shiftingFollowingMatchesBy:(NSInteger)delta {
    NSRange *matches = _matches.mutableBytes;
    NSUInteger count = self.numberOfMatches;
    for (NSUInteger index = NSMaxRange(indexes); index < count; index++) {
        matches[index].location = (NSUInteger)((NSInteger)matches[index].location + delta);
    }
    [_matches replaceBytesInRange:NSMakeRange(indexes.location * sizeof(NSRange), indexes.length * sizeof(NSRange))
                        withBytes:NULL
                           length:0];
}

- (void)updateForReplacementOfUTF16Range:(NSRange)range
                       replacementLength:(NSUInteger)replacementLength
                          previousBuffer:(SCETextBuffer *)previousBuffer {
    if (_invalidated || _error || !_query.pattern.length) {
        return;
    }
    [self cancelBackgroundTasks];
    NSInteger delta = (NSInteger)replacementLength - (NSInteger)range.length;
    const NSRange *matches = self.matchRanges;
    NSUInteger count = self.numberOfMatches;
    if (_searchesWholeDocument) {
        // Matches that intersect the replaced text are removed; the others stay
        // aligned with the text until the next whole-document search.
        NSUInteger first = SCEIndexOfFirstRangeEndingAfter(matches, count, range.location);
        NSUInteger last = SCEIndexOfFirstRangeStartingAtOrAfter(matches, count, NSMaxRange(range));
        [self removeMatchesInIndexRange:NSMakeRange(first, last - first) shiftingFollowingMatchesBy:delta];
        _wholeDocumentStale = YES;
        [self setNeedsBackgroundSearch];
        [self setNeedsNotificationForLineRange:NSMakeRange(0, 0)];
        return;
    }
    // Matches lie within lines, so only the edited lines need a new search.
    NSUInteger firstLine = [previousBuffer lineIndexForUTF16Offset:range.location];
    NSUInteger oldLastLine = [previousBuffer lineIndexForUTF16Offset:NSMaxRange(range)];
    NSUInteger newLastLine = [_buffer lineIndexForUTF16Offset:range.location + replacementLength];
    NSUInteger oldStart = [previousBuffer UTF16RangeOfLine:firstLine includingLineEnding:YES].location;
    NSUInteger oldEnd = NSMaxRange([previousBuffer UTF16RangeOfLine:oldLastLine includingLineEnding:YES]);
    NSUInteger first = SCEIndexOfFirstRangeStartingAtOrAfter(matches, count, oldStart);
    NSUInteger last = SCEIndexOfFirstRangeStartingAtOrAfter(matches, count, oldEnd);
    [self removeMatchesInIndexRange:NSMakeRange(first, last - first) shiftingFollowingMatchesBy:delta];
    [_unsearchedLines removeIndexesInRange:NSMakeRange(firstLine, oldLastLine - firstLine + 1)];
    [_unsearchedLines shiftIndexesStartingAtIndex:oldLastLine + 1 by:(NSInteger)newLastLine - (NSInteger)oldLastLine];
    NSRange editedLines = NSMakeRange(firstLine, newLastLine - firstLine + 1);
    [_unsearchedLines addIndexesInRange:editedLines];
    [self searchUnsearchedLinesInRange:editedLines maximumLength:SCETextSearchSynchronousLength];
    [self setNeedsBackgroundSearch];
    [self setNeedsNotificationForLineRange:editedLines];
}

// MARK: Background search

- (void)cancelBackgroundTasks {
    _cancellation.cancelled = YES;
    _cancellation = [[SCETextSearchCancellation alloc] init];
    [_scheduledLines removeAllIndexes];
    _wholeDocumentScheduled = NO;
}

// Starts background work after the current event, so that several edits in one
// event schedule their unsearched lines together.
- (void)setNeedsBackgroundSearch {
    if (_backgroundSearchScheduled || !self.isSearching) {
        return;
    }
    _backgroundSearchScheduled = YES;
    __weak SCETextSearchSession *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        SCETextSearchSession *session = weakSelf;
        if (session) {
            session->_backgroundSearchScheduled = NO;
            [session startBackgroundSearch];
        }
    });
}

// Returns the next unscheduled chunk: first in the priority range, then after
// it, then from the start of the document.
- (NSRange)nextBackgroundChunk {
    NSMutableIndexSet *candidates = [_unsearchedLines mutableCopy];
    [candidates removeIndexes:_scheduledLines];
    if (!candidates.count) {
        return NSMakeRange(NSNotFound, 0);
    }
    NSUInteger start = [candidates indexGreaterThanOrEqualToIndex:_priorityLineRange.location];
    if (start == NSNotFound) {
        start = candidates.firstIndex;
    }
    return [self chunkOfLines:candidates startingAtLine:start];
}

- (void)startBackgroundSearch {
    if (!self.isSearching) {
        return;
    }
    if (_searchesWholeDocument) {
        if (!_wholeDocumentScheduled) {
            _wholeDocumentScheduled = YES;
            [self dispatchSearchOfLineRange:NSMakeRange(0, _buffer.lineCount)
                                 UTF16Range:NSMakeRange(0, _buffer.lengthUTF16)
                              wholeDocument:YES];
        }
        return;
    }
    while (_runningTaskCount < _maximumRunningTaskCount &&
           self.numberOfMatches < SCETextSearchDefaultMaximumMatchCount) {
        NSRange lines = [self nextBackgroundChunk];
        if (lines.location == NSNotFound) {
            break;
        }
        [_scheduledLines addIndexesInRange:lines];
        [self dispatchSearchOfLineRange:lines UTF16Range:[self UTF16RangeOfLineRange:lines] wholeDocument:NO];
    }
}

- (void)dispatchSearchOfLineRange:(NSRange)lines UTF16Range:(NSRange)range wholeDocument:(BOOL)wholeDocument {
    // Copying a rope shares its immutable nodes, so a snapshot is constant time
    // and stays valid while the live buffer changes.
    SCETextBuffer *snapshot = [_buffer copy];
    SCETextSearchQuery *query = _query;
    SCETextSearchCancellation *cancellation = _cancellation;
    NSUInteger maximumCount = wholeDocument ? SCETextSearchDefaultMaximumMatchCount
                                            : SCETextSearchDefaultMaximumMatchCount - self.numberOfMatches;
    _runningTaskCount++;
    __weak SCETextSearchSession *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData *data = nil;
        @autoreleasepool {
            if (!cancellation.isCancelled) {
                data = [query rangeDataOfMatchesInBuffer:snapshot
                                              UTF16Range:range
                                            maximumCount:maximumCount
                                             isCancelled:^BOOL {
                                                 return cancellation.isCancelled;
                                             }
                                                   error:NULL];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf finishSearchOfLineRange:lines
                                   UTF16Range:range
                                    matchData:data
                                 maximumCount:maximumCount
                                 cancellation:cancellation
                                wholeDocument:wholeDocument];
        });
    });
}

- (void)finishSearchOfLineRange:(NSRange)lines
                     UTF16Range:(NSRange)range
                      matchData:(NSData *)data
                   maximumCount:(NSUInteger)maximumCount
                   cancellation:(SCETextSearchCancellation *)cancellation
                  wholeDocument:(BOOL)wholeDocument {
    _runningTaskCount--;
    if (_invalidated) {
        return;
    }
    // Every edit replaces the cancellation object, so a current object means the
    // snapshot still matches the live buffer.
    if (cancellation == _cancellation && data) {
        if (wholeDocument) {
            _matches = [data mutableCopy];
            _wholeDocumentStale = NO;
            _wholeDocumentScheduled = NO;
            _matchLimitReached = self.numberOfMatches >= maximumCount;
            [self setNeedsNotificationForLineRange:NSMakeRange(0, _buffer.lineCount)];
        } else {
            [_scheduledLines removeIndexesInRange:lines];
            // Navigation may have searched some of these lines synchronously; the
            // rest are scheduled again.
            if ([_unsearchedLines containsIndexesInRange:lines]) {
                [self insertMatchData:data intoUnsearchedLineRange:lines UTF16Range:range maximumCount:maximumCount];
                [self setNeedsNotificationForLineRange:lines];
            }
        }
    }
    [self startBackgroundSearch];
}

// MARK: Navigation

// Returns the index of the first match that starts at or after offset, or
// NSNotFound when no match follows. Sets determined to NO, without searching,
// when searching is NO and unsearched text could contain an earlier match.
- (NSUInteger)indexOfFirstMatchAtOrAfterUTF16Offset:(NSUInteger)offset
                                          searching:(BOOL)searching
                                         determined:(BOOL *)determined {
    *determined = YES;
    if (_error || !_query.pattern.length) {
        return NSNotFound;
    }
    if (_searchesWholeDocument) {
        if (_wholeDocumentStale) {
            if (!searching) {
                *determined = NO;
                return NSNotFound;
            }
            [self searchWholeDocumentSynchronously];
            [self setNeedsNotificationForLineRange:NSMakeRange(0, _buffer.lineCount)];
        }
        NSUInteger index = SCEIndexOfFirstRangeStartingAtOrAfter(self.matchRanges, self.numberOfMatches, offset);
        return index < self.numberOfMatches ? index : NSNotFound;
    }
    NSUInteger line = [_buffer lineIndexForUTF16Offset:offset];
    while (YES) {
        const NSRange *matches = self.matchRanges;
        NSUInteger count = self.numberOfMatches;
        NSUInteger index = SCEIndexOfFirstRangeStartingAtOrAfter(matches, count, offset);
        NSUInteger lastLine =
            index < count ? [_buffer lineIndexForUTF16Offset:matches[index].location] : _buffer.lineCount - 1;
        NSUInteger unsearched = [_unsearchedLines indexGreaterThanOrEqualToIndex:line];
        if (unsearched == NSNotFound || unsearched > lastLine) {
            return index < count ? index : NSNotFound;
        }
        if (!searching) {
            *determined = NO;
            return NSNotFound;
        }
        NSRange chunk = [self chunkOfLines:_unsearchedLines startingAtLine:unsearched];
        [self searchLineRangeSynchronously:chunk];
        [self setNeedsNotificationForLineRange:chunk];
    }
}

// Returns the index of the last match that ends at or before offset, or
// NSNotFound when no match precedes it.
- (NSUInteger)indexOfLastMatchEndingAtOrBeforeUTF16Offset:(NSUInteger)offset {
    if (_error || !_query.pattern.length) {
        return NSNotFound;
    }
    if (_searchesWholeDocument) {
        if (_wholeDocumentStale) {
            [self searchWholeDocumentSynchronously];
            [self setNeedsNotificationForLineRange:NSMakeRange(0, _buffer.lineCount)];
        }
        NSUInteger index = SCEIndexOfFirstRangeEndingAfter(self.matchRanges, self.numberOfMatches, offset);
        return index > 0 ? index - 1 : NSNotFound;
    }
    NSUInteger line = [_buffer lineIndexForUTF16Offset:offset];
    while (YES) {
        const NSRange *matches = self.matchRanges;
        NSUInteger index = SCEIndexOfFirstRangeEndingAfter(matches, self.numberOfMatches, offset);
        NSUInteger firstLine = index > 0 ? [_buffer lineIndexForUTF16Offset:matches[index - 1].location] : 0;
        NSUInteger unsearched = [_unsearchedLines indexLessThanOrEqualToIndex:line];
        if (unsearched == NSNotFound || unsearched < firstLine) {
            return index > 0 ? index - 1 : NSNotFound;
        }
        NSRange chunk = [self chunkOfLines:_unsearchedLines endingAtLine:unsearched];
        [self searchLineRangeSynchronously:chunk];
        [self setNeedsNotificationForLineRange:chunk];
    }
}

- (NSUInteger)indexOfNextMatchFromUTF16Offset:(NSUInteger)offset {
    if (_invalidated) {
        return NSNotFound;
    }
    offset = MIN(offset, _buffer.lengthUTF16);
    BOOL determined;
    NSUInteger index = [self indexOfFirstMatchAtOrAfterUTF16Offset:offset searching:YES determined:&determined];
    if (index == NSNotFound && offset > 0) {
        index = [self indexOfFirstMatchAtOrAfterUTF16Offset:0 searching:YES determined:&determined];
    }
    return index;
}

- (NSUInteger)indexOfPreviousMatchBeforeUTF16Offset:(NSUInteger)offset {
    if (_invalidated) {
        return NSNotFound;
    }
    offset = MIN(offset, _buffer.lengthUTF16);
    NSUInteger index = [self indexOfLastMatchEndingAtOrBeforeUTF16Offset:offset];
    if (index == NSNotFound && offset < _buffer.lengthUTF16) {
        index = [self indexOfLastMatchEndingAtOrBeforeUTF16Offset:_buffer.lengthUTF16];
    }
    return index;
}

- (BOOL)canLocateNextMatchFromUTF16OffsetWithoutSearching:(NSUInteger)offset {
    if (_invalidated) {
        return YES;
    }
    offset = MIN(offset, _buffer.lengthUTF16);
    BOOL determined;
    NSUInteger index = [self indexOfFirstMatchAtOrAfterUTF16Offset:offset searching:NO determined:&determined];
    if (!determined || index != NSNotFound || !offset) {
        return determined;
    }
    [self indexOfFirstMatchAtOrAfterUTF16Offset:0 searching:NO determined:&determined];
    return determined;
}

// MARK: Notification

- (void)setNeedsNotificationForLineRange:(NSRange)lines {
    if (lines.length) {
        _changedLineRange = _hasChangedLines ? NSUnionRange(_changedLineRange, lines) : lines;
        _hasChangedLines = YES;
    }
    if (_notificationScheduled) {
        return;
    }
    _notificationScheduled = YES;
    __weak SCETextSearchSession *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf postNotification];
    });
}

- (void)postNotification {
    _notificationScheduled = NO;
    NSRange lines = _hasChangedLines ? _changedLineRange : NSMakeRange(0, 0);
    _hasChangedLines = NO;
    if (!_invalidated) {
        [self.delegate textSearchSession:self didUpdateMatchesInLineRange:lines];
    }
}

@end
