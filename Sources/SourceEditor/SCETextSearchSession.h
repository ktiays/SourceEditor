#import <Foundation/Foundation.h>
#import "include/SCETextBuffer.h"
#import "include/SCETextSearch.h"

NS_ASSUME_NONNULL_BEGIN

@class SCETextSearchSession;

/// Returns the index of the first range whose location is at least offset.
/// ranges must be sorted and non-overlapping.
FOUNDATION_EXPORT NSUInteger SCEIndexOfFirstRangeStartingAtOrAfter(const NSRange *ranges, NSUInteger count,
                                                                   NSUInteger offset);

/// Returns the index of the first range that ends after offset. Sorted,
/// non-overlapping ranges also have increasing end offsets.
FOUNDATION_EXPORT NSUInteger SCEIndexOfFirstRangeEndingAfter(const NSRange *ranges, NSUInteger count,
                                                             NSUInteger offset);

@protocol SCETextSearchSessionDelegate <NSObject>

/// Called on the main thread, at most once per main queue turn, after matches or
/// the search state change. lineRange contains every line whose matches changed,
/// in current line indices, and has zero length when only the state changed.
- (void)textSearchSession:(SCETextSearchSession *)session didUpdateMatchesInLineRange:(NSRange)lineRange;

@end

/// Maintains the matches of one query in an editable document, searching the
/// text a part at a time in order of priority instead of all at once.
///
/// When the query cannot match across lines, the session tracks which lines are
/// still unsearched. Short unsearched ranges in the priority range, usually the
/// viewport, are searched synchronously so their matches appear immediately; the
/// remaining lines are searched in chunks on concurrent background queues, from
/// the priority range forward and then from the start of the document. An edit
/// removes the matches of the edited lines, moves later matches with the text,
/// and searches the edited lines again; other lines keep their results. Moving
/// to the next or previous match searches only the unsearched lines between the
/// starting offset and the match. Chunks read their text from rope snapshots, so
/// the whole document is never materialized.
///
/// Queries that can match across lines are searched as a whole document on a
/// background queue. After an edit, unaffected matches move with the text until
/// the next whole-document search replaces them.
///
/// Background searching stops collecting once SCETextSearchDefaultMaximumMatchCount
/// matches are known. Edits and navigation still search the lines they need.
///
/// Use on the main thread. Offsets count UTF-16 code units and lines are
/// zero-based logical line indices of the buffer passed to the initializer, which
/// the owner edits only through calls followed by
/// updateForReplacementOfUTF16Range:replacementLength:previousBuffer:.
@interface SCETextSearchSession : NSObject

/// Compiles the query and searches the priority range synchronously when it is
/// short. buffer is the live document buffer, not a snapshot.
- (instancetype)initWithQuery:(SCETextSearchQuery *)query
                       buffer:(SCETextBuffer *)buffer
            priorityLineRange:(NSRange)priorityLineRange
                     delegate:(nullable id<SCETextSearchSessionDelegate>)delegate NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly, copy) SCETextSearchQuery *query;
@property (nonatomic, readonly, weak, nullable) id<SCETextSearchSessionDelegate> delegate;
/// The pattern compilation error, or nil.
@property (nonatomic, readonly, nullable) NSError *error;
/// The known matches in document order. Valid until the session changes.
@property (nonatomic, readonly) const NSRange *matchRanges NS_RETURNS_INNER_POINTER;
@property (nonatomic, readonly) NSUInteger numberOfMatches;
/// YES while unsearched text remains and searching continues in the background.
@property (nonatomic, readonly, getter=isSearching) BOOL searching;
/// YES when matches may be missing because the match limit stopped searching.
@property (nonatomic, readonly, getter=isTruncated) BOOL truncated;

/// The lines searched first, normally the viewport. Setting it synchronously
/// searches the unsearched lines in the range when their total length is short.
@property (nonatomic) NSRange priorityLineRange;

/// Updates the matches after the live buffer replaced range of previousBuffer, a
/// snapshot taken before the edit, with replacementLength UTF-16 code units.
- (void)updateForReplacementOfUTF16Range:(NSRange)range
                       replacementLength:(NSUInteger)replacementLength
                          previousBuffer:(SCETextBuffer *)previousBuffer;

/// Returns the index of the first match that starts at or after offset, wrapping
/// to the first match, or NSNotFound when the document has no match. Searches
/// unsearched text synchronously, but only as far as needed to determine the match.
- (NSUInteger)indexOfNextMatchFromUTF16Offset:(NSUInteger)offset;

/// Returns the index of the last match that ends at or before offset, wrapping to
/// the last match, or NSNotFound when the document has no match. Searches
/// unsearched text synchronously, but only as far as needed to determine the match.
- (NSUInteger)indexOfPreviousMatchBeforeUTF16Offset:(NSUInteger)offset;

/// Returns the index of the match nearest offset: the fewest lines away, then the
/// fewest UTF-16 code units away, preferring the following match on a tie. A
/// match that contains offset is nearest. Searches unsearched lines around
/// offset synchronously, widening outward, at most maximumLength UTF-16 code
/// units in whole lines; pass NSUIntegerMax for no limit. Returns NSNotFound when
/// the document has no match. Sets determined to NO, and returns NSNotFound, when
/// unsearched text beyond the limit could contain a nearer match.
- (NSUInteger)indexOfMatchNearestUTF16Offset:(NSUInteger)offset
                  searchingAtMostUTF16Length:(NSUInteger)maximumLength
                                  determined:(BOOL *)determined;

/// Cancels background work. The session no longer changes or notifies its delegate.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
