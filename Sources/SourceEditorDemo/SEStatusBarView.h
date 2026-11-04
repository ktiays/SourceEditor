#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT const CGFloat SEStatusBarHeight;

typedef NSString *SEStatusBarItem NS_TYPED_ENUM;
FOUNDATION_EXPORT SEStatusBarItem const SEStatusBarItemLine;
FOUNDATION_EXPORT SEStatusBarItem const SEStatusBarItemColumn;
FOUNDATION_EXPORT SEStatusBarItem const SEStatusBarItemLineCount;
FOUNDATION_EXPORT SEStatusBarItem const SEStatusBarItemLanguage;

@interface SEStatusBarView : NSVisualEffectView

// Shown in this order. The language item is aligned to the trailing edge.
// Unknown and duplicate items are ignored. Defaults to all items.
@property (nonatomic, copy) NSArray<SEStatusBarItem> *items;

// The only languages the user can choose. Empty hides the language item;
// one title shows a fixed label that isn't clickable; more show a pop-up.
@property (nonatomic, copy) NSArray<NSString *> *languageTitles;
@property (nonatomic) NSUInteger selectedLanguageIndex;

// Called after the user picks a different language in the pop-up.
@property (nonatomic, copy, nullable) void (^languageSelectionHandler)(NSUInteger index);

// NO when the configuration leaves nothing to show; hosts should hide the bar
// and drop its scroll insets.
@property (nonatomic, readonly) BOOL hasVisibleItems;

- (void)setLine:(NSUInteger)line column:(NSUInteger)column lineCount:(NSUInteger)lineCount;

@end

NS_ASSUME_NONNULL_END
