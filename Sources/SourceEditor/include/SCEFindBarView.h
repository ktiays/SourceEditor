#import <AppKit/AppKit.h>
#import "SCETextSearch.h"

NS_ASSUME_NONNULL_BEGIN

@class SCEEditorView;

/// A floating find bar that searches an SCEEditorView incrementally.
///
/// On macOS 26 and later, the search field, match navigation buttons, and close
/// button are separate Liquid Glass shapes in one NSGlassEffectContainerView,
/// so they blend when they are close together. Earlier versions use
/// NSVisualEffectView backgrounds with the same layout.
///
/// The host positions the view, typically over the top trailing corner of the
/// editor's scroll view, and shows or hides it. The view sizes itself with Auto
/// Layout. Access the view on the main thread.
///
/// Keyboard behavior in the search field: Return selects the next match,
/// Shift-Return selects the previous match, and Escape ends the search.
@interface SCEFindBarView : NSView

/// The editor to search. The find bar sets the editor's searchQuery while searching.
@property (nonatomic, weak, nullable) SCEEditorView *editor;

/// The text in the search field. Setting it during a search updates the
/// editor's query and selects the match nearest the search origin, before or
/// after it: the fewest lines away, then the fewest UTF-16 code units away,
/// preferring the following match on a tie. Without a match, the caret returns
/// to the origin. The origin is the start of the editor's selection; it follows
/// every selection change except the find bar's own match selection, so
/// continued typing keeps searching near the original caret position.
@property (nonatomic, copy) NSString *searchString;

/// The match options shown by the option buttons in the search field.
@property (nonatomic) SCETextSearchOptions searchOptions;

/// YES between beginSearch and endSearch.
@property (nonatomic, readonly, getter=isSearching) BOOL searching;

/// Called after the user ends the search with Escape or the close button. The
/// host should hide the find bar. The find bar has already called endSearch.
@property (nonatomic, copy, nullable) void (^dismissalHandler)(void);

/// Applies the search string to the editor, records the selection start as the
/// origin for incremental matching, and focuses the search field with its text
/// selected. Call this after the find bar is visible in the editor's window.
- (void)beginSearch;

/// Clears the editor's search query and match highlights and returns keyboard
/// focus to the editor when the find bar contains the first responder. The
/// editor's selection, including a selected match, is preserved.
- (void)endSearch;

/// Selects the match after the editor's selection, wrapping to the first match.
- (IBAction)findNext:(nullable id)sender;

/// Selects the match before the editor's selection, wrapping to the last match.
- (IBAction)findPrevious:(nullable id)sender;

@end

NS_ASSUME_NONNULL_END
