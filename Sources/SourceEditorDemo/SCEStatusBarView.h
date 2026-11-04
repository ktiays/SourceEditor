#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT const CGFloat SCEStatusBarHeight;

typedef NSString *SCEStatusBarItem NS_TYPED_ENUM;
FOUNDATION_EXPORT SCEStatusBarItem const SCEStatusBarItemLine;
FOUNDATION_EXPORT SCEStatusBarItem const SCEStatusBarItemColumn;
FOUNDATION_EXPORT SCEStatusBarItem const SCEStatusBarItemLineCount;
FOUNDATION_EXPORT SCEStatusBarItem const SCEStatusBarItemLanguage;

@interface SCEStatusBarView : NSVisualEffectView

/// Items are displayed in this order, with the language item at the trailing edge.
/// Unknown and duplicate items are ignored. Defaults to all items.
@property (nonatomic, copy) NSArray<SCEStatusBarItem> *items;

/// Available language titles. An empty list hides the language item.
/// One title displays a fixed label; multiple titles display a pop-up button.
@property (nonatomic, copy) NSArray<NSString *> *languageTitles;
@property (nonatomic) NSUInteger selectedLanguageIndex;

/// Called after the user selects a different language in the pop-up button.
@property (nonatomic, copy, nullable) void (^languageSelectionHandler)(NSUInteger index);

/// Returns NO when no configured items are visible. Hosts should then hide the
/// status bar and remove its scroll insets.
@property (nonatomic, readonly) BOOL hasVisibleItems;

- (void)setLine:(NSUInteger)line column:(NSUInteger)column lineCount:(NSUInteger)lineCount;

@end

NS_ASSUME_NONNULL_END
