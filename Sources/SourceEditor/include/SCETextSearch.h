#import <Foundation/Foundation.h>
#import "SCETextBuffer.h"

NS_ASSUME_NONNULL_BEGIN

/// Options that control how a search pattern matches document text.
typedef NS_OPTIONS(NSUInteger, SCETextSearchOptions) {
    /// Matches letters with the same case only. Searches ignore case by default.
    SCETextSearchOptionCaseSensitive = 1 << 0,
    /// Requires that a match neither starts nor ends inside a word. Word characters
    /// are letters, combining marks, numbers, and the underscore, matching the
    /// editor's double-click word selection.
    SCETextSearchOptionWholeWord = 1 << 1,
    /// Interprets the pattern as an ICU regular expression. The anchors ^ and $
    /// match at line boundaries, and the dot does not match line endings.
    SCETextSearchOptionRegularExpression = 1 << 2,
};

/// The default maximum number of matches an editor collects for one query.
FOUNDATION_EXPORT const NSUInteger SCETextSearchDefaultMaximumMatchCount;

/// An immutable description of a document search. Instances are thread-safe and
/// can search buffer snapshots on any queue.
@interface SCETextSearchQuery : NSObject <NSCopying>

- (instancetype)initWithPattern:(NSString *)pattern options:(SCETextSearchOptions)options NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly, copy) NSString *pattern;
@property (nonatomic, readonly) SCETextSearchOptions options;

/// Returns the non-empty matches in document order. The ranges count UTF-16 code
/// units and do not overlap. Collection stops after maximumCount matches, so a
/// result containing exactly maximumCount ranges may be incomplete. An empty
/// pattern produces no matches. Returns nil and sets error when the pattern is
/// not a valid regular expression.
///
/// This method materializes the buffer, which takes O(document length) time and
/// memory. Call it with a snapshot on a background queue for large documents.
- (nullable NSArray<NSValue *> *)rangesOfMatchesInBuffer:(SCETextBuffer *)buffer
                                            maximumCount:(NSUInteger)maximumCount
                                                   error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
