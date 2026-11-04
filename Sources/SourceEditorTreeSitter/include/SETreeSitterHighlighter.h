#import <Foundation/Foundation.h>
@import SourceEditor;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, SETreeSitterLanguage) {
    SETreeSitterLanguageJSON,
    SETreeSitterLanguageJavaScript,
};

FOUNDATION_EXPORT NSErrorDomain const SETreeSitterErrorDomain;

/// Optional adapter. Owns one document's parser on a private serial queue.
/// It neither owns an editor nor chooses colors; use one instance per document.
@interface SETreeSitterHighlighter : NSObject <SESyntaxHighlighter>
- (nullable instancetype)initWithLanguage:(SETreeSitterLanguage)language
                                    error:(NSError *_Nullable *_Nullable)error NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) SETreeSitterLanguage language;
@end

NS_ASSUME_NONNULL_END
