#import "include/SCETextBuffer.h"

NS_ASSUME_NONNULL_BEGIN

/// The maximum number of UTF-16 code units scanned in each direction.
/// Bounds the work for each caret movement independently of document length.
FOUNDATION_EXPORT const NSUInteger SCEBracketScopeDefaultScanLimit;

/// Finds the innermost (), [] or {} pair enclosing `offset` whose brackets are
/// on lines that are at least two apart, so at least one line lies inside.
/// Each bracket kind is balanced independently, so an unmatched bracket of one
/// kind does not hide scopes of another. A bracket before `offset` belongs to the
/// text before the caret; a bracket at `offset` belongs to the text after it.
/// Returns the range from the opening bracket through the closing bracket,
/// or {NSNotFound, 0}. Matching includes brackets in strings and comments.
FOUNDATION_EXPORT NSRange SCEEnclosingMultilineBracketRange(SCETextBuffer *buffer, NSUInteger offset,
                                                            NSUInteger scanLimit);

/// Finds the innermost multiline (), [] or {} pair that encloses all of
/// `range`: its opening bracket lies before range.location and its closing
/// bracket lies at or after NSMaxRange(range). A selected bracket therefore
/// belongs to the selection, not to an enclosing pair. An empty range behaves
/// like SCEEnclosingMultilineBracketRange at range.location. The scan reads at
/// most `scanLimit` UTF-16 code units before the range, and the range plus at
/// most `scanLimit` code units after it.
FOUNDATION_EXPORT NSRange SCEEnclosingMultilineBracketRangeForRange(SCETextBuffer *buffer, NSRange range,
                                                                    NSUInteger scanLimit);

NS_ASSUME_NONNULL_END
