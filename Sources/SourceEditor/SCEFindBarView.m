#import "include/SCEFindBarView.h"
#import "SCEEditorViewInternal.h"

static const CGFloat SCEFindBarControlHeight = 36;
// Controls inside a capsule keep this inset from its top, bottom, and trailing
// edges. Their capsule shapes then share the outer capsule's center of
// curvature: inner radius = outer radius - inset.
static const CGFloat SCEFindBarConcentricInset = 4;
static const CGFloat SCEFindBarOptionButtonWidth = 32;
static const CGFloat SCEFindBarGlassSpacing = 8;
static const CGFloat SCEFindBarButtonSize = 28;
static const CGFloat SCEFindBarMinimumFieldWidth = 180;

@interface SCEFindBarView () <NSTextFieldDelegate>
@end

// A toggle drawn as a capsule concentric with the find bar's search capsule.
// The fill indicates the on state, pointer hover, and pressing.
@interface SCEFindOptionButton : NSButton
@property (nonatomic, copy) NSString *optionTitle;
@end

@implementation SCEFindOptionButton {
    NSTrackingArea *_hoverTrackingArea;
    BOOL _hovered;
}

- (NSSize)intrinsicContentSize {
    return NSMakeSize(SCEFindBarOptionButtonWidth, SCEFindBarControlHeight - 2 * SCEFindBarConcentricInset);
}

- (void)setState:(NSControlStateValue)state {
    [super setState:state];
    self.needsDisplay = YES;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.needsDisplay = YES;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_hoverTrackingArea) {
        [self removeTrackingArea:_hoverTrackingArea];
    }
    _hoverTrackingArea = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
               owner:self
            userInfo:nil];
    [self addTrackingArea:_hoverTrackingArea];
}

- (void)mouseEntered:(NSEvent *)event {
    _hovered = YES;
    self.needsDisplay = YES;
}

- (void)mouseExited:(NSEvent *)event {
    _hovered = NO;
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    BOOL isOn = self.state == NSControlStateValueOn;
    CGFloat fillAlpha = 0;
    if (self.isHighlighted) {
        fillAlpha = isOn ? 0.22 : 0.12;
    } else if (isOn) {
        fillAlpha = 0.16;
    } else if (_hovered) {
        fillAlpha = 0.07;
    }
    NSRect bounds = self.bounds;
    if (fillAlpha > 0) {
        CGFloat radius = NSHeight(bounds) / 2;
        [[NSColor.labelColor colorWithAlphaComponent:fillAlpha] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:bounds xRadius:radius yRadius:radius] fill];
    }
    NSColor *titleColor =
        !self.isEnabled ? NSColor.tertiaryLabelColor : (isOn ? NSColor.labelColor : NSColor.secondaryLabelColor);
    NSAttributedString *title = [[NSAttributedString alloc]
        initWithString:self.optionTitle ?: @""
            attributes:@{
                NSFontAttributeName : [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightSemibold],
                NSForegroundColorAttributeName : titleColor,
            }];
    NSSize size = title.size;
    [title drawAtPoint:NSMakePoint(round(NSMidX(bounds) - size.width / 2), round(NSMidY(bounds) - size.height / 2))];
}

@end

@implementation SCEFindBarView {
    NSTextField *_searchField;
    NSTextField *_statusLabel;
    NSButton *_caseSensitiveButton;
    NSButton *_wholeWordButton;
    NSButton *_regularExpressionButton;
    NSButton *_previousButton;
    NSButton *_nextButton;
    NSButton *_closeButton;
    NSNumberFormatter *_countFormatter;
    id _searchResultsObserver;
    id _selectionObserver;
    // UTF-16 offset from which incremental matching starts after the query changes.
    NSUInteger _searchOrigin;
    // Set when the query changes; cleared after the resulting match is selected.
    BOOL _selectsMatchFromSearchOrigin;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        [self setUpFindBar];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    if ((self = [super initWithCoder:coder])) {
        [self setUpFindBar];
    }
    return self;
}

- (void)dealloc {
    [self removeEditorObservers];
}

// MARK: View construction

- (void)setUpFindBar {
    _countFormatter = [[NSNumberFormatter alloc] init];
    _countFormatter.numberStyle = NSNumberFormatterDecimalStyle;
    [self setAccessibilityElement:YES];
    [self setAccessibilityRole:NSAccessibilityGroupRole];
    [self setAccessibilityLabel:NSLocalizedString(@"Find", nil)];

    NSImageView *searchIcon = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"magnifyingglass"
                                                                        accessibilityDescription:nil]];
    searchIcon.contentTintColor = NSColor.secondaryLabelColor;
    searchIcon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:13
                                                                                     weight:NSFontWeightMedium];
    [searchIcon setAccessibilityElement:NO];

    _searchField = [NSTextField textFieldWithString:@""];
    _searchField.bordered = NO;
    _searchField.bezeled = NO;
    _searchField.drawsBackground = NO;
    _searchField.focusRingType = NSFocusRingTypeNone;
    _searchField.font = [NSFont systemFontOfSize:13];
    _searchField.placeholderString = NSLocalizedString(@"Find", nil);
    _searchField.usesSingleLineMode = YES;
    _searchField.lineBreakMode = NSLineBreakByClipping;
    _searchField.cell.scrollable = YES;
    _searchField.delegate = self;
    [_searchField setAccessibilityLabel:NSLocalizedString(@"Find", nil)];
    [_searchField setContentHuggingPriority:NSLayoutPriorityDefaultLow
                             forOrientation:NSLayoutConstraintOrientationHorizontal];

    _statusLabel = [NSTextField labelWithString:@""];
    _statusLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    _statusLabel.textColor = NSColor.secondaryLabelColor;
    [_statusLabel setContentHuggingPriority:NSLayoutPriorityRequired
                             forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_statusLabel setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                           forOrientation:NSLayoutConstraintOrientationHorizontal];

    _caseSensitiveButton = [self optionButtonWithTitle:@"Aa" toolTip:NSLocalizedString(@"Match Case", nil)];
    _wholeWordButton = [self optionButtonWithTitle:@"W" toolTip:NSLocalizedString(@"Whole Words", nil)];
    _regularExpressionButton = [self optionButtonWithTitle:@".*" toolTip:NSLocalizedString(@"Regular Expression", nil)];

    NSStackView *fieldContent = [self rowWithViews:@[
        searchIcon, _searchField, _statusLabel, _caseSensitiveButton, _wholeWordButton, _regularExpressionButton
    ]];
    fieldContent.edgeInsets = NSEdgeInsetsMake(0, 14, 0, SCEFindBarConcentricInset);
    [fieldContent setCustomSpacing:6 afterView:searchIcon];
    [fieldContent setCustomSpacing:8 afterView:_statusLabel];
    fieldContent.spacing = 2;

    _previousButton = [self symbolButtonWithName:@"chevron.up"
                                           label:NSLocalizedString(@"Previous Match", nil)
                                          action:@selector(findPrevious:)];
    _nextButton = [self symbolButtonWithName:@"chevron.down"
                                       label:NSLocalizedString(@"Next Match", nil)
                                      action:@selector(findNext:)];
    NSStackView *navigationContent = [self rowWithViews:@[ _previousButton, _nextButton ]];
    navigationContent.edgeInsets = NSEdgeInsetsMake(0, 4, 0, 4);
    navigationContent.spacing = 0;

    _closeButton = [self symbolButtonWithName:@"xmark"
                                        label:NSLocalizedString(@"Done", nil)
                                       action:@selector(closeFindBar:)];
    NSStackView *closeContent = [self rowWithViews:@[ _closeButton ]];
    closeContent.edgeInsets = NSEdgeInsetsMake(0, 4, 0, 4);

    NSView *fieldGlass = [self glassViewWithContentView:fieldContent];
    NSView *navigationGlass = [self glassViewWithContentView:navigationContent];
    NSView *closeGlass = [self glassViewWithContentView:closeContent];
    [NSLayoutConstraint activateConstraints:@[
        [fieldGlass.widthAnchor constraintGreaterThanOrEqualToConstant:SCEFindBarMinimumFieldWidth + 120],
        [closeGlass.widthAnchor constraintEqualToConstant:SCEFindBarControlHeight],
    ]];

    NSStackView *row = [NSStackView stackViewWithViews:@[ fieldGlass, navigationGlass, closeGlass ]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = SCEFindBarGlassSpacing;
    row.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *container = row;
    if (@available(macOS 26.0, *)) {
        // The container renders the three shapes in one pass. A merge distance
        // of zero keeps them visually separate at the spacing between them.
        NSGlassEffectContainerView *glassContainer = [[NSGlassEffectContainerView alloc] init];
        glassContainer.spacing = 0;
        glassContainer.contentView = row;
        glassContainer.translatesAutoresizingMaskIntoConstraints = NO;
        [self pinView:row toView:glassContainer];
        container = glassContainer;
    }
    [self addSubview:container];
    [self pinView:container toView:self];

    [self updateOptionButtons];
    [self updateStatus];
}

- (NSStackView *)rowWithViews:(NSArray<NSView *> *)views {
    NSStackView *row = [NSStackView stackViewWithViews:views];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [row.heightAnchor constraintEqualToConstant:SCEFindBarControlHeight].active = YES;
    return row;
}

- (void)pinView:(NSView *)view toView:(NSView *)container {
    [NSLayoutConstraint activateConstraints:@[
        [view.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [view.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [view.topAnchor constraintEqualToAnchor:container.topAnchor],
        [view.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
    ]];
}

// Wraps content in a capsule. Liquid Glass is used where available, with a
// translucent material as the fallback on earlier systems.
- (NSView *)glassViewWithContentView:(NSView *)contentView {
    CGFloat cornerRadius = SCEFindBarControlHeight / 2;
    NSView *background = nil;
    if (@available(macOS 26.0, *)) {
        NSGlassEffectView *glass = [[NSGlassEffectView alloc] init];
        glass.cornerRadius = cornerRadius;
        glass.contentView = contentView;
        if (@available(macOS 27.0, *)) {
            glass.effectIsInteractive = YES;
        }
        background = glass;
    } else {
        NSVisualEffectView *effect = [[NSVisualEffectView alloc] init];
        effect.material = NSVisualEffectMaterialPopover;
        effect.blendingMode = NSVisualEffectBlendingModeWithinWindow;
        effect.state = NSVisualEffectStateActive;
        effect.wantsLayer = YES;
        effect.layer.cornerRadius = cornerRadius;
        effect.layer.cornerCurve = kCACornerCurveContinuous;
        effect.layer.masksToBounds = YES;
        effect.layer.borderWidth = 0.5;
        effect.layer.borderColor = [NSColor.separatorColor colorWithAlphaComponent:0.4].CGColor;
        [effect addSubview:contentView];
        background = effect;
    }
    background.translatesAutoresizingMaskIntoConstraints = NO;
    [self pinView:contentView toView:background];
    return background;
}

- (NSButton *)symbolButtonWithName:(NSString *)symbolName label:(NSString *)label action:(SEL)action {
    NSImage *image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:label];
    NSButton *button = [NSButton buttonWithImage:image target:self action:action];
    button.bordered = NO;
    button.imagePosition = NSImageOnly;
    button.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightSemibold];
    button.contentTintColor = NSColor.labelColor;
    button.toolTip = label;
    [button setAccessibilityLabel:label];
    [NSLayoutConstraint activateConstraints:@[
        [button.widthAnchor constraintEqualToConstant:SCEFindBarButtonSize],
        [button.heightAnchor constraintEqualToConstant:SCEFindBarButtonSize],
    ]];
    return button;
}

- (NSButton *)optionButtonWithTitle:(NSString *)title toolTip:(NSString *)toolTip {
    SCEFindOptionButton *button = [[SCEFindOptionButton alloc] initWithFrame:NSZeroRect];
    [button setButtonType:NSButtonTypePushOnPushOff];
    button.bordered = NO;
    button.title = @"";
    button.optionTitle = title;
    ((NSButtonCell *)button.cell).highlightsBy = NSNoCellMask;
    button.target = self;
    button.action = @selector(changeSearchOption:);
    button.toolTip = toolTip;
    [button setAccessibilityLabel:toolTip];
    [button setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [button setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationVertical];
    return button;
}

// MARK: Editor observation

- (void)setEditor:(SCEEditorView *)editor {
    if (_editor == editor) {
        return;
    }
    if (_searching) {
        _editor.searchQuery = nil;
    }
    [self removeEditorObservers];
    _editor = editor;
    if (editor) {
        __weak SCEFindBarView *weakSelf = self;
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        _searchResultsObserver = [center addObserverForName:SCEEditorSearchResultsDidChangeNotification
                                                     object:editor
                                                      queue:nil
                                                 usingBlock:^(NSNotification *note) {
                                                     [weakSelf searchResultsDidChange];
                                                 }];
        _selectionObserver = [center addObserverForName:SCEEditorSelectionDidChangeNotification
                                                 object:editor
                                                  queue:nil
                                             usingBlock:^(NSNotification *note) {
                                                 [weakSelf updateStatus];
                                             }];
    }
    if (_searching) {
        _searchOrigin = editor.selectedRange.location;
        [self applySearchQuerySelectingMatch:NO];
    }
    [self updateStatus];
}

- (void)removeEditorObservers {
    for (id observer in @[ _searchResultsObserver ?: NSNull.null, _selectionObserver ?: NSNull.null ]) {
        if (observer != NSNull.null) {
            [NSNotificationCenter.defaultCenter removeObserver:observer];
        }
    }
    _searchResultsObserver = nil;
    _selectionObserver = nil;
}

// Selects the match from the origin as soon as the known matches determine it,
// which is usually before the whole document is searched.
- (void)searchResultsDidChange {
    if (_selectsMatchFromSearchOrigin &&
        [_editor canSelectNextSearchMatchFromUTF16OffsetWithoutSearching:_searchOrigin]) {
        [self selectMatchFromSearchOrigin];
    }
    [self updateStatus];
}

// MARK: Search state

- (NSString *)searchString {
    return _searchField.stringValue;
}

- (void)setSearchString:(NSString *)searchString {
    searchString = searchString ?: @"";
    if ([searchString isEqualToString:_searchField.stringValue]) {
        return;
    }
    _searchField.stringValue = searchString;
    [self applySearchQuerySelectingMatch:YES];
}

- (void)setSearchOptions:(SCETextSearchOptions)searchOptions {
    if (_searchOptions == searchOptions) {
        return;
    }
    _searchOptions = searchOptions;
    [self updateOptionButtons];
    [self applySearchQuerySelectingMatch:YES];
}

- (void)updateOptionButtons {
    _caseSensitiveButton.state =
        _searchOptions & SCETextSearchOptionCaseSensitive ? NSControlStateValueOn : NSControlStateValueOff;
    _wholeWordButton.state =
        _searchOptions & SCETextSearchOptionWholeWord ? NSControlStateValueOn : NSControlStateValueOff;
    _regularExpressionButton.state =
        _searchOptions & SCETextSearchOptionRegularExpression ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)changeSearchOption:(NSButton *)sender {
    SCETextSearchOptions options = 0;
    if (_caseSensitiveButton.state == NSControlStateValueOn) {
        options |= SCETextSearchOptionCaseSensitive;
    }
    if (_wholeWordButton.state == NSControlStateValueOn) {
        options |= SCETextSearchOptionWholeWord;
    }
    if (_regularExpressionButton.state == NSControlStateValueOn) {
        options |= SCETextSearchOptionRegularExpression;
    }
    self.searchOptions = options;
}

- (void)applySearchQuerySelectingMatch:(BOOL)selectsMatch {
    if (!_searching || !_editor) {
        return;
    }
    NSString *pattern = _searchField.stringValue;
    _selectsMatchFromSearchOrigin = selectsMatch;
    _editor.searchQuery =
        pattern.length ? [[SCETextSearchQuery alloc] initWithPattern:pattern options:_searchOptions] : nil;
    // An unchanged query produces no notification, so complete the selection here.
    [self searchResultsDidChange];
}

// Selects the first match at or after the origin, wrapping to the first match.
// Without matches, the caret remains at the origin. The editor locates the
// match with a binary search, so the cost does not grow with the match count.
- (void)selectMatchFromSearchOrigin {
    _selectsMatchFromSearchOrigin = NO;
    _editor.selectedRange = NSMakeRange(_searchOrigin, 0);
    [_editor selectNextSearchMatch];
}

- (void)beginSearch {
    if (!_searching) {
        _searching = YES;
        _searchOrigin = _editor.selectedRange.location;
        [self applySearchQuerySelectingMatch:NO];
    }
    [self.window makeFirstResponder:_searchField];
    [_searchField selectText:nil];
    [self updateStatus];
}

- (void)endSearch {
    if (!_searching) {
        return;
    }
    _searching = NO;
    _selectsMatchFromSearchOrigin = NO;
    _editor.searchQuery = nil;
    NSResponder *responder = self.window.firstResponder;
    if ([responder isKindOfClass:NSView.class] && [(NSView *)responder isDescendantOf:self] && _editor.window) {
        [_editor.window makeFirstResponder:_editor];
    }
    [self updateStatus];
}

- (void)findNext:(id)sender {
    if ([_editor selectNextSearchMatch]) {
        _searchOrigin = _editor.selectedRange.location;
    }
}

- (void)findPrevious:(id)sender {
    if ([_editor selectPreviousSearchMatch]) {
        _searchOrigin = _editor.selectedRange.location;
    }
}

- (void)closeFindBar:(id)sender {
    [self endSearch];
    if (self.dismissalHandler) {
        self.dismissalHandler();
    }
}

- (void)cancelOperation:(id)sender {
    [self closeFindBar:sender];
}

- (void)updateStatus {
    NSString *status = @"";
    NSColor *color = NSColor.secondaryLabelColor;
    NSString *toolTip = nil;
    SCEEditorView *editor = _editor;
    BOOL hasQuery = _searching && editor.searchQuery != nil;
    NSUInteger count = hasQuery ? editor.numberOfSearchMatches : 0;
    if (hasQuery && editor.searchError) {
        status = NSLocalizedString(@"Invalid Pattern", nil);
        color = NSColor.systemRedColor;
        toolTip = editor.searchError.localizedFailureReason ?: editor.searchError.localizedDescription;
    } else if (hasQuery && !count && !editor.isSearchPending) {
        status = NSLocalizedString(@"No Matches", nil);
    } else if (count) {
        NSString *total = [_countFormatter stringFromNumber:@(count)];
        if (editor.isSearchResultTruncated) {
            total = [total stringByAppendingString:@"+"];
        }
        NSUInteger current = editor.currentSearchMatchIndex;
        if (current != NSNotFound) {
            status = [NSString stringWithFormat:NSLocalizedString(@"%@ of %@", nil),
                                                [_countFormatter stringFromNumber:@(current + 1)], total];
        } else if (count == 1 && !editor.isSearchResultTruncated) {
            status = NSLocalizedString(@"1 match", nil);
        } else {
            status = [NSString stringWithFormat:NSLocalizedString(@"%@ matches", nil), total];
        }
    }
    _statusLabel.stringValue = status;
    _statusLabel.textColor = color;
    _statusLabel.toolTip = toolTip;
    _statusLabel.hidden = status.length == 0;
    BOOL canNavigate = count > 0 || (hasQuery && editor.isSearchPending);
    _previousButton.enabled = canNavigate;
    _nextButton.enabled = canNavigate;
}

// MARK: Search field delegate

- (void)controlTextDidChange:(NSNotification *)notification {
    [self applySearchQuerySelectingMatch:YES];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)selector {
    if (selector == @selector(insertNewline:) || selector == @selector(insertLineBreak:) ||
        selector == @selector(insertNewlineIgnoringFieldEditor:)) {
        if (NSApp.currentEvent.modifierFlags & NSEventModifierFlagShift) {
            [self findPrevious:control];
        } else {
            [self findNext:control];
        }
        return YES;
    }
    if (selector == @selector(cancelOperation:)) {
        [self closeFindBar:control];
        return YES;
    }
    return NO;
}

@end
