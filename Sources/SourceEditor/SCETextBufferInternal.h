#import "include/SCETextBuffer.h"

NS_ASSUME_NONNULL_BEGIN

@interface SCETextBuffer (StorageIdentity)

/// Compares immutable rope roots without reading text. Independently edited
/// snapshots may have equal document identifiers and revisions but different roots.
- (BOOL)hasSameStorageAsBuffer:(SCETextBuffer *)buffer;

@end

NS_ASSUME_NONNULL_END
