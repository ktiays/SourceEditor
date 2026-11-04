#import "SCEStatusBarView.h"

const CGFloat SCEStatusBarHeight = 32;

SCEStatusBarItem const SCEStatusBarItemLine = @"line";
SCEStatusBarItem const SCEStatusBarItemColumn = @"column";
SCEStatusBarItem const SCEStatusBarItemLineCount = @"lineCount";
SCEStatusBarItem const SCEStatusBarItemLanguage = @"language";

@interface SCEStatusBarView ()

@property (nonatomic, strong) NSStackView *stack;
@property (nonatomic, strong) NSTextField *lineLabel;
@property (nonatomic, strong) NSTextField *columnLabel;
@property (nonatomic, strong) NSTextField *lineCountLabel;
@property (nonatomic, strong) NSPopUpButton *languageButton;
@property (nonatomic, strong) NSTextField *languageLabel;

@end

@implementation SCEStatusBarView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) {
        return nil;
    }

    self.material = NSVisualEffectMaterialHeaderView;
    self.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    self.state = NSVisualEffectStateFollowsWindowActiveState;

    self.lineLabel = [self makeLabelWithToolTip:@"Cursor line"];
    self.columnLabel = [self makeLabelWithToolTip:@"Cursor column"];
    self.lineCountLabel = [self makeLabelWithToolTip:@"Total lines"];
    self.languageButton = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.languageButton.bordered = NO;
    self.languageButton.controlSize = NSControlSizeSmall;
    self.languageButton.font = [NSFont systemFontOfSize:11];
    self.languageButton.toolTip = @"Change syntax language";
    self.languageButton.target = self;
    self.languageButton.action = @selector(languageButtonChanged:);
    [self.languageButton setAccessibilityLabel:@"Syntax language"];
    [self.languageButton setContentHuggingPriority:NSLayoutPriorityRequired
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.languageButton setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                                  forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.languageLabel = [self makeLabelWithToolTip:@"Syntax language"];
    self.languageLabel.font = [NSFont systemFontOfSize:11];
    [self.languageLabel setAccessibilityLabel:@"Syntax language"];

    self.stack = [[NSStackView alloc] init];
    self.stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    self.stack.alignment = NSLayoutAttributeCenterY;
    self.stack.spacing = 10;
    self.stack.detachesHiddenViews = NO;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:self.stack];
    [NSLayoutConstraint activateConstraints:@[
        [self.stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
        [self.stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
        [self.stack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];

    _items = @[ SCEStatusBarItemLine, SCEStatusBarItemColumn, SCEStatusBarItemLineCount, SCEStatusBarItemLanguage ];
    _languageTitles = @[];
    [self rebuildItems];
    [self setLine:1 column:1 lineCount:1];
    return self;
}

- (NSTextField *)makeLabelWithToolTip:(NSString *)toolTip {
    NSTextField *label = [NSTextField labelWithString:@""];
    label.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    label.textColor = NSColor.secondaryLabelColor;
    label.toolTip = toolTip;
    [label setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
    return label;
}

- (NSView *)makeSeparator {
    NSBox *separator = [[NSBox alloc] init];
    separator.boxType = NSBoxSeparator;
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [separator.widthAnchor constraintEqualToConstant:1],
        [separator.heightAnchor constraintEqualToConstant:12],
    ]];
    [separator setAccessibilityElement:NO];
    return separator;
}

- (void)setItems:(NSArray<SCEStatusBarItem> *)items {
    _items = [items copy];
    [self rebuildItems];
}

- (void)setLanguageTitles:(NSArray<NSString *> *)languageTitles {
    _languageTitles = [languageTitles copy];
    [self.languageButton removeAllItems];
    [self.languageButton addItemsWithTitles:_languageTitles];
    if (_selectedLanguageIndex >= _languageTitles.count) {
        _selectedLanguageIndex = 0;
    }
    [self updateLanguageSelection];
    [self rebuildItems];
}

- (void)setSelectedLanguageIndex:(NSUInteger)selectedLanguageIndex {
    _selectedLanguageIndex = selectedLanguageIndex < self.languageTitles.count ? selectedLanguageIndex : 0;
    [self updateLanguageSelection];
}

- (void)updateLanguageSelection {
    if (self.languageTitles.count == 0) {
        self.languageLabel.stringValue = @"";
        return;
    }
    [self.languageButton selectItemAtIndex:self.selectedLanguageIndex];
    self.languageLabel.stringValue = self.languageTitles[self.selectedLanguageIndex];
}

- (void)languageButtonChanged:(NSPopUpButton *)sender {
    NSInteger index = sender.indexOfSelectedItem;
    if (index < 0 || (NSUInteger)index == self.selectedLanguageIndex) {
        return;
    }
    _selectedLanguageIndex = index;
    [self updateLanguageSelection];
    if (self.languageSelectionHandler) {
        self.languageSelectionHandler(index);
    }
}

- (nullable NSView *)viewForItem:(SCEStatusBarItem)item {
    if ([item isEqualToString:SCEStatusBarItemLine]) {
        return self.lineLabel;
    }
    if ([item isEqualToString:SCEStatusBarItemColumn]) {
        return self.columnLabel;
    }
    if ([item isEqualToString:SCEStatusBarItemLineCount]) {
        return self.lineCountLabel;
    }
    if ([item isEqualToString:SCEStatusBarItemLanguage]) {
        if (self.languageTitles.count == 0) {
            return nil;
        }
        return self.languageTitles.count == 1 ? self.languageLabel : self.languageButton;
    }
    return nil;
}

- (void)rebuildItems {
    for (NSView *view in [self.stack.arrangedSubviews copy]) {
        [self.stack removeArrangedSubview:view];
        [view removeFromSuperview];
    }

    NSMutableArray<NSView *> *leading = [NSMutableArray array];
    NSView *language = nil;
    for (SCEStatusBarItem item in self.items) {
        NSView *view = [self viewForItem:item];
        if (!view || [leading containsObject:view] || view == language) {
            continue;
        }
        if ([item isEqualToString:SCEStatusBarItemLanguage]) {
            language = view;
        } else {
            [leading addObject:view];
        }
    }

    for (NSUInteger index = 0; index < leading.count; index++) {
        if (index > 0) {
            [self.stack addArrangedSubview:[self makeSeparator]];
        }
        [self.stack addArrangedSubview:leading[index]];
    }
    if (language) {
        NSView *spacer = [[NSView alloc] init];
        [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        [spacer setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        [self.stack addArrangedSubview:spacer];
        if (leading.count > 0) {
            [self.stack addArrangedSubview:[self makeSeparator]];
        }
        [self.stack addArrangedSubview:language];
    }
    _hasVisibleItems = leading.count > 0 || language != nil;
}

- (void)setLine:(NSUInteger)line column:(NSUInteger)column lineCount:(NSUInteger)lineCount {
    self.lineLabel.stringValue = [NSString stringWithFormat:@"Ln %lu", (unsigned long)line];
    self.columnLabel.stringValue = [NSString stringWithFormat:@"Col %lu", (unsigned long)column];
    self.lineCountLabel.stringValue = [NSString stringWithFormat:@"%lu lines", (unsigned long)lineCount];
}

@end
