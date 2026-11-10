#import "include/SCEEditorView.h"

NS_ASSUME_NONNULL_BEGIN

@interface SCEEditorView (SearchNavigation)

/// Returns whether the match selectSearchMatchNearestUTF16Offset: would select is
/// known after searching unsearched lines around offset synchronously, at most
/// maximumLength UTF-16 code units in whole lines, so that selecting it does not
/// search further on the main thread. Returns YES without a query and when the
/// known matches show that the document has no match. Pass 0 to search nothing.
- (BOOL)locateSearchMatchNearestUTF16Offset:(NSUInteger)offset searchingAtMostUTF16Length:(NSUInteger)maximumLength;

/// Selects and scrolls to the match nearest offset: the fewest lines away, then
/// the fewest UTF-16 code units away, preferring the following match on a tie. A
/// match that contains offset is nearest. Returns NO and keeps the selection when
/// there is no match.
- (BOOL)selectSearchMatchNearestUTF16Offset:(NSUInteger)offset;

@end

NS_ASSUME_NONNULL_END
