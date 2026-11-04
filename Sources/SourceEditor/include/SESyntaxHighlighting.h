#import <Foundation/Foundation.h>
#import "SETextBuffer.h"

NS_ASSUME_NONNULL_BEGIN

typedef NSString *SESyntaxTokenKind NS_TYPED_EXTENSIBLE_ENUM;

FOUNDATION_EXPORT SESyntaxTokenKind const SESyntaxTokenComment;
FOUNDATION_EXPORT SESyntaxTokenKind const SESyntaxTokenString;
FOUNDATION_EXPORT SESyntaxTokenKind const SESyntaxTokenEscape;
FOUNDATION_EXPORT SESyntaxTokenKind const SESyntaxTokenNumber;
FOUNDATION_EXPORT SESyntaxTokenKind const SESyntaxTokenKeyword;
FOUNDATION_EXPORT SESyntaxTokenKind const SESyntaxTokenFunction;
FOUNDATION_EXPORT SESyntaxTokenKind const SESyntaxTokenType;
FOUNDATION_EXPORT SESyntaxTokenKind const SESyntaxTokenProperty;
FOUNDATION_EXPORT SESyntaxTokenKind const SESyntaxTokenVariable;
FOUNDATION_EXPORT SESyntaxTokenKind const SESyntaxTokenOperator;
FOUNDATION_EXPORT SESyntaxTokenKind const SESyntaxTokenPunctuation;

/// An immutable, engine-independent semantic range in document UTF-16 units.
@interface SESyntaxToken : NSObject <NSCopying>
- (instancetype)initWithRange:(NSRange)range kind:(SESyntaxTokenKind)kind;
@property (nonatomic, readonly) NSRange range;
@property (nonatomic, readonly, copy) SESyntaxTokenKind kind;
@end

/// Coordinates describe the exact edit, including both sides of a replacement.
/// Columns count UTF-16 units from the start of the logical line, not glyphs.
@interface SETextEdit : NSObject
- (instancetype)initWithRange:(NSRange)range
          insertedLengthUTF16:(NSUInteger)insertedLength
                       before:(SETextBuffer *)before
                        after:(SETextBuffer *)after;
@property (nonatomic, readonly) NSRange rangeBeforeEdit;
@property (nonatomic, readonly) NSUInteger insertedLengthUTF16;
@property (nonatomic, readonly) NSUInteger previousRevision;
@property (nonatomic, readonly) NSUInteger revision;
@property (nonatomic, readonly) NSUInteger startLine;
@property (nonatomic, readonly) NSUInteger startColumnUTF16;
@property (nonatomic, readonly) NSUInteger oldEndLine;
@property (nonatomic, readonly) NSUInteger oldEndColumnUTF16;
@property (nonatomic, readonly) NSUInteger newEndLine;
@property (nonatomic, readonly) NSUInteger newEndColumnUTF16;
@end

/// Tokens may overlap; later tokens override earlier ones. Tokens can extend
/// outside coveredRange (e.g. a multiline comment crossing the viewport).
@interface SESyntaxHighlightResult : NSObject
- (instancetype)initWithRevision:(NSUInteger)revision
                    coveredRange:(NSRange)range
                          tokens:(NSArray<SESyntaxToken *> *)tokens;
@property (nonatomic, readonly) NSUInteger revision;
@property (nonatomic, readonly) NSRange coveredRange;
@property (nonatomic, readonly, copy) NSArray<SESyntaxToken *> *tokens;
@end

typedef void (^SESyntaxHighlightCompletion)(SESyntaxHighlightResult *_Nullable result);

/// Optional service, called on the main thread with an independent Rope snapshot.
/// Implementations must return quickly and do expensive work off the main thread.
/// A nil edit means a range-only request or a reset; incremental reuse is valid
/// only when the provider's revision matches edit.previousRevision.
/// Completions may use any queue. Superseded/cancelled requests may be discarded.
@protocol SESyntaxHighlighter <NSObject>
- (void)highlightBuffer:(SETextBuffer *)snapshot
             UTF16Range:(NSRange)range
              afterEdit:(nullable SETextEdit *)edit
             completion:(SESyntaxHighlightCompletion)completion;

@optional
- (void)cancelPendingRequests;
@end

NS_ASSUME_NONNULL_END
