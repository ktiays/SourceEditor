#import <Foundation/Foundation.h>
#import "SCEBracketPair.h"
#import "SCELanguageContextProvider.h"

NS_ASSUME_NONNULL_BEGIN

/// Immutable editing rules, independent of syntax highlighting and parsers.
/// The configuration copies its pairs and retains its context provider. Access
/// configurations and providers on the main thread; copying shares the provider.
@interface SCELanguageConfiguration : NSObject <NSCopying>

/// Curly and square brackets, both with multiline expansion.
+ (instancetype)languageConfigurationForJSON;

/// Curly and square brackets with multiline expansion, and parentheses without
/// it. Strings, comments, template literals, and regular expressions are recognized
/// conservatively; uncertain syntax suppresses language-specific editing.
+ (instancetype)languageConfigurationForJavaScript;

/// Every opening and closing character must be unique across all pairs.
- (instancetype)initWithBracketPairs:(NSArray<SCEBracketPair *> *)bracketPairs
                     contextProvider:(id<SCELanguageContextProvider>)contextProvider NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly, copy) NSArray<SCEBracketPair *> *bracketPairs;

@end

NS_ASSUME_NONNULL_END
