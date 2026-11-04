#import <Foundation/Foundation.h>
@import SourceEditor;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, SCETreeSitterLanguage) {
    SCETreeSitterLanguageJSON,
};

FOUNDATION_EXPORT NSErrorDomain const SCETreeSitterErrorDomain;

/// A syntax highlighter that owns one document's parser on a private serial queue.
/// The editor supplies presentation colors. Use one highlighter per document.
@interface SCETreeSitterHighlighter : NSObject <SCESyntaxHighlighter>
- (nullable instancetype)initWithLanguage:(SCETreeSitterLanguage)language
                                    error:(NSError *_Nullable *_Nullable)error NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) SCETreeSitterLanguage language;
@end

NS_ASSUME_NONNULL_END
