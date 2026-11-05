#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// An immutable pair of distinct, non-whitespace BMP characters. Surrogates
/// are not supported. Each character occupies one UTF-16 code unit.
@interface SCEBracketPair : NSObject <NSCopying>

- (instancetype)initWithOpeningCharacter:(unichar)openingCharacter
                        closingCharacter:(unichar)closingCharacter
                        expandsOnNewline:(BOOL)expandsOnNewline NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) unichar openingCharacter;
@property (nonatomic, readonly) unichar closingCharacter;
/// Whether Return after the opener indents one level and places an adjacent
/// closer on its own line. Does not enable insertion of a missing closer.
@property (nonatomic, readonly) BOOL expandsOnNewline;

@end

NS_ASSUME_NONNULL_END
