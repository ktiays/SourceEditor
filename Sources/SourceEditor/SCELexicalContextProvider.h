#import "include/SCELanguageContextProvider.h"

NS_ASSUME_NONNULL_BEGIN

/// A main-thread lexer with revision-checked prefix checkpoints. Each lookup
/// reads at most 131,072 UTF-16 units and never materializes the document.
@interface SCELexicalContextProvider : NSObject <SCELanguageContextProvider>

- (instancetype)initWithJavaScriptEnabled:(BOOL)javaScriptEnabled NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

- (void)invalidateForReplacementOfUTF16Range:(NSRange)range
                              previousBuffer:(SCETextBuffer *)previousBuffer
                                 afterBuffer:(SCETextBuffer *)afterBuffer;

@end

NS_ASSUME_NONNULL_END
