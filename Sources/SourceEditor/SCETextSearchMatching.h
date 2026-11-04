#import "include/SCETextSearch.h"

NS_ASSUME_NONNULL_BEGIN

@interface SCETextSearchQuery (SCEMatchCollection)

/// Returns NSRange values packed in document order. Returns nil with a nil error
/// when isCancelled reports YES during matching, and nil with an error when the
/// pattern is invalid. isCancelled is called on the calling queue.
- (nullable NSData *)rangeDataOfMatchesInString:(NSString *)string
                                   maximumCount:(NSUInteger)maximumCount
                                    isCancelled:(BOOL (^_Nullable)(void))isCancelled
                                          error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
