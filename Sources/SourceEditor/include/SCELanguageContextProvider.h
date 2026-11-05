#import <Foundation/Foundation.h>
#import "SCETextBuffer.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, SCELanguageContext) {
    SCELanguageContextUnknown,
    SCELanguageContextCode,
    /// Includes template text and regular-expression literal contents.
    SCELanguageContextString,
    SCELanguageContextComment,
};

/// Classifies an insertion position using the text before that position.
/// Called synchronously on the main thread with an independent buffer snapshot.
/// Return promptly, never mutate the snapshot, and return Unknown when current
/// context is unavailable. Asynchronous highlight tokens may be out of date.
/// Providers may serve multiple documents; caches must distinguish snapshot
/// contents, including independently edited copies of the same document.
@protocol SCELanguageContextProvider <NSObject>

- (SCELanguageContext)contextAtUTF16Offset:(NSUInteger)offset inBuffer:(SCETextBuffer *)snapshot;

@end

NS_ASSUME_NONNULL_END
