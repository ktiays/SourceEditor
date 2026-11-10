#import "include/SCEEditorView.h"

NS_ASSUME_NONNULL_BEGIN

@interface SCEEditorView (SearchNavigation)

/// Returns whether the known matches already determine the match that
/// selectNextSearchMatch would select with the caret at offset, so that selecting
/// it does not search unsearched text on the main thread. Returns YES without a
/// query and when the known matches show that the document has no match.
- (BOOL)canSelectNextSearchMatchFromUTF16OffsetWithoutSearching:(NSUInteger)offset;

@end

NS_ASSUME_NONNULL_END
