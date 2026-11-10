#import "include/SCETextSearch.h"

NS_ASSUME_NONNULL_BEGIN

@interface SCETextSearchQuery (SCEMatchCollection)

/// YES when a match might contain a line feed or depend on text across a line
/// feed. The test is conservative: NO guarantees that every match lies within
/// one line and that searching whole lines independently, each with its line
/// ending, finds exactly the matches of a whole-document search. Literal
/// patterns without a line feed and regular expressions that cannot match a line
/// feed return NO. Regular expressions that use escapes, classes, or flags that
/// may match a line feed, or anchors for the whole input, return YES.
@property (nonatomic, readonly) BOOL canMatchAcrossLines;

/// Returns the compiled expression, or nil and the compilation error.
- (nullable NSRegularExpression *)compiledRegularExpressionWithError:(NSError **)error;

/// Returns NSRange values packed in document order. Returns nil with a nil error
/// when isCancelled reports YES during matching, and nil with an error when the
/// pattern is invalid. isCancelled is called on the calling queue.
- (nullable NSData *)rangeDataOfMatchesInString:(NSString *)string
                                   maximumCount:(NSUInteger)maximumCount
                                    isCancelled:(BOOL (^_Nullable)(void))isCancelled
                                          error:(NSError **)error;

/// Searches range of buffer as an independent string and returns NSRange values
/// in document coordinates, packed in document order. Reads only range from the
/// rope, so the cost depends on the range length rather than on the document.
/// Callers must start and end range at line boundaries, including the line
/// ending, when canMatchAcrossLines is NO, or search the whole document
/// otherwise. Thread-safe for buffer snapshots.
- (nullable NSData *)rangeDataOfMatchesInBuffer:(SCETextBuffer *)buffer
                                     UTF16Range:(NSRange)range
                                   maximumCount:(NSUInteger)maximumCount
                                    isCancelled:(BOOL (^_Nullable)(void))isCancelled
                                          error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
