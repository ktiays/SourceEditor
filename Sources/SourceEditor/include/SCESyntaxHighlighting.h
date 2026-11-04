#import <Foundation/Foundation.h>
#import "SCETextBuffer.h"

NS_ASSUME_NONNULL_BEGIN

typedef NSString *SCESyntaxTokenKind NS_TYPED_EXTENSIBLE_ENUM;

FOUNDATION_EXPORT SCESyntaxTokenKind const SCESyntaxTokenComment;
FOUNDATION_EXPORT SCESyntaxTokenKind const SCESyntaxTokenString;
FOUNDATION_EXPORT SCESyntaxTokenKind const SCESyntaxTokenEscape;
FOUNDATION_EXPORT SCESyntaxTokenKind const SCESyntaxTokenNumber;
FOUNDATION_EXPORT SCESyntaxTokenKind const SCESyntaxTokenKeyword;
FOUNDATION_EXPORT SCESyntaxTokenKind const SCESyntaxTokenFunction;
FOUNDATION_EXPORT SCESyntaxTokenKind const SCESyntaxTokenType;
FOUNDATION_EXPORT SCESyntaxTokenKind const SCESyntaxTokenProperty;
FOUNDATION_EXPORT SCESyntaxTokenKind const SCESyntaxTokenVariable;
FOUNDATION_EXPORT SCESyntaxTokenKind const SCESyntaxTokenOperator;
FOUNDATION_EXPORT SCESyntaxTokenKind const SCESyntaxTokenPunctuation;

/// An immutable, engine-independent semantic range in document UTF-16 units.
@interface SCESyntaxToken : NSObject <NSCopying>
- (instancetype)initWithRange:(NSRange)range kind:(SCESyntaxTokenKind)kind;
@property (nonatomic, readonly) NSRange range;
@property (nonatomic, readonly, copy) SCESyntaxTokenKind kind;
@end

/// Coordinates describe the exact edit, including both sides of a replacement.
/// Columns count UTF-16 units from the start of the logical line, not glyphs.
@interface SCETextEdit : NSObject
- (instancetype)initWithRange:(NSRange)range
          insertedLengthUTF16:(NSUInteger)insertedLength
                 beforeBuffer:(SCETextBuffer *)beforeBuffer
                  afterBuffer:(SCETextBuffer *)afterBuffer;
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
/// outside coveredRange, such as a multiline comment crossing the viewport.
@interface SCESyntaxHighlightResult : NSObject
- (instancetype)initWithRevision:(NSUInteger)revision
                    coveredRange:(NSRange)range
                          tokens:(NSArray<SCESyntaxToken *> *)tokens;
@property (nonatomic, readonly) NSUInteger revision;
@property (nonatomic, readonly) NSRange coveredRange;
@property (nonatomic, readonly, copy) NSArray<SCESyntaxToken *> *tokens;
@end

typedef void (^SCESyntaxHighlightCompletion)(SCESyntaxHighlightResult *_Nullable result);

/// An optional highlighter called on the main thread with an independent rope snapshot.
/// Implementations must return promptly and perform parsing off the main thread.
/// A nil edit means a range-only request or a reset; incremental reuse is valid
/// only when the highlighter's revision matches edit.previousRevision.
/// Completions may use any queue. Superseded or canceled requests may be discarded.
/// A nil result reports that no highlight is available, such as after an aborted
/// parse; the editor keeps its current colors instead of clearing them. While a
/// request is pending, edited lines show the previous colors remapped to the
/// edited text.
@protocol SCESyntaxHighlighter <NSObject>
- (void)highlightBuffer:(SCETextBuffer *)snapshot
             UTF16Range:(NSRange)range
              afterEdit:(nullable SCETextEdit *)edit
             completion:(SCESyntaxHighlightCompletion)completion;

@optional
- (void)cancelPendingRequests;
@end

NS_ASSUME_NONNULL_END
