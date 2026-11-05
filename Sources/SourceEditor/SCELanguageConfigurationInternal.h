#import "include/SCELanguageConfiguration.h"

NS_ASSUME_NONNULL_BEGIN

@interface SCELanguageConfiguration (Editing)

- (SCELanguageContext)contextAtUTF16Offset:(NSUInteger)offset inBuffer:(SCETextBuffer *)buffer;

/// Preserves only lexical checkpoints before the edit in the built-in provider.
- (void)invalidateContextForReplacementOfUTF16Range:(NSRange)range
                                     previousBuffer:(SCETextBuffer *)previousBuffer
                                        afterBuffer:(SCETextBuffer *)afterBuffer;

@end

NS_ASSUME_NONNULL_END
