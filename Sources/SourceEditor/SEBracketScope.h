#import "include/SETextBuffer.h"

NS_ASSUME_NONNULL_BEGIN

/// Characters scanned in each direction before giving up. Bounds the work done
/// on every caret move, independent of the document length.
FOUNDATION_EXPORT const NSUInteger SEBracketScopeDefaultScanLimit;

/// Finds the innermost (), [] or {} pair enclosing `offset` whose brackets are
/// on lines that are at least two apart, so at least one line lies inside.
/// Each bracket kind is balanced independently, so a stray bracket of one kind
/// doesn't hide scopes of another. A bracket before `offset` belongs to the
/// text before the caret; a bracket at `offset` belongs to the text after it.
/// Returns the range from the opening bracket through the closing bracket,
/// or {NSNotFound, 0}. Brackets in strings and comments are counted too.
FOUNDATION_EXPORT NSRange SEEnclosingMultilineBracketRange(
    SETextBuffer *buffer, NSUInteger offset, NSUInteger scanLimit);

NS_ASSUME_NONNULL_END
