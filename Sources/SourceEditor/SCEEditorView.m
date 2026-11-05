#import "include/SCEEditorView.h"
#import "SCELineLayoutCache.h"
#import "SCEViewport.h"
#import "SCESelectionPath.h"
#import "SCEBracketScope.h"
#import "SCETextSearchMatching.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>

NSNotificationName const SCEEditorTextDidChangeNotification = @"SCEEditorTextDidChangeNotification";
NSNotificationName const SCEEditorSelectionDidChangeNotification = @"SCEEditorSelectionDidChangeNotification";
NSNotificationName const SCEEditorSyntaxHighlightingDidUpdateNotification =
    @"SCEEditorSyntaxHighlightingDidUpdateNotification";
NSNotificationName const SCEEditorSearchResultsDidChangeNotification = @"SCEEditorSearchResultsDidChangeNotification";

static const CGFloat SCEInset = 12;
static const CGFloat SCELineSpacingMultiplier = 1.2;
static const CGFloat SCECaretWidth = 2.5;
static const CGFloat SCEHighlightHorizontalPadding = 8;
static const CGFloat SCECurrentLineCornerRadius = 6;
static const CGFloat SCELineNumberFontSizeRatio = 0.9;
static const CGFloat SCEScopeGuideWidth = 1;
static const CGFloat SCESearchMatchCornerRadius = 3;

// Returns the index of the first range whose location is at least offset.
// Ranges must be sorted and non-overlapping.
static NSUInteger SCEIndexOfFirstRangeStartingAtOrAfter(const NSRange *ranges, NSUInteger count, NSUInteger offset) {
    NSUInteger low = 0;
    NSUInteger high = count;
    while (low < high) {
        NSUInteger middle = low + (high - low) / 2;
        if (ranges[middle].location < offset) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    return low;
}

// Returns the index of the first range that ends after offset. Sorted,
// non-overlapping ranges also have increasing end offsets.
static NSUInteger SCEIndexOfFirstRangeEndingAfter(const NSRange *ranges, NSUInteger count, NSUInteger offset) {
    NSUInteger low = 0;
    NSUInteger high = count;
    while (low < high) {
        NSUInteger middle = low + (high - low) / 2;
        if (NSMaxRange(ranges[middle]) <= offset) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    return low;
}

// Cancellation state shared between the main thread and the search queue.
@interface SCETextSearchRequest : NSObject
@property (atomic, getter=isCancelled) BOOL cancelled;
@end

@implementation SCETextSearchRequest
@end

@interface SCEEditorView (SurfaceDrawing)
- (void)drawTextSurface:(NSView *)surface;
/// Whether the background fills every pixel, so that views behind it need not draw.
@property (nonatomic, readonly) BOOL hasOpaqueBackground;

- (void)drawBackgroundSurface:(NSView *)surface;
@end

// Backing stores are viewport-sized, even when the document is millions of
// points tall. Text and selection have independent backing layers.
@interface SCEEditorSurface : NSView
@property (nonatomic, weak) SCEEditorView *editor;
@property (nonatomic) BOOL drawsText;
@end

@implementation SCEEditorSurface

- (BOOL)isFlipped {
    return YES;
}

- (BOOL)isOpaque {
    return !self.drawsText && self.editor.hasOpaqueBackground;
}

- (BOOL)isAccessibilityElement {
    return NO;
}

- (NSView *)hitTest:(NSPoint)point {
    return nil;
}

- (void)drawRect:(NSRect)dirtyRect {
    if (self.drawsText) {
        [self.editor drawTextSurface:self];
    } else {
        [self.editor drawBackgroundSurface:self];
    }
}

@end

@implementation SCEEditorView {
    SCETextBuffer *_buffer;
    SCELineLayoutCache *_layoutCache;
    SCEEditorSurface *_backgroundSurface;
    SCEEditorSurface *_textSurface;
    NSTextInsertionIndicator *_caretIndicator;
    NSUndoManager *_editUndoManager;
    NSTextInputContext *_textInputContext;
    NSTimer *_autoscrollTimer;
    id _clipBoundsObserver;
    id _clipFrameObserver;
    id _windowKeyObserver;
    id _windowResignObserver;
    id _systemColorsObserver;
    NSUInteger _anchor;
    NSUInteger _head;
    CGFloat _preferredX;
    CGFloat _lineHeight;
    CGFloat _baseline;
    NSFont *_lineNumberFont;
    CGFloat _lineNumberBaseline;
    CGFloat _lineNumberMaximumDigitWidth;
    CGFloat _maximumMeasuredWidth;
    NSRect _viewportRect;
    BOOL _updatingViewport;
    NSRange _markedRange;
    NSRange _compositionOriginalSelection;
    NSString *_compositionOriginalText;
    NSUInteger _dragGranularity;
    NSRange _dragInitialRange;
    NSEvent *_lastDragEvent;
    SCETextEdit *_pendingSyntaxEdit;
    NSUInteger _syntaxRequestID;
    NSUInteger _requestedSyntaxRevision;
    NSRange _requestedSyntaxRange;
    BOOL _hasSyntaxRequest;
    // Enclosing bracket scope of the caret, cached by document revision and head.
    NSRange _scopeGuideBrackets;
    NSUInteger _scopeGuideOpenLine;
    NSUInteger _scopeGuideCloseLine;
    NSUInteger _scopeGuideRevision;
    NSUInteger _scopeGuideHead;
    BOOL _hasScopeGuideState;
    CGFloat _scopeGuideX;
    // Search matches are packed NSRange values in document order. Edits move or
    // remove them immediately; a background search then replaces them.
    dispatch_queue_t _searchQueue;
    NSMutableData *_searchMatchData;
    SCETextSearchRequest *_searchRequest;
    NSUInteger _searchRequestID;
    BOOL _searchUpdateScheduled;
    NSTrackingArea *_linkTrackingArea;
    id _modifierFlagsMonitor;
    NSDataDetector *_linkDetector;
    NSArray<NSTextCheckingResult *> *_detectedLineLinks;
    NSUInteger _detectedLinkLine;
    NSUInteger _detectedLinkRevision;
    NSRange _hoveredLinkRange;
    BOOL _handlingLinkClick;
    NSURL *_pressedLinkURL;
    NSRange _pressedLinkRange;
    NSUInteger _pressedLinkRevision;
}

+ (NSScrollView *)scrollableEditorView {
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSNoBorder;
    scroll.drawsBackground = NO;
    scroll.documentView = [[self alloc] initWithFrame:scroll.contentView.bounds];
    return scroll;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        [self setUpEditor];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    if ((self = [super initWithCoder:coder])) {
        [self setUpEditor];
    }
    return self;
}

- (void)setUpEditor {
    _buffer = [[SCETextBuffer alloc] init];
    _font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    _layoutCache = [[SCELineLayoutCache alloc] initWithBuffer:_buffer font:_font];
    _syntaxTheme = SCESyntaxTheme.defaultTheme;
    _editable = YES;
    _showsLineNumbers = YES;
    _showsScopeGuide = YES;
    _focusable = YES;
    _scopeGuideBrackets = NSMakeRange(NSNotFound, 0);
    _scopeGuideX = NAN;
    _automaticIndentationEnabled = YES;
    _automaticLinkDetectionEnabled = YES;
    _hoveredLinkRange = NSMakeRange(NSNotFound, 0);
    _tabWidth = 4;
    _preferredX = NAN;
    _markedRange = NSMakeRange(NSNotFound, 0);
    _searchMatchData = [NSMutableData data];
    _searchQueue = dispatch_queue_create(
        "SourceEditor.SCEEditorView.search",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    _editUndoManager = [[NSUndoManager alloc] init];
    _editUndoManager.groupsByEvent = NO;
    _editUndoManager.levelsOfUndo = 1000;
    _backgroundSurface = [[SCEEditorSurface alloc] initWithFrame:self.bounds];
    _backgroundSurface.editor = self;
    _backgroundSurface.wantsLayer = YES;
    _textSurface = [[SCEEditorSurface alloc] initWithFrame:self.bounds];
    _textSurface.editor = self;
    _textSurface.drawsText = YES;
    _textSurface.wantsLayer = YES;
    _textSurface.layer.masksToBounds = YES;
    [self addSubview:_backgroundSurface];
    [self addSubview:_textSurface];
    _caretIndicator = [[NSTextInsertionIndicator alloc] initWithFrame:NSZeroRect];
    _caretIndicator.displayMode = NSTextInsertionIndicatorDisplayModeHidden;
    // Dictation effects require an overlay outside the clipped text surface.
    _caretIndicator.automaticModeOptions = 0;
    [_textSurface addSubview:_caretIndicator];
    __weak SCEEditorView *weakSelf = self;
    _systemColorsObserver = [NSNotificationCenter.defaultCenter addObserverForName:NSSystemColorsDidChangeNotification
                                                                            object:nil
                                                                             queue:NSOperationQueue.mainQueue
                                                                        usingBlock:^(NSNotification *note) {
                                                                            [weakSelf updateAppearance];
                                                                        }];
    [self updateFontMetrics];
    [self updateAppearance];
}

- (void)dealloc {
    if (_modifierFlagsMonitor) {
        [NSEvent removeMonitor:_modifierFlagsMonitor];
    }
    if ([_syntaxHighlighter respondsToSelector:@selector(cancelPendingRequests)]) {
        [_syntaxHighlighter cancelPendingRequests];
    }
    _searchRequest.cancelled = YES;
    [_autoscrollTimer invalidate];
    for (id token in @[
             _clipBoundsObserver ?: NSNull.null, _clipFrameObserver ?: NSNull.null, _windowKeyObserver ?: NSNull.null,
             _windowResignObserver ?: NSNull.null, _systemColorsObserver ?: NSNull.null
         ]) {
        if (token != NSNull.null) {
            [NSNotificationCenter.defaultCenter removeObserver:token];
        }
    }
}

- (BOOL)isFlipped {
    return YES;
}

- (BOOL)acceptsFirstResponder {
    return _focusable;
}

- (BOOL)isOpaque {
    return NO;
}

- (BOOL)becomeFirstResponder {
    // NSWindow calls this without consulting acceptsFirstResponder.
    if (!_focusable) {
        return NO;
    }
    [self.inputContext activate];
    [self selectionDidChange];
    // AppKit commits the new first responder after this method returns.
    __weak SCEEditorView *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf updateCaret];
    });
    return YES;
}

- (BOOL)resignFirstResponder {
    [self unmarkText];
    [self.inputContext discardMarkedText];
    [self.inputContext deactivate];
    [self setCaretVisible:NO];
    _backgroundSurface.needsDisplay = YES;
    return YES;
}

- (NSUndoManager *)undoManager {
    return _editUndoManager;
}

- (NSTextInputContext *)inputContext {
    if (!_textInputContext) {
        _textInputContext = [[NSTextInputContext alloc] initWithClient:self];
    }
    return _textInputContext;
}

- (void)updateFontMetrics {
    CGFloat descent = ceil(fabs(_font.descender));
    CGFloat naturalHeight = ceil(_font.ascender + fabs(_font.descender) + _font.leading);
    _lineHeight = ceil(naturalHeight * SCELineSpacingMultiplier);
    // Preserve the font's natural baseline and split the added spacing evenly.
    _baseline = naturalHeight - descent + (_lineHeight - naturalHeight) / 2;
    _lineNumberFont = [NSFont fontWithDescriptor:_font.fontDescriptor
                                            size:_font.pointSize * SCELineNumberFontSizeRatio];
    NSAttributedString *digits = [[NSAttributedString alloc] initWithString:@"0123456789"
                                                                 attributes:@{
                                                                     NSFontAttributeName : _lineNumberFont,
                                                                 }];
    CTLineRef digitLine = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)digits);
    CGRect digitBounds = CTLineGetBoundsWithOptions(digitLine, kCTLineBoundsUseGlyphPathBounds);
    _lineNumberBaseline = _lineHeight / 2 + CGRectGetMidY(digitBounds);
    CFRelease(digitLine);
    _lineNumberMaximumDigitWidth = 0;
    for (NSUInteger index = 0; index < digits.length; index++) {
        NSAttributedString *digit = [digits attributedSubstringFromRange:NSMakeRange(index, 1)];
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)digit);
        _lineNumberMaximumDigitWidth =
            MAX(_lineNumberMaximumDigitWidth, CTLineGetTypographicBounds(line, NULL, NULL, NULL));
        CFRelease(line);
    }
    self.enclosingScrollView.verticalLineScroll = _lineHeight;
}

- (void)updateAppearance {
    if (!_layoutCache) {
        return;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        self->_layoutCache.textColor = [[self themeColor:SCEEditorColorText fallback:NSColor.textColor]
            colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
        self->_layoutCache.appearance = self.effectiveAppearance;
        self->_caretIndicator.color = [self themeColor:SCEEditorColorCaret fallback:NSColor.controlAccentColor];
    }];
    [CATransaction commit];
    _backgroundSurface.needsDisplay = YES;
    _textSurface.needsDisplay = YES;
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self updateAppearance];
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    _textSurface.needsDisplay = YES;
    [self updateCaret];
}

- (void)viewDidMoveToSuperview {
    [super viewDidMoveToSuperview];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    if (_clipBoundsObserver) {
        [center removeObserver:_clipBoundsObserver];
    }
    if (_clipFrameObserver) {
        [center removeObserver:_clipFrameObserver];
    }
    _clipBoundsObserver = nil;
    _clipFrameObserver = nil;
    NSClipView *clip = self.enclosingScrollView.contentView;
    if (clip) {
        clip.postsBoundsChangedNotifications = YES;
        clip.postsFrameChangedNotifications = YES;
        __weak SCEEditorView *weakSelf = self;
        _clipBoundsObserver = [center addObserverForName:NSViewBoundsDidChangeNotification
                                                  object:clip
                                                   queue:nil
                                              usingBlock:^(NSNotification *note) {
                                                  [weakSelf updateViewport];
                                              }];
        _clipFrameObserver = [center addObserverForName:NSViewFrameDidChangeNotification
                                                 object:clip
                                                  queue:nil
                                             usingBlock:^(NSNotification *note) {
                                                 [weakSelf updateViewport];
                                             }];
        self.enclosingScrollView.verticalLineScroll = _lineHeight;
    }
    [self updateViewport];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (_modifierFlagsMonitor) {
        [NSEvent removeMonitor:_modifierFlagsMonitor];
        _modifierFlagsMonitor = nil;
    }
    [self setHoveredLinkRange:NSMakeRange(NSNotFound, 0)];
    _handlingLinkClick = NO;
    _pressedLinkURL = nil;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    if (_windowKeyObserver) {
        [center removeObserver:_windowKeyObserver];
    }
    if (_windowResignObserver) {
        [center removeObserver:_windowResignObserver];
    }
    _windowKeyObserver = nil;
    _windowResignObserver = nil;
    if (self.window) {
        __weak SCEEditorView *weakSelf = self;
        void (^update)(NSNotification *) = ^(NSNotification *note) {
            [weakSelf selectionDidChange];
            [weakSelf updateLinkHoverForCurrentPointer];
        };
        _windowKeyObserver = [center addObserverForName:NSWindowDidBecomeKeyNotification
                                                 object:self.window
                                                  queue:nil
                                             usingBlock:update];
        _windowResignObserver = [center addObserverForName:NSWindowDidResignKeyNotification
                                                    object:self.window
                                                     queue:nil
                                                usingBlock:update];
        // Modifier events go to the first responder. A local monitor also keeps
        // hover feedback current when another view has focus, without consuming
        // events or observing input outside this application.
        _modifierFlagsMonitor = [NSEvent
            addLocalMonitorForEventsMatchingMask:NSEventMaskFlagsChanged
                                         handler:^NSEvent *(NSEvent *event) {
                                             SCEEditorView *editor = weakSelf;
                                             if (editor.window.isKeyWindow) {
                                                 [editor
                                                     updateLinkHoverAtWindowPoint:editor.window
                                                                                      .mouseLocationOutsideOfEventStream
                                                                    modifierFlags:event.modifierFlags];
                                             }
                                             return event;
                                         }];
    }
    [self updateViewport];
}

- (CGFloat)gutterWidth {
    if (!_showsLineNumbers) {
        return 0;
    }
    NSUInteger digits = [NSString stringWithFormat:@"%lu", (unsigned long)_buffer.lineCount].length;
    return MAX(44, ceil(digits * _lineNumberMaximumDigitWidth) + 22);
}

- (CGFloat)textOriginX {
    return self.gutterWidth + SCEInset;
}

- (void)updateViewport {
    if (_updatingViewport || !_buffer) {
        return;
    }
    _updatingViewport = YES;
    NSClipView *clip = self.enclosingScrollView.contentView;
    NSRect visible = clip ? clip.bounds : self.bounds;
    if (clip) {
        NSSize size = NSMakeSize(MAX(NSWidth(visible), self.textOriginX + _maximumMeasuredWidth + SCEInset),
                                 MAX(NSHeight(visible), SCEInset * 2 + _buffer.lineCount * _lineHeight));
        if (!NSEqualSizes(size, self.frame.size)) {
            [self setFrameSize:size];
        }
        visible = clip.bounds;
    }
    _viewportRect = visible;
    NSRange lines = [SCEViewport lineRangeForVisibleRect:visible
                                               lineCount:_buffer.lineCount
                                              lineHeight:_lineHeight
                                                topInset:SCEInset
                                                overscan:6];
    [_layoutCache retainLinesInRange:lines];
    for (NSUInteger i = lines.location; i < NSMaxRange(lines); i++) {
        _maximumMeasuredWidth = MAX(_maximumMeasuredWidth, [_layoutCache layoutForLineAtIndex:i].width);
    }
    if (clip) {
        CGFloat width = MAX(NSWidth(visible), self.textOriginX + _maximumMeasuredWidth + SCEInset);
        if (width != NSWidth(self.frame)) {
            [self setFrameSize:NSMakeSize(width, NSHeight(self.frame))];
        }
        _viewportRect = clip.bounds;
    }
    _backgroundSurface.frame = _viewportRect;
    _textSurface.frame = _viewportRect;
    _backgroundSurface.needsDisplay = YES;
    _textSurface.needsDisplay = YES;
    [self updateCaret];
    [_textInputContext invalidateCharacterCoordinates];
    [self.window invalidateCursorRectsForView:self];
    _updatingViewport = NO;
    [self updateLinkHoverForCurrentPointer];
    SCETextEdit *edit = _pendingSyntaxEdit;
    _pendingSyntaxEdit = nil;
    [self requestSyntaxHighlightingForLines:lines edit:edit];
}

- (void)setSyntaxHighlighter:(id<SCESyntaxHighlighter>)syntaxHighlighter {
    if (_syntaxHighlighter == syntaxHighlighter) {
        return;
    }
    if ([_syntaxHighlighter respondsToSelector:@selector(cancelPendingRequests)]) {
        [_syntaxHighlighter cancelPendingRequests];
    }
    _syntaxHighlighter = syntaxHighlighter;
    _syntaxRequestID++;
    _hasSyntaxRequest = NO;
    [_layoutCache removeAllSyntaxTokens];
    [self updateViewport];
}

- (void)setSyntaxTheme:(SCESyntaxTheme *)syntaxTheme {
    _syntaxTheme = [syntaxTheme copy] ?: SCESyntaxTheme.defaultTheme;
    _layoutCache.syntaxTheme = _syntaxTheme;
    [self updateAppearance];
    [self updateViewport];
}

- (NSColor *)themeColor:(SCEEditorColorKey)key fallback:(NSColor *)fallback {
    return [_syntaxTheme editorColorForKey:key] ?: fallback;
}

- (NSColor *)activeSelectionColor {
    return [self themeColor:SCEEditorColorSelection fallback:NSColor.selectedTextBackgroundColor];
}

- (NSColor *)inactiveSelectionColor {
    NSColor *color = [_syntaxTheme editorColorForKey:SCEEditorColorInactiveSelection];
    if (color) {
        return color;
    }
    NSColor *selection = [_syntaxTheme editorColorForKey:SCEEditorColorSelection];
    return selection ? [selection colorWithAlphaComponent:selection.alphaComponent * 0.5]
                     : NSColor.unemphasizedSelectedTextBackgroundColor;
}

- (BOOL)hasOpaqueBackground {
    // A translucent text or gutter background shows what is behind the editor.
    NSColor *background = [_syntaxTheme editorColorForKey:SCEEditorColorBackground];
    NSColor *gutter = [_syntaxTheme editorColorForKey:SCEEditorColorGutterBackground];
    return (!background || background.alphaComponent >= 1) && (!gutter || gutter.alphaComponent >= 1);
}

- (NSColor *)themeBackgroundColor {
    return [self themeColor:SCEEditorColorBackground fallback:NSColor.textBackgroundColor];
}

- (void)requestSyntaxHighlightingForLines:(NSRange)lines edit:(SCETextEdit *)edit {
    id<SCESyntaxHighlighter> highlighter = _syntaxHighlighter;
    if (!highlighter) {
        return;
    }
    NSRange range = NSMakeRange(0, 0);
    if (lines.length) {
        NSRange first = [_buffer UTF16RangeOfLine:lines.location includingLineEnding:YES];
        NSRange last = [_buffer UTF16RangeOfLine:NSMaxRange(lines) - 1 includingLineEnding:YES];
        range = NSMakeRange(first.location, NSMaxRange(last) - first.location);
    }
    if (!edit && _hasSyntaxRequest && _requestedSyntaxRevision == _buffer.revision &&
        NSEqualRanges(range, _requestedSyntaxRange)) {
        return;
    }
    _hasSyntaxRequest = YES;
    _requestedSyntaxRevision = _buffer.revision;
    _requestedSyntaxRange = range;
    NSUInteger requestID = ++_syntaxRequestID;
    SCETextBuffer *snapshot = [_buffer copy];
    __weak SCEEditorView *weakSelf = self;
    [highlighter highlightBuffer:snapshot
                      UTF16Range:range
                       afterEdit:edit
                      completion:^(SCESyntaxHighlightResult *result) {
                          dispatch_async(dispatch_get_main_queue(), ^{
                              SCEEditorView *editor = weakSelf;
                              if (!editor || editor->_syntaxRequestID != requestID ||
                                  editor->_buffer.revision != snapshot.revision) {
                                  return;
                              }
                              // A nil result carries no highlight information, so the
                              // current colors remain instead of being cleared.
                              if (!result || result.revision != snapshot.revision ||
                                  !NSEqualRanges(result.coveredRange, range)) {
                                  return;
                              }
                              if ([editor->_layoutCache applySyntaxTokens:result.tokens toLineRange:lines]) {
                                  editor->_textSurface.needsDisplay = YES;
                              }
                              [NSNotificationCenter.defaultCenter
                                  postNotificationName:SCEEditorSyntaxHighlightingDidUpdateNotification
                                                object:editor];
                          });
                      }];
}

- (void)resetCursorRects {
    [self addCursorRect:self.visibleRect cursor:NSCursor.IBeamCursor];
    if (_hoveredLinkRange.location == NSNotFound) {
        return;
    }
    NSUInteger line = [_buffer lineIndexForUTF16Offset:_hoveredLinkRange.location];
    NSRange content = [_buffer UTF16RangeOfLine:line includingLineEnding:NO];
    NSRange local = NSMakeRange(_hoveredLinkRange.location - content.location, _hoveredLinkRange.length);
    SCELineLayout *layout = [_layoutCache layoutForLineAtIndex:line];
    NSRect textRect = NSIntersectionRect(
        self.visibleRect, NSMakeRect(NSMinX(_viewportRect) + self.gutterWidth, NSMinY(_viewportRect),
                                     MAX(0, NSWidth(_viewportRect) - self.gutterWidth), NSHeight(_viewportRect)));
    for (NSValue *value in [layout selectionRectsForUTF16Range:local height:_lineHeight]) {
        NSRect rect = NSOffsetRect(value.rectValue, self.textOriginX, SCEInset + line * _lineHeight);
        rect = NSIntersectionRect(rect, textRect);
        if (!NSIsEmptyRect(rect)) {
            [self addCursorRect:rect cursor:NSCursor.pointingHandCursor];
        }
    }
}

- (NSString *)string {
    return _buffer.string;
}

- (void)setString:(NSString *)string {
    [self invalidateDetectedLinks];
    SCETextBuffer *before = _syntaxHighlighter ? [_buffer copy] : nil;
    _markedRange = NSMakeRange(NSNotFound, 0);
    _compositionOriginalText = nil;
    [_textInputContext discardMarkedText];
    [_buffer replaceCharactersInUTF16Range:NSMakeRange(0, _buffer.lengthUTF16) withString:string ?: @""];
    if (before) {
        _pendingSyntaxEdit = [[SCETextEdit alloc] initWithRange:NSMakeRange(0, before.lengthUTF16)
                                            insertedLengthUTF16:_buffer.lengthUTF16
                                                   beforeBuffer:before
                                                    afterBuffer:_buffer];
    }
    [_editUndoManager removeAllActions];
    [_layoutCache removeAllLayouts];
    [_layoutCache removeAllSyntaxTokens];
    _searchMatchData.length = 0;
    [self setNeedsSearchUpdate];
    _maximumMeasuredWidth = 0;
    _head = 0;
    _anchor = _head;
    _preferredX = NAN;
    [self updateViewport];
    [self scrollPoint:NSZeroPoint];
    [self selectionDidChange];
    [NSNotificationCenter.defaultCenter postNotificationName:SCEEditorTextDidChangeNotification object:self];
}

- (SCETextBuffer *)bufferSnapshot {
    return [_buffer copy];
}

- (NSUInteger)lineCount {
    return _buffer.lineCount;
}

- (void)setFont:(NSFont *)font {
    if (!font || [_font isEqual:font]) {
        return;
    }
    _font = [font copy];
    _layoutCache.font = font;
    _scopeGuideX = NAN;
    _maximumMeasuredWidth = 0;
    [self updateFontMetrics];
    [self updateViewport];
    [self scrollSelectionToVisible];
}

- (void)setShowsLineNumbers:(BOOL)showsLineNumbers {
    _showsLineNumbers = showsLineNumbers;
    [self updateViewport];
}

- (void)setTabWidth:(NSUInteger)tabWidth {
    _tabWidth = MAX(1, MIN(tabWidth, 32));
    _layoutCache.tabWidth = _tabWidth;
    _scopeGuideX = NAN;
    _maximumMeasuredWidth = 0;
    [self updateViewport];
}

- (void)setShowsScopeGuide:(BOOL)showsScopeGuide {
    if (_showsScopeGuide == showsScopeGuide) {
        return;
    }
    _showsScopeGuide = showsScopeGuide;
    _hasScopeGuideState = NO;
    [self updateScopeGuide];
    _backgroundSurface.needsDisplay = YES;
}

- (NSRange)scopeGuideBracketRange {
    [self updateScopeGuide];
    return _scopeGuideBrackets;
}

- (void)updateScopeGuide {
    if (_hasScopeGuideState && _scopeGuideRevision == _buffer.revision && _scopeGuideHead == _head) {
        return;
    }
    _hasScopeGuideState = YES;
    _scopeGuideRevision = _buffer.revision;
    _scopeGuideHead = _head;
    _scopeGuideX = NAN;
    _scopeGuideBrackets = _showsScopeGuide && _focusable
                              ? SCEEnclosingMultilineBracketRange(_buffer, _head, SCEBracketScopeDefaultScanLimit)
                              : NSMakeRange(NSNotFound, 0);
    if (_scopeGuideBrackets.location != NSNotFound) {
        _scopeGuideOpenLine = [_buffer lineIndexForUTF16Offset:_scopeGuideBrackets.location];
        _scopeGuideCloseLine = [_buffer lineIndexForUTF16Offset:NSMaxRange(_scopeGuideBrackets) - 1];
    }
}

// The guide runs down the opening line's indentation, in text coordinates.
- (CGFloat)scopeGuideX {
    if (isnan(_scopeGuideX)) {
        NSRange content = [_buffer UTF16RangeOfLine:_scopeGuideOpenLine includingLineEnding:NO];
        NSString *text = [_buffer substringWithUTF16Range:content];
        NSUInteger indent = 0;
        while (indent < text.length &&
               ([text characterAtIndex:indent] == ' ' || [text characterAtIndex:indent] == '\t')) {
            indent++;
        }
        _scopeGuideX = [[_layoutCache layoutForLineAtIndex:_scopeGuideOpenLine] xForUTF16Index:indent];
    }
    return _scopeGuideX;
}

- (void)drawScopeGuideInSurface:(NSView *)surface {
    if (!_showsScopeGuide || !_focusable) {
        return;
    }
    [self updateScopeGuide];
    if (_scopeGuideBrackets.location == NSNotFound) {
        return;
    }
    CGFloat scale = self.window.backingScaleFactor ?: 2;
    CGFloat top = SCEInset + (_scopeGuideOpenLine + 1) * _lineHeight - NSMinY(_viewportRect);
    CGFloat bottom = SCEInset + _scopeGuideCloseLine * _lineHeight - NSMinY(_viewportRect);
    if (bottom <= 0 || top >= NSHeight(surface.bounds)) {
        return;
    }
    CGFloat x = round((self.textOriginX + self.scopeGuideX - NSMinX(_viewportRect)) * scale) / scale;
    CGFloat width = MAX(1 / scale, round(SCEScopeGuideWidth * scale) / scale);
    NSRect guide = NSMakeRect(x, MAX(top, -1), width, MIN(bottom, NSHeight(surface.bounds) + 1) - MAX(top, -1));
    // The pinned gutter covers the guide when scrolled horizontally.
    guide =
        NSIntersectionRect(guide, NSMakeRect(self.gutterWidth, -1, MAX(0, NSWidth(surface.bounds) - self.gutterWidth),
                                             NSHeight(surface.bounds) + 2));
    if (NSIsEmptyRect(guide)) {
        return;
    }
    [[self themeColor:SCEEditorColorScopeGuide fallback:NSColor.tertiaryLabelColor] setFill];
    NSRectFillUsingOperation(guide, NSCompositingOperationSourceOver);
}

- (void)setFocusable:(BOOL)focusable {
    if (_focusable == focusable) {
        return;
    }
    _focusable = focusable;
    if (!focusable && self.window.firstResponder == self) {
        [self.window makeFirstResponder:nil];
    }
    _hasScopeGuideState = NO;
    [self updateCaret];
    _backgroundSurface.needsDisplay = YES;
}

- (void)setEditable:(BOOL)editable {
    if (!editable) {
        [self unmarkText];
    }
    _editable = editable;
    [self updateCaret];
}

- (NSRange)selectedRange {
    return NSMakeRange(MIN(_anchor, _head), MAX(_anchor, _head) - MIN(_anchor, _head));
}

- (NSUInteger)normalizeOffset:(NSUInteger)offset forward:(BOOL)forward {
    offset = MIN(offset, _buffer.lengthUTF16);
    if (offset == _buffer.lengthUTF16) {
        return offset;
    }
    NSUInteger line = [_buffer lineIndexForUTF16Offset:offset];
    NSRange lineRange = [_buffer UTF16RangeOfLine:line includingLineEnding:YES];
    NSString *text = [_buffer substringWithUTF16Range:lineRange];
    NSUInteger local = offset - lineRange.location;
    if (local && [text characterAtIndex:local] == '\n' && [text characterAtIndex:local - 1] == '\r') {
        return forward ? offset + 1 : offset - 1;
    }
    NSRange cluster = [text rangeOfComposedCharacterSequenceAtIndex:local];
    if (cluster.location == local) {
        return offset;
    }
    return lineRange.location + (forward ? NSMaxRange(cluster) : cluster.location);
}

- (void)setSelectedRange:(NSRange)range {
    [self finishComposition];
    NSUInteger start = MIN(range.location, _buffer.lengthUTF16);
    NSUInteger end = start + MIN(range.length, _buffer.lengthUTF16 - start);
    [self setAnchor:[self normalizeOffset:start forward:NO]
               head:[self normalizeOffset:end forward:range.length > 0]
             scroll:YES
          preserveX:NO];
}

- (void)setAnchor:(NSUInteger)anchor head:(NSUInteger)head scroll:(BOOL)scroll preserveX:(BOOL)preserveX {
    _anchor = MIN(anchor, _buffer.lengthUTF16);
    _head = MIN(head, _buffer.lengthUTF16);
    if (!preserveX) {
        _preferredX = NAN;
    }
    [self selectionDidChange];
    if (scroll) {
        [self scrollSelectionToVisible];
    }
}

- (void)selectionDidChange {
    [self updateScopeGuide];
    _backgroundSurface.needsDisplay = YES;
    [self updateCaret];
    [_textInputContext invalidateCharacterCoordinates];
    [NSNotificationCenter.defaultCenter postNotificationName:SCEEditorSelectionDidChangeNotification object:self];
    NSAccessibilityPostNotification(self, NSAccessibilitySelectedTextChangedNotification);
}

- (NSRect)caretRectForUTF16Offset:(NSUInteger)offset {
    NSUInteger line = [_buffer lineIndexForUTF16Offset:offset];
    NSRange range = [_buffer UTF16RangeOfLine:line includingLineEnding:NO];
    SCELineLayout *layout = [_layoutCache layoutForLineAtIndex:line];
    _maximumMeasuredWidth = MAX(_maximumMeasuredWidth, layout.width);
    CGFloat x = self.textOriginX + [layout xForUTF16Index:MIN(offset - range.location, range.length)];
    return NSMakeRect(x, SCEInset + line * _lineHeight, 1, _lineHeight);
}

- (void)updateCaret {
    if (!_buffer) {
        return;
    }
    NSUInteger line = [_buffer lineIndexForUTF16Offset:_head];
    CGFloat y = SCEInset + line * _lineHeight;
    BOOL visible = y + _lineHeight > NSMinY(_viewportRect) && y < NSMaxY(_viewportRect);
    // Read-only documents keep the caret so that it can still be moved and extended into a selection.
    BOOL active = _focusable && visible && !self.selectedRange.length && self.window.isKeyWindow &&
                  self.window.firstResponder == self;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (visible) {
        NSRect rect = [self caretRectForUTF16Offset:_head];
        rect.origin.x -= NSMinX(_viewportRect);
        rect.origin.y -= NSMinY(_viewportRect);
        CGFloat scale = self.window.backingScaleFactor ?: 2;
        rect.size.width = round(SCECaretWidth * scale) / scale;
        rect.origin.x = round((rect.origin.x - rect.size.width / 2) * scale) / scale;
        rect.origin.y = round((rect.origin.y + 1) * scale) / scale;
        rect.size.height = round((rect.size.height - 2) * scale) / scale;
        if (!NSEqualRects(_caretIndicator.frame, rect)) {
            _caretIndicator.frame = rect;
        }
        if (rect.origin.x < self.gutterWidth || NSMinX(rect) >= NSWidth(_textSurface.bounds)) {
            active = NO;
        }
    }
    [CATransaction commit];
    [self setCaretVisible:active];
}

- (void)setCaretVisible:(BOOL)visible {
    NSTextInsertionIndicatorDisplayMode mode =
        visible ? NSTextInsertionIndicatorDisplayModeAutomatic : NSTextInsertionIndicatorDisplayModeHidden;
    if (_caretIndicator.displayMode != mode) {
        _caretIndicator.displayMode = mode;
    }
}

- (void)scrollSelectionToVisible {
    NSRect rect = [self caretRectForUTF16Offset:_head];
    CGFloat width = self.textOriginX + _maximumMeasuredWidth + SCEInset;
    if (self.enclosingScrollView && width > NSWidth(self.frame)) {
        [self setFrameSize:NSMakeSize(width, NSHeight(self.frame))];
    }
    if (_head == 0) {
        [self scrollPoint:NSZeroPoint];
        [self updateCaret];
        return;
    }
    // Leave room for the pinned gutter when horizontally scrolling the caret.
    rect.origin.x -= self.gutterWidth + 8;
    rect.size.width += self.gutterWidth + 16;
    rect = NSInsetRect(rect, 0, -4);
    [self scrollRectToVisible:rect];
    [self updateCaret];
}

static void SCEDrawCTLine(CGContextRef context, CTLineRef line, CGFloat x, CGFloat baseline) {
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, x, baseline);
    CGContextScaleCTM(context, 1, -1);
    CGContextSetTextMatrix(context, CGAffineTransformIdentity);
    CGContextSetTextPosition(context, 0, 0);
    CTLineDraw(line, context);
    CGContextRestoreGState(context);
}

- (void)drawTextSurface:(NSView *)surface {
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGFloat scale = self.window.backingScaleFactor ?: 2;
    NSRange visible = [SCEViewport lineRangeForVisibleRect:_viewportRect
                                                 lineCount:_buffer.lineCount
                                                lineHeight:_lineHeight
                                                  topInset:SCEInset
                                                  overscan:0];
    CGFloat originX = self.textOriginX - NSMinX(_viewportRect);
    CGContextSaveGState(context);
    CGContextClipToRect(context, NSMakeRect(self.gutterWidth, 0, MAX(0, NSWidth(surface.bounds) - self.gutterWidth),
                                            NSHeight(surface.bounds)));
    for (NSUInteger i = visible.location; i < NSMaxRange(visible); i++) {
        SCELineLayout *layout = [_layoutCache layoutForLineAtIndex:i];
        CGFloat y = SCEInset + i * _lineHeight - NSMinY(_viewportRect);
        CGFloat baseline = round((y + _baseline) * scale) / scale;
        SCEDrawCTLine(context, layout.line, originX, baseline);
        if (_hoveredLinkRange.location != NSNotFound) {
            NSRange lineRange = [_buffer UTF16RangeOfLine:i includingLineEnding:NO];
            NSRange overlap = NSIntersectionRange(lineRange, _hoveredLinkRange);
            if (overlap.length) {
                NSRange local = NSMakeRange(overlap.location - lineRange.location, overlap.length);
                [_layoutCache.textColor setFill];
                for (NSValue *value in [layout selectionRectsForUTF16Range:local height:_lineHeight]) {
                    NSRect rect = value.rectValue;
                    NSRectFill(NSMakeRect(originX + rect.origin.x, baseline + 2, rect.size.width, 1));
                }
            }
        }
        if ([self hasMarkedText]) {
            NSRange lineRange = [_buffer UTF16RangeOfLine:i includingLineEnding:NO];
            NSRange overlap = NSIntersectionRange(lineRange, _markedRange);
            if (overlap.length) {
                NSRange local = NSMakeRange(overlap.location - lineRange.location, overlap.length);
                [_layoutCache.textColor setFill];
                for (NSValue *value in [layout selectionRectsForUTF16Range:local height:_lineHeight]) {
                    NSRect rect = value.rectValue;
                    NSRectFill(NSMakeRect(originX + rect.origin.x, baseline + 2, rect.size.width, 1));
                }
            }
        }
    }
    CGContextRestoreGState(context);
    if (_showsLineNumbers) {
        NSDictionary *attrs = @{
            NSFontAttributeName : _lineNumberFont,
            NSForegroundColorAttributeName : [self themeColor:SCEEditorColorLineNumber
                                                     fallback:NSColor.secondaryLabelColor],
        };
        for (NSUInteger i = visible.location; i < NSMaxRange(visible); i++) {
            NSAttributedString *number =
                [[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%lu", (unsigned long)i + 1]
                                                attributes:attrs];
            CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)number);
            CGFloat width = (CGFloat)CTLineGetTypographicBounds(line, NULL, NULL, NULL);
            CGFloat y = SCEInset + i * _lineHeight - NSMinY(_viewportRect);
            CGFloat baseline = round((y + _lineNumberBaseline) * scale) / scale;
            SCEDrawCTLine(context, line, round((self.gutterWidth - width - 10) * scale) / scale, baseline);
            CFRelease(line);
        }
    }
}

- (void)drawBackgroundSurface:(NSView *)surface {
    NSColor *background = self.themeBackgroundColor;
    [background setFill];
    NSRectFill(surface.bounds);
    if (_showsLineNumbers) {
        [[self themeColor:SCEEditorColorGutterBackground fallback:NSColor.windowBackgroundColor] setFill];
        NSRectFill(NSMakeRect(0, 0, self.gutterWidth, NSHeight(surface.bounds)));
    }
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(context);
    NSRange selection = self.selectedRange;
    if (!selection.length && _focusable) {
        NSUInteger line = [_buffer lineIndexForUTF16Offset:_head];
        NSRect rect = NSMakeRect(SCEHighlightHorizontalPadding, SCEInset + line * _lineHeight - NSMinY(_viewportRect),
                                 MAX(0, NSWidth(surface.bounds) - 2 * SCEHighlightHorizontalPadding), _lineHeight);
        // One fill keeps the highlight uniform across the gutter and text.
        NSColor *highlight = [self themeColor:SCEEditorColorCurrentLine
                                     fallback:[background blendedColorWithFraction:0.035
                                                                           ofColor:_layoutCache.textColor]];
        [highlight setFill];
        CGPathRef path = SCECreateSelectionPath(@[ [NSValue valueWithRect:rect] ], SCECurrentLineCornerRadius);
        CGContextSetShouldAntialias(context, YES);
        CGContextAddPath(context, path);
        CGContextFillPath(context);
        CGPathRelease(path);
    } else if (selection.length) {
        CGFloat rightEdge = MAX(self.gutterWidth, NSWidth(surface.bounds) - SCEHighlightHorizontalPadding);
        NSRect selectionBounds =
            NSMakeRect(self.gutterWidth, 0, rightEdge - self.gutterWidth, NSHeight(surface.bounds));
        CGContextClipToRect(context, selectionBounds);
        BOOL active = self.window.isKeyWindow && self.window.firstResponder == self;
        [(active ? self.activeSelectionColor : self.inactiveSelectionColor) setFill];
        NSMutableArray<NSValue *> *selectionRects = [NSMutableArray array];
        CGFloat cornerRadius = MIN(4, _lineHeight * 0.2);
        NSRect geometryBounds = NSInsetRect(selectionBounds, -cornerRadius * 3, -_lineHeight * 2);
        // Round at the inset right edge while retaining overscan elsewhere.
        geometryBounds.size.width = rightEdge - NSMinX(geometryBounds);
        NSRange visible = [SCEViewport lineRangeForVisibleRect:_viewportRect
                                                     lineCount:_buffer.lineCount
                                                    lineHeight:_lineHeight
                                                      topInset:SCEInset
                                                      overscan:1];
        for (NSUInteger i = visible.location; i < NSMaxRange(visible); i++) {
            NSRange wholeLine = [_buffer UTF16RangeOfLine:i includingLineEnding:YES];
            NSRange overlap = NSIntersectionRange(wholeLine, selection);
            if (!overlap.length) {
                continue;
            }
            NSRange content = [_buffer UTF16RangeOfLine:i includingLineEnding:NO];
            NSRange textOverlap = NSIntersectionRange(content, selection);
            SCELineLayout *layout = [_layoutCache layoutForLineAtIndex:i];
            CGFloat y = SCEInset + i * _lineHeight - NSMinY(_viewportRect);
            CGFloat x = self.textOriginX - NSMinX(_viewportRect);
            if (textOverlap.length) {
                NSRange local = NSMakeRange(textOverlap.location - content.location, textOverlap.length);
                for (NSValue *value in [layout selectionRectsForUTF16Range:local height:_lineHeight]) {
                    NSRect rect = value.rectValue;
                    rect.origin.x += x;
                    rect.origin.y += y;
                    rect = NSIntersectionRect(rect, geometryBounds);
                    if (!NSIsEmptyRect(rect)) {
                        [selectionRects addObject:[NSValue valueWithRect:rect]];
                    }
                }
            }
            if (NSMaxRange(overlap) > NSMaxRange(content)) {
                CGFloat endX = x + [layout xForUTF16Index:content.length];
                NSRect rect =
                    NSIntersectionRect(NSMakeRect(endX, y, MAX(0, rightEdge - endX), _lineHeight), geometryBounds);
                if (!NSIsEmptyRect(rect)) {
                    [selectionRects addObject:[NSValue valueWithRect:rect]];
                }
            }
        }
        // Trace the union first, then smooth all exposed turns, including
        // concave row junctions. One antialiased fill has no internal seams.
        CGPathRef selectionPath = SCECreateSelectionPath(selectionRects, cornerRadius);
        CGContextSetShouldAntialias(context, YES);
        CGContextAddPath(context, selectionPath);
        CGContextFillPath(context);
        CGPathRelease(selectionPath);
    }
    CGContextRestoreGState(context);
    [self drawSearchMatchesInSurface:surface];
    [self drawScopeGuideInSurface:surface];
}

// MARK: Search

- (void)setSearchQuery:(SCETextSearchQuery *)searchQuery {
    if (_searchQuery == searchQuery || [_searchQuery isEqual:searchQuery]) {
        return;
    }
    _searchQuery = [searchQuery copy];
    if (_searchQuery) {
        [self setNeedsSearchUpdate];
        return;
    }
    [self cancelSearchRequest];
    _searchPending = NO;
    _searchError = nil;
    _searchResultTruncated = NO;
    _searchMatchData.length = 0;
    _backgroundSurface.needsDisplay = YES;
    [NSNotificationCenter.defaultCenter postNotificationName:SCEEditorSearchResultsDidChangeNotification object:self];
}

- (void)cancelSearchRequest {
    _searchRequest.cancelled = YES;
    _searchRequest = nil;
    _searchRequestID++;
}

// Marks the results stale and starts one search after the current event, so
// that several edits in one event produce one search.
- (void)setNeedsSearchUpdate {
    if (!_searchQuery) {
        return;
    }
    [self cancelSearchRequest];
    _searchPending = YES;
    if (_searchUpdateScheduled) {
        return;
    }
    _searchUpdateScheduled = YES;
    __weak SCEEditorView *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        SCEEditorView *editor = weakSelf;
        if (!editor) {
            return;
        }
        editor->_searchUpdateScheduled = NO;
        if (editor->_searchPending && editor->_searchQuery && !editor->_searchRequest) {
            [editor startSearchRequest];
        }
    });
}

- (void)startSearchRequest {
    [self cancelSearchRequest];
    SCETextSearchRequest *request = [[SCETextSearchRequest alloc] init];
    _searchRequest = request;
    NSUInteger requestID = _searchRequestID;
    SCETextSearchQuery *query = _searchQuery;
    SCETextBuffer *snapshot = [_buffer copy];
    __weak SCEEditorView *weakSelf = self;
    dispatch_async(_searchQueue, ^{
        if (request.isCancelled) {
            return;
        }
        NSError *error = nil;
        NSData *matches = [query rangeDataOfMatchesInString:snapshot.string
                                               maximumCount:SCETextSearchDefaultMaximumMatchCount
                                                isCancelled:^BOOL {
                                                    return request.isCancelled;
                                                }
                                                      error:&error];
        if (!matches && !error) {
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            SCEEditorView *editor = weakSelf;
            if (!editor || editor->_searchRequestID != requestID || editor->_buffer.revision != snapshot.revision) {
                return;
            }
            [editor applySearchMatchData:matches error:error];
        });
    });
}

- (void)applySearchMatchData:(NSData *)matches error:(NSError *)error {
    _searchRequest = nil;
    _searchPending = NO;
    _searchError = error;
    _searchMatchData = matches ? [matches mutableCopy] : [NSMutableData data];
    _searchResultTruncated = self.numberOfSearchMatches >= SCETextSearchDefaultMaximumMatchCount;
    _backgroundSurface.needsDisplay = YES;
    [NSNotificationCenter.defaultCenter postNotificationName:SCEEditorSearchResultsDidChangeNotification object:self];
}

// Navigation needs results for the current text, so a pending search runs
// synchronously on the main thread instead of waiting for the search queue.
- (void)updateSearchResultsIfNeeded {
    if (!_searchPending || !_searchQuery) {
        return;
    }
    [self cancelSearchRequest];
    NSError *error = nil;
    NSData *matches = [_searchQuery rangeDataOfMatchesInString:_buffer.string
                                                  maximumCount:SCETextSearchDefaultMaximumMatchCount
                                                   isCancelled:nil
                                                         error:&error];
    [self applySearchMatchData:matches error:error];
}

// Keeps unaffected matches aligned with the text until new results arrive.
// Matches that intersect the replaced range are removed.
- (void)moveSearchMatchesForReplacementOfUTF16Range:(NSRange)range replacementLength:(NSUInteger)replacementLength {
    if (!_searchQuery) {
        return;
    }
    NSRange *matches = _searchMatchData.mutableBytes;
    NSUInteger count = _searchMatchData.length / sizeof(NSRange);
    NSUInteger retainedCount = 0;
    for (NSUInteger index = 0; index < count; index++) {
        NSRange match = matches[index];
        if (NSMaxRange(match) <= range.location) {
            matches[retainedCount++] = match;
        } else if (match.location >= NSMaxRange(range)) {
            match.location = match.location - range.length + replacementLength;
            matches[retainedCount++] = match;
        }
    }
    _searchMatchData.length = retainedCount * sizeof(NSRange);
    [self setNeedsSearchUpdate];
}

- (NSUInteger)numberOfSearchMatches {
    return _searchMatchData.length / sizeof(NSRange);
}

- (NSArray<NSValue *> *)searchMatchRanges {
    const NSRange *matches = _searchMatchData.bytes;
    NSUInteger count = self.numberOfSearchMatches;
    NSMutableArray<NSValue *> *values = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger index = 0; index < count; index++) {
        [values addObject:[NSValue valueWithRange:matches[index]]];
    }
    return values;
}

- (NSUInteger)currentSearchMatchIndex {
    NSRange selection = self.selectedRange;
    if (!selection.length) {
        return NSNotFound;
    }
    const NSRange *matches = _searchMatchData.bytes;
    NSUInteger count = self.numberOfSearchMatches;
    NSUInteger index = SCEIndexOfFirstRangeStartingAtOrAfter(matches, count, selection.location);
    return index < count && NSEqualRanges(matches[index], selection) ? index : NSNotFound;
}

- (BOOL)selectNextSearchMatch {
    [self updateSearchResultsIfNeeded];
    NSUInteger count = self.numberOfSearchMatches;
    if (!count) {
        return NO;
    }
    const NSRange *matches = _searchMatchData.bytes;
    NSRange selection = self.selectedRange;
    NSUInteger offset = selection.length ? NSMaxRange(selection) : selection.location;
    NSUInteger index = SCEIndexOfFirstRangeStartingAtOrAfter(matches, count, offset);
    self.selectedRange = matches[index < count ? index : 0];
    return YES;
}

- (BOOL)selectPreviousSearchMatch {
    [self updateSearchResultsIfNeeded];
    NSUInteger count = self.numberOfSearchMatches;
    if (!count) {
        return NO;
    }
    const NSRange *matches = _searchMatchData.bytes;
    NSUInteger index = SCEIndexOfFirstRangeEndingAfter(matches, count, self.selectedRange.location);
    self.selectedRange = matches[index > 0 ? index - 1 : count - 1];
    return YES;
}

// Highlights the matches on visible lines. Each line is located with a binary
// search, so drawing cost is independent of the total match count.
- (void)drawSearchMatchesInSurface:(NSView *)surface {
    NSUInteger count = self.numberOfSearchMatches;
    if (!count) {
        return;
    }
    const NSRange *matches = _searchMatchData.bytes;
    NSRange visible = [SCEViewport lineRangeForVisibleRect:_viewportRect
                                                 lineCount:_buffer.lineCount
                                                lineHeight:_lineHeight
                                                  topInset:SCEInset
                                                  overscan:0];
    if (!visible.length) {
        return;
    }
    NSUInteger visibleStart = [_buffer UTF16RangeOfLine:visible.location includingLineEnding:YES].location;
    NSUInteger index = SCEIndexOfFirstRangeEndingAfter(matches, count, visibleStart);
    if (index == count) {
        return;
    }
    NSUInteger currentIndex = self.currentSearchMatchIndex;
    NSColor *matchColor = [self themeColor:SCEEditorColorSearchMatch
                                  fallback:[NSColor.systemYellowColor colorWithAlphaComponent:0.28]];
    NSColor *currentColor = [self themeColor:SCEEditorColorCurrentSearchMatch
                                    fallback:[NSColor.findHighlightColor colorWithAlphaComponent:0.6]];
    NSColor *currentBorderColor = [self themeColor:SCEEditorColorCurrentSearchMatchBorder
                                          fallback:NSColor.systemYellowColor];
    CGFloat lineEndingWidth = ceil(_font.pointSize * 0.5);
    CGFloat originX = self.textOriginX - NSMinX(_viewportRect);
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(context);
    CGContextClipToRect(context, NSMakeRect(self.gutterWidth, 0, MAX(0, NSWidth(surface.bounds) - self.gutterWidth),
                                            NSHeight(surface.bounds)));
    for (NSUInteger line = visible.location; line < NSMaxRange(visible) && index < count; line++) {
        NSRange wholeLine = [_buffer UTF16RangeOfLine:line includingLineEnding:YES];
        NSRange content = [_buffer UTF16RangeOfLine:line includingLineEnding:NO];
        CGFloat y = SCEInset + line * _lineHeight - NSMinY(_viewportRect);
        SCELineLayout *layout = nil;
        for (NSUInteger matchIndex = index; matchIndex < count && matches[matchIndex].location < NSMaxRange(wholeLine);
             matchIndex++) {
            NSRange match = matches[matchIndex];
            layout = layout ?: [_layoutCache layoutForLineAtIndex:line];
            NSMutableArray<NSValue *> *rects = [NSMutableArray array];
            NSRange textOverlap = NSIntersectionRange(match, content);
            if (textOverlap.length) {
                NSRange local = NSMakeRange(textOverlap.location - content.location, textOverlap.length);
                [rects addObjectsFromArray:[layout selectionRectsForUTF16Range:local height:_lineHeight]];
            }
            // A match that includes the line ending extends past the last character.
            if (NSMaxRange(match) > NSMaxRange(content) && match.location <= NSMaxRange(content) &&
                NSMaxRange(wholeLine) > NSMaxRange(content)) {
                CGFloat endX = [layout xForUTF16Index:content.length];
                [rects addObject:[NSValue valueWithRect:NSMakeRect(endX, 0, lineEndingWidth, _lineHeight)]];
            }
            BOOL isCurrent = matchIndex == currentIndex;
            for (NSValue *value in rects) {
                NSRect rect = NSInsetRect(NSOffsetRect(value.rectValue, originX, y), -1, 1);
                NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:rect
                                                                     xRadius:SCESearchMatchCornerRadius
                                                                     yRadius:SCESearchMatchCornerRadius];
                [(isCurrent ? currentColor : matchColor) setFill];
                [path fill];
                if (isCurrent) {
                    [currentBorderColor setStroke];
                    path.lineWidth = 1;
                    [path stroke];
                }
            }
        }
        while (index < count && NSMaxRange(matches[index]) <= NSMaxRange(wholeLine)) {
            index++;
        }
    }
    CGContextRestoreGState(context);
}

// MARK: Editing transactions

- (NSRange)clampedRange:(NSRange)range {
    NSUInteger location = MIN(range.location, _buffer.lengthUTF16);
    return NSMakeRange(location, MIN(range.length, _buffer.lengthUTF16 - location));
}

- (void)registerUndoForRange:(NSRange)range text:(NSString *)text selection:(NSRange)selection {
    BOOL openGroup = _editUndoManager.groupingLevel == 0;
    if (openGroup) {
        [_editUndoManager beginUndoGrouping];
    }
    [_editUndoManager registerUndoWithTarget:self
                                     handler:^(SCEEditorView *target) {
                                         [target replaceRange:range
                                                   withString:text
                                               selectionAfter:selection
                                                 registerUndo:YES];
                                     }];
    [_editUndoManager setActionName:NSLocalizedString(@"Typing", nil)];
    if (openGroup) {
        [_editUndoManager endUndoGrouping];
    }
}

- (void)replaceRange:(NSRange)range
          withString:(NSString *)text
      selectionAfter:(NSRange)selection
        registerUndo:(BOOL)registerUndo {
    range = [self clampedRange:range];
    NSString *removed = [_buffer substringWithUTF16Range:range];
    NSRange previousSelection = self.selectedRange;
    if (registerUndo && ![removed isEqualToString:text]) {
        [self registerUndoForRange:NSMakeRange(range.location, text.length) text:removed selection:previousSelection];
    }
    // Rope snapshots share storage, so capturing the pre-edit buffer is constant time.
    SCETextBuffer *before = [_buffer copy];
    [self invalidateDetectedLinks];
    [_buffer replaceCharactersInUTF16Range:range withString:text];
    if (_syntaxHighlighter) {
        _pendingSyntaxEdit = [[SCETextEdit alloc] initWithRange:range
                                            insertedLengthUTF16:text.length
                                                   beforeBuffer:before
                                                    afterBuffer:_buffer];
    }
    [_layoutCache invalidateForReplacementOfUTF16Range:range replacementLength:text.length previousBuffer:before];
    [self moveSearchMatchesForReplacementOfUTF16Range:range replacementLength:text.length];
    NSRange after = [self clampedRange:selection];
    _anchor = after.location;
    _head = NSMaxRange(after);
    _preferredX = NAN;
    [self updateViewport];
    [self selectionDidChange];
    [self scrollSelectionToVisible];
    [NSNotificationCenter.defaultCenter postNotificationName:SCEEditorTextDidChangeNotification object:self];
    NSAccessibilityPostNotification(self, NSAccessibilityValueChangedNotification);
}

- (void)finishComposition {
    [self unmarkText];
    [_textInputContext discardMarkedText];
}

- (void)insertText:(id)value replacementRange:(NSRange)replacementRange {
    if (!_editable) {
        return;
    }
    NSString *text = [value isKindOfClass:NSAttributedString.class] ? [value string] : value;
    if (![text isKindOfClass:NSString.class]) {
        return;
    }
    if ([self hasMarkedText] &&
        (replacementRange.location == NSNotFound || NSEqualRanges(replacementRange, _markedRange))) {
        NSRange marked = _markedRange;
        [self replaceRange:marked
                withString:text
            selectionAfter:NSMakeRange(marked.location + text.length, 0)
              registerUndo:NO];
        _markedRange = NSMakeRange(marked.location, text.length);
        [self unmarkText];
    } else {
        [self unmarkText];
        NSRange range =
            replacementRange.location == NSNotFound ? self.selectedRange : [self clampedRange:replacementRange];
        [self replaceRange:range
                withString:text
            selectionAfter:NSMakeRange(range.location + text.length, 0)
              registerUndo:YES];
    }
}

- (void)insertText:(id)value {
    [self insertText:value replacementRange:NSMakeRange(NSNotFound, 0)];
}

- (void)setMarkedText:(id)value selectedRange:(NSRange)selection replacementRange:(NSRange)replacementRange {
    if (!_editable) {
        return;
    }
    NSString *text = [value isKindOfClass:NSAttributedString.class] ? [value string] : value;
    if (![text isKindOfClass:NSString.class]) {
        return;
    }
    if ([self hasMarkedText] && replacementRange.location != NSNotFound &&
        !NSEqualRanges(replacementRange, _markedRange)) {
        [self unmarkText];
    }
    NSRange range = replacementRange.location != NSNotFound
                        ? [self clampedRange:replacementRange]
                        : ([self hasMarkedText] ? _markedRange : self.selectedRange);
    if (![self hasMarkedText]) {
        _compositionOriginalText = [_buffer substringWithUTF16Range:range];
        _compositionOriginalSelection = self.selectedRange;
    }
    NSUInteger start = MIN(selection.location, text.length);
    NSUInteger length = MIN(selection.length, text.length - start);
    _markedRange = NSMakeRange(range.location, text.length);
    [self replaceRange:range
            withString:text
        selectionAfter:NSMakeRange(range.location + start, length)
          registerUndo:NO];
}

- (BOOL)hasMarkedText {
    return _markedRange.location != NSNotFound;
}

- (NSRange)markedRange {
    return _markedRange;
}

- (void)unmarkText {
    if (![self hasMarkedText]) {
        return;
    }
    NSRange finalRange = _markedRange;
    NSString *original = _compositionOriginalText ?: @"";
    NSRange originalSelection = _compositionOriginalSelection;
    _markedRange = NSMakeRange(NSNotFound, 0);
    _compositionOriginalText = nil;
    if (![original isEqualToString:[_buffer substringWithUTF16Range:finalRange]]) {
        [self registerUndoForRange:finalRange text:original selection:originalSelection];
    }
    _textSurface.needsDisplay = YES;
    [_textInputContext invalidateCharacterCoordinates];
}

- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText {
    return @[];
}

- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    if (range.location == NSNotFound || range.location > _buffer.lengthUTF16) {
        if (actualRange) {
            *actualRange = NSMakeRange(NSNotFound, 0);
        }
        return nil;
    }
    range = [self clampedRange:range];
    range.length = MIN(range.length, 16384);
    if (actualRange) {
        *actualRange = range;
    }
    return [[NSAttributedString alloc] initWithString:[_buffer substringWithUTF16Range:range]
                                           attributes:@{
                                               NSFontAttributeName : _font,
                                           }];
}

- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    range = [self clampedRange:range];
    NSUInteger line = [_buffer lineIndexForUTF16Offset:range.location];
    NSRange content = [_buffer UTF16RangeOfLine:line includingLineEnding:NO];
    NSUInteger start = MIN(range.location, NSMaxRange(content));
    NSUInteger end = MIN(NSMaxRange(range), NSMaxRange(content));
    if (actualRange) {
        *actualRange = NSMakeRange(start, end - start);
    }
    SCELineLayout *layout = [_layoutCache layoutForLineAtIndex:line];
    CGFloat x1 = [layout xForUTF16Index:start - content.location];
    CGFloat x2 = [layout xForUTF16Index:end - content.location];
    NSRect rect =
        NSMakeRect(self.textOriginX + MIN(x1, x2), SCEInset + line * _lineHeight, MAX(1, fabs(x2 - x1)), _lineHeight);
    return self.window ? [self.window convertRectToScreen:[self convertRect:rect toView:nil]] : NSZeroRect;
}

- (NSUInteger)UTF16OffsetForDocumentPoint:(NSPoint)point {
    if (point.y >= SCEInset + _buffer.lineCount * _lineHeight) {
        return _buffer.lengthUTF16;
    }
    CGFloat row = floor(MAX(0, point.y - SCEInset) / _lineHeight);
    NSUInteger line = (NSUInteger)MIN(row, (CGFloat)(_buffer.lineCount - 1));
    NSRange range = [_buffer UTF16RangeOfLine:line includingLineEnding:NO];
    return range.location + [[_layoutCache layoutForLineAtIndex:line] UTF16IndexForX:point.x - self.textOriginX];
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point {
    if (!self.window) {
        return NSNotFound;
    }
    NSPoint windowPoint = [self.window convertPointFromScreen:point];
    return [self UTF16OffsetForDocumentPoint:[self convertPoint:windowPoint fromView:nil]];
}

- (NSInteger)windowLevel {
    return self.window.level;
}

- (BOOL)drawsVerticallyForCharacterAtIndex:(NSUInteger)index {
    return NO;
}

- (void)keyDown:(NSEvent *)event {
    [self interpretKeyEvents:@[ event ]];
}

- (void)doCommandBySelector:(SEL)selector {
    if ([self respondsToSelector:selector]) {
        void (*invoke)(id, SEL, id) = (void (*)(id, SEL, id))[self methodForSelector:selector];
        invoke(self, selector, nil);
    } else {
        [super doCommandBySelector:selector];
    }
}

// MARK: Standard editing commands

- (void)undo:(id)sender {
    [self finishComposition];
    if (_editable) {
        [_editUndoManager undo];
    }
}

- (void)redo:(id)sender {
    [self finishComposition];
    if (_editable) {
        [_editUndoManager redo];
    }
}

- (void)copy:(id)sender {
    if (!self.selectedRange.length) {
        return;
    }
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    [pasteboard setString:[_buffer substringWithUTF16Range:self.selectedRange] forType:NSPasteboardTypeString];
}

- (void)cut:(id)sender {
    if (_editable && self.selectedRange.length) {
        [self copy:sender];
        [self deleteBackward:sender];
    }
}

- (void)paste:(id)sender {
    NSString *text = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
    if (_editable && text) {
        [self insertText:text replacementRange:NSMakeRange(NSNotFound, 0)];
    }
}

- (void)delete:(id)sender {
    if (_editable && self.selectedRange.length) {
        [self finishComposition];
        [self deleteRange:self.selectedRange];
    }
}

- (void)selectAll:(id)sender {
    [self finishComposition];
    [self setAnchor:0 head:_buffer.lengthUTF16 scroll:NO preserveX:NO];
}

- (NSUInteger)previousBoundary:(NSUInteger)offset {
    if (!offset) {
        return 0;
    }
    NSUInteger line = [_buffer lineIndexForUTF16Offset:offset - 1];
    NSRange range = [_buffer UTF16RangeOfLine:line includingLineEnding:YES];
    NSString *text = [_buffer substringWithUTF16Range:range];
    NSUInteger local = offset - range.location;
    if (local >= 2 && [text characterAtIndex:local - 1] == '\n' && [text characterAtIndex:local - 2] == '\r') {
        return offset - 2;
    }
    return range.location + [text rangeOfComposedCharacterSequenceAtIndex:local - 1].location;
}

- (NSUInteger)nextBoundary:(NSUInteger)offset {
    if (offset >= _buffer.lengthUTF16) {
        return _buffer.lengthUTF16;
    }
    NSUInteger line = [_buffer lineIndexForUTF16Offset:offset];
    NSRange range = [_buffer UTF16RangeOfLine:line includingLineEnding:YES];
    NSString *text = [_buffer substringWithUTF16Range:range];
    NSUInteger local = offset - range.location;
    if (local + 1 < text.length && [text characterAtIndex:local] == '\r' && [text characterAtIndex:local + 1] == '\n') {
        return offset + 2;
    }
    return range.location + NSMaxRange([text rangeOfComposedCharacterSequenceAtIndex:local]);
}

- (void)deleteRange:(NSRange)range {
    if (_editable && range.length) {
        [self replaceRange:range withString:@"" selectionAfter:NSMakeRange(range.location, 0) registerUndo:YES];
    }
}

- (void)deleteBackward:(id)sender {
    if (!_editable) {
        return;
    }
    [self finishComposition];
    NSRange range = self.selectedRange;
    if (!range.length) {
        NSUInteger before = [self previousBoundary:_head];
        range = NSMakeRange(before, _head - before);
    }
    [self deleteRange:range];
}

- (void)deleteForward:(id)sender {
    if (!_editable) {
        return;
    }
    [self finishComposition];
    NSRange range = self.selectedRange;
    if (!range.length) {
        range = NSMakeRange(_head, [self nextBoundary:_head] - _head);
    }
    [self deleteRange:range];
}

- (void)insertNewline:(id)sender {
    if (!_editable) {
        return;
    }
    [self finishComposition];
    NSUInteger line = [_buffer lineIndexForUTF16Offset:self.selectedRange.location];
    NSRange range = [_buffer UTF16RangeOfLine:line includingLineEnding:YES];
    NSString *text = [_buffer substringWithUTF16Range:range];
    NSUInteger maxIndent = MIN(self.selectedRange.location - range.location, text.length);
    NSUInteger indent = 0;
    if (_automaticIndentationEnabled) {
        while (indent < maxIndent && ([text characterAtIndex:indent] == ' ' || [text
                                                                                   characterAtIndex:indent] == '\t')) {
            indent++;
        }
    }
    NSString *ending = [text hasSuffix:@"\r\n"] ? @"\r\n" : @"\n";
    if (![text hasSuffix:@"\n"] && _buffer.lineCount > 1) {
        NSString *first = [_buffer substringWithUTF16Range:[_buffer UTF16RangeOfLine:0 includingLineEnding:YES]];
        if ([first hasSuffix:@"\r\n"]) {
            ending = @"\r\n";
        }
    }
    [self insertText:[ending stringByAppendingString:[text substringToIndex:indent]]
        replacementRange:NSMakeRange(NSNotFound, 0)];
}

- (void)insertTab:(id)sender {
    [self insertText:@"\t" replacementRange:NSMakeRange(NSNotFound, 0)];
}

- (void)cancelOperation:(id)sender {
    if (![self hasMarkedText]) {
        return;
    }
    NSRange range = _markedRange;
    NSString *original = _compositionOriginalText ?: @"";
    NSRange selection = _compositionOriginalSelection;
    _markedRange = NSMakeRange(NSNotFound, 0);
    _compositionOriginalText = nil;
    [_textInputContext discardMarkedText];
    [self replaceRange:range withString:original selectionAfter:selection registerUndo:NO];
}

// MARK: Navigation

- (void)moveToOffset:(NSUInteger)offset extending:(BOOL)extending preserveX:(BOOL)preserveX {
    [self finishComposition];
    [self setAnchor:extending ? _anchor : offset head:offset scroll:YES preserveX:preserveX];
}

- (void)moveHorizontal:(BOOL)forward extending:(BOOL)extending {
    NSRange selection = self.selectedRange;
    NSUInteger offset = !extending && selection.length
                            ? (forward ? NSMaxRange(selection) : selection.location)
                            : (forward ? [self nextBoundary:_head] : [self previousBoundary:_head]);
    [self moveToOffset:offset extending:extending preserveX:NO];
}

- (void)moveLeft:(id)sender {
    [self moveHorizontal:NO extending:NO];
}

- (void)moveRight:(id)sender {
    [self moveHorizontal:YES extending:NO];
}

- (void)moveLeftAndModifySelection:(id)sender {
    [self moveHorizontal:NO extending:YES];
}

- (void)moveRightAndModifySelection:(id)sender {
    [self moveHorizontal:YES extending:YES];
}

- (void)moveBackward:(id)sender {
    [self moveLeft:sender];
}

- (void)moveForward:(id)sender {
    [self moveRight:sender];
}

- (void)moveBackwardAndModifySelection:(id)sender {
    [self moveLeftAndModifySelection:sender];
}

- (void)moveForwardAndModifySelection:(id)sender {
    [self moveRightAndModifySelection:sender];
}

- (void)moveVertical:(NSInteger)delta extending:(BOOL)extending {
    NSUInteger line = [_buffer lineIndexForUTF16Offset:_head];
    NSRange range = [_buffer UTF16RangeOfLine:line includingLineEnding:NO];
    if (isnan(_preferredX)) {
        _preferredX =
            [[_layoutCache layoutForLineAtIndex:line] xForUTF16Index:MIN(_head - range.location, range.length)];
    }
    NSInteger target = MAX(0, MIN((NSInteger)_buffer.lineCount - 1, (NSInteger)line + delta));
    NSRange targetRange = [_buffer UTF16RangeOfLine:(NSUInteger)target includingLineEnding:NO];
    NSUInteger offset =
        targetRange.location + [[_layoutCache layoutForLineAtIndex:(NSUInteger)target] UTF16IndexForX:_preferredX];
    if (target == (NSInteger)line) {
        offset = delta < 0 ? 0 : _buffer.lengthUTF16;
    }
    [self moveToOffset:offset extending:extending preserveX:YES];
}

- (void)moveUp:(id)sender {
    [self moveVertical:-1 extending:NO];
}

- (void)moveDown:(id)sender {
    [self moveVertical:1 extending:NO];
}

- (void)moveUpAndModifySelection:(id)sender {
    [self moveVertical:-1 extending:YES];
}

- (void)moveDownAndModifySelection:(id)sender {
    [self moveVertical:1 extending:YES];
}

- (void)pageUp:(id)sender {
    [self moveVertical:-(NSInteger)MAX(1, NSHeight(_viewportRect) / _lineHeight - 1) extending:NO];
}

- (void)pageDown:(id)sender {
    [self moveVertical:(NSInteger)MAX(1, NSHeight(_viewportRect) / _lineHeight - 1) extending:NO];
}

- (void)pageUpAndModifySelection:(id)sender {
    [self moveVertical:-(NSInteger)MAX(1, NSHeight(_viewportRect) / _lineHeight - 1) extending:YES];
}

- (void)pageDownAndModifySelection:(id)sender {
    [self moveVertical:(NSInteger)MAX(1, NSHeight(_viewportRect) / _lineHeight - 1) extending:YES];
}

- (NSUInteger)lineBoundary:(BOOL)end {
    NSRange range = [_buffer UTF16RangeOfLine:[_buffer lineIndexForUTF16Offset:_head] includingLineEnding:NO];
    return end ? NSMaxRange(range) : range.location;
}

- (void)moveToBeginningOfLine:(id)sender {
    [self moveToOffset:[self lineBoundary:NO] extending:NO preserveX:NO];
}

- (void)moveToEndOfLine:(id)sender {
    [self moveToOffset:[self lineBoundary:YES] extending:NO preserveX:NO];
}

- (void)moveToBeginningOfLineAndModifySelection:(id)sender {
    [self moveToOffset:[self lineBoundary:NO] extending:YES preserveX:NO];
}

- (void)moveToEndOfLineAndModifySelection:(id)sender {
    [self moveToOffset:[self lineBoundary:YES] extending:YES preserveX:NO];
}

- (void)moveToBeginningOfParagraph:(id)sender {
    [self moveToBeginningOfLine:sender];
}

- (void)moveToEndOfParagraph:(id)sender {
    [self moveToEndOfLine:sender];
}

- (void)moveToBeginningOfParagraphAndModifySelection:(id)sender {
    [self moveToBeginningOfLineAndModifySelection:sender];
}

- (void)moveToEndOfParagraphAndModifySelection:(id)sender {
    [self moveToEndOfLineAndModifySelection:sender];
}

- (void)moveToBeginningOfDocument:(id)sender {
    [self moveToOffset:0 extending:NO preserveX:NO];
}

- (void)moveToEndOfDocument:(id)sender {
    [self moveToOffset:_buffer.lengthUTF16 extending:NO preserveX:NO];
}

- (void)moveToBeginningOfDocumentAndModifySelection:(id)sender {
    [self moveToOffset:0 extending:YES preserveX:NO];
}

- (void)moveToEndOfDocumentAndModifySelection:(id)sender {
    [self moveToOffset:_buffer.lengthUTF16 extending:YES preserveX:NO];
}

static NSInteger SCECharacterClass(NSString *text, NSUInteger index) {
    unichar ch = [text characterAtIndex:index];
    if ([NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:ch]) {
        return 0;
    }
    if (ch == '_' || [NSCharacterSet.alphanumericCharacterSet characterIsMember:ch]) {
        return 1;
    }
    return 2;
}

- (NSRange)wordRangeAtOffset:(NSUInteger)offset {
    if (!_buffer.lengthUTF16) {
        return NSMakeRange(0, 0);
    }
    offset = MIN(offset, _buffer.lengthUTF16 - 1);
    NSRange range = [_buffer UTF16RangeOfLine:[_buffer lineIndexForUTF16Offset:offset] includingLineEnding:YES];
    NSString *text = [_buffer substringWithUTF16Range:range];
    NSRange cluster = [text rangeOfComposedCharacterSequenceAtIndex:offset - range.location];
    NSInteger kind = SCECharacterClass(text, cluster.location);
    NSUInteger start = cluster.location;
    NSUInteger end = NSMaxRange(cluster);
    while (start) {
        NSRange previous = [text rangeOfComposedCharacterSequenceAtIndex:start - 1];
        if (SCECharacterClass(text, previous.location) != kind) {
            break;
        }
        start = previous.location;
    }
    while (end < text.length) {
        NSRange next = [text rangeOfComposedCharacterSequenceAtIndex:end];
        if (SCECharacterClass(text, next.location) != kind) {
            break;
        }
        end = NSMaxRange(next);
    }
    return NSMakeRange(range.location + start, end - start);
}

- (NSUInteger)wordBoundary:(BOOL)forward {
    NSUInteger offset = _head;
    if (forward) {
        if (offset == _buffer.lengthUTF16) {
            return offset;
        }
        NSRange word = [self wordRangeAtOffset:offset];
        if (SCECharacterClass([_buffer substringWithUTF16Range:word], 0) == 0 &&
            NSMaxRange(word) < _buffer.lengthUTF16) {
            word = [self wordRangeAtOffset:NSMaxRange(word)];
        }
        return NSMaxRange(word);
    }
    if (!offset) {
        return 0;
    }
    NSRange word = [self wordRangeAtOffset:[self previousBoundary:offset]];
    if (SCECharacterClass([_buffer substringWithUTF16Range:word], 0) == 0 && word.location) {
        word = [self wordRangeAtOffset:[self previousBoundary:word.location]];
    }
    return word.location;
}

- (void)moveWordLeft:(id)sender {
    [self moveToOffset:[self wordBoundary:NO] extending:NO preserveX:NO];
}

- (void)moveWordRight:(id)sender {
    [self moveToOffset:[self wordBoundary:YES] extending:NO preserveX:NO];
}

- (void)moveWordLeftAndModifySelection:(id)sender {
    [self moveToOffset:[self wordBoundary:NO] extending:YES preserveX:NO];
}

- (void)moveWordRightAndModifySelection:(id)sender {
    [self moveToOffset:[self wordBoundary:YES] extending:YES preserveX:NO];
}

- (void)moveWordBackward:(id)sender {
    [self moveWordLeft:sender];
}

- (void)moveWordForward:(id)sender {
    [self moveWordRight:sender];
}

- (void)moveWordBackwardAndModifySelection:(id)sender {
    [self moveWordLeftAndModifySelection:sender];
}

- (void)moveWordForwardAndModifySelection:(id)sender {
    [self moveWordRightAndModifySelection:sender];
}

- (void)deleteWordBackward:(id)sender {
    if (!_editable) {
        return;
    }
    [self finishComposition];
    if (self.selectedRange.length) {
        [self deleteRange:self.selectedRange];
    } else {
        NSUInteger start = [self wordBoundary:NO];
        [self deleteRange:NSMakeRange(start, _head - start)];
    }
}

- (void)deleteWordForward:(id)sender {
    if (!_editable) {
        return;
    }
    [self finishComposition];
    [self deleteRange:self.selectedRange.length ? self.selectedRange
                                                : NSMakeRange(_head, [self wordBoundary:YES] - _head)];
}

- (void)deleteToBeginningOfLine:(id)sender {
    if (!_editable) {
        return;
    }
    [self finishComposition];
    NSUInteger start = [self lineBoundary:NO];
    [self deleteRange:self.selectedRange.length ? self.selectedRange : NSMakeRange(start, _head - start)];
}

- (void)deleteToEndOfLine:(id)sender {
    if (!_editable) {
        return;
    }
    [self finishComposition];
    [self deleteRange:self.selectedRange.length ? self.selectedRange
                                                : NSMakeRange(_head, [self lineBoundary:YES] - _head)];
}

// MARK: Context menus

- (NSMenu *)defaultContextMenu {
    // The context menu offers only clipboard commands. Undo, Redo, Delete, and
    // Select All remain available through the main menu and key equivalents.
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    [menu addItemWithTitle:NSLocalizedString(@"Cut", nil) action:@selector(cut:) keyEquivalent:@""];
    [menu addItemWithTitle:NSLocalizedString(@"Copy", nil) action:@selector(copy:) keyEquivalent:@""];
    [menu addItemWithTitle:NSLocalizedString(@"Paste", nil) action:@selector(paste:) keyEquivalent:@""];
    for (NSMenuItem *item in menu.itemArray) {
        // Explicit targets keep commands attached to this editor even when
        // it is non-focusable or another view becomes the first responder.
        item.target = self;
    }
    return menu;
}

- (NSMenu *)menuForEvent:(NSEvent *)event {
    if (_focusable) {
        [self.window makeFirstResponder:self];
    }
    [self finishComposition];
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (![self isDocumentPoint:point inTextRange:self.selectedRange]) {
        NSUInteger offset = [self UTF16OffsetForDocumentPoint:point];
        NSRange range = [self wordRangeAtOffset:offset];
        if (![self isDocumentPoint:point inTextRange:range] ||
            (range.length && SCECharacterClass([_buffer substringWithUTF16Range:range], 0) == 0)) {
            range = NSMakeRange(offset, 0);
        }
        [self setAnchor:range.location head:NSMaxRange(range) scroll:NO preserveX:NO];
    }
    NSMenu *menu = self.menu ? [self.menu copy] : [self defaultContextMenu];
    if ([_delegate respondsToSelector:@selector(editorView:menu:forEvent:)]) {
        return [_delegate editorView:self menu:menu forEvent:event];
    }
    return menu;
}

// MARK: Link recognition and hover feedback

- (BOOL)isDocumentPoint:(NSPoint)point inTextRange:(NSRange)range {
    if (!range.length || !NSPointInRect(point, self.visibleRect) ||
        point.x < NSMinX(_viewportRect) + self.gutterWidth || point.y < SCEInset ||
        point.y >= SCEInset + _buffer.lineCount * _lineHeight) {
        return NO;
    }
    NSUInteger line = (NSUInteger)floor((point.y - SCEInset) / _lineHeight);
    NSRange content = [_buffer UTF16RangeOfLine:line includingLineEnding:NO];
    NSRange overlap = NSIntersectionRange(content, range);
    SCELineLayout *layout = [_layoutCache layoutForLineAtIndex:line];
    NSPoint localPoint = NSMakePoint(point.x - self.textOriginX, point.y - SCEInset - line * _lineHeight);
    NSRange wholeLine = [_buffer UTF16RangeOfLine:line includingLineEnding:YES];
    NSRange lineOverlap = NSIntersectionRange(wholeLine, range);
    if (lineOverlap.length && NSMaxRange(lineOverlap) > NSMaxRange(content) &&
        localPoint.x >= [layout xForUTF16Index:content.length]) {
        return YES;
    }
    if (!overlap.length) {
        return NO;
    }
    NSRange local = NSMakeRange(overlap.location - content.location, overlap.length);
    for (NSValue *value in [layout selectionRectsForUTF16Range:local height:_lineHeight]) {
        if (NSPointInRect(localPoint, value.rectValue)) {
            return YES;
        }
    }
    return NO;
}

- (NSURL *)URLAtPoint:(NSPoint)point effectiveRange:(NSRangePointer)effectiveRange {
    if (effectiveRange) {
        *effectiveRange = NSMakeRange(NSNotFound, 0);
    }
    if (!_automaticLinkDetectionEnabled || !NSPointInRect(point, self.visibleRect) ||
        point.x < NSMinX(_viewportRect) + self.gutterWidth || point.y < SCEInset ||
        point.y >= SCEInset + _buffer.lineCount * _lineHeight) {
        return nil;
    }
    NSUInteger line = (NSUInteger)floor((point.y - SCEInset) / _lineHeight);
    NSRange content = [_buffer UTF16RangeOfLine:line includingLineEnding:NO];
    if (!_detectedLineLinks || _detectedLinkLine != line || _detectedLinkRevision != _buffer.revision) {
        if (!_linkDetector) {
            _linkDetector = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink error:NULL];
        }
        NSString *text = [_buffer substringWithUTF16Range:content];
        _detectedLineLinks = [_linkDetector matchesInString:text options:0 range:NSMakeRange(0, text.length)];
        _detectedLinkLine = line;
        _detectedLinkRevision = _buffer.revision;
    }
    for (NSTextCheckingResult *match in _detectedLineLinks) {
        NSString *scheme = match.URL.scheme.lowercaseString;
        if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) {
            continue;
        }
        NSRange range = NSMakeRange(content.location + match.range.location, match.range.length);
        if ([self isDocumentPoint:point inTextRange:range]) {
            if (effectiveRange) {
                *effectiveRange = range;
            }
            return match.URL;
        }
    }
    return nil;
}

- (void)setAutomaticLinkDetectionEnabled:(BOOL)enabled {
    _automaticLinkDetectionEnabled = enabled;
    [self invalidateDetectedLinks];
    [self updateLinkHoverForCurrentPointer];
}

- (void)invalidateDetectedLinks {
    _detectedLineLinks = nil;
    _pressedLinkURL = nil;
    [self setHoveredLinkRange:NSMakeRange(NSNotFound, 0)];
}

- (void)setHoveredLinkRange:(NSRange)range {
    if (NSEqualRanges(range, _hoveredLinkRange)) {
        return;
    }
    _hoveredLinkRange = range;
    _textSurface.needsDisplay = YES;
    [self.window invalidateCursorRectsForView:self];
}

- (void)updateLinkHoverAtWindowPoint:(NSPoint)windowPoint modifierFlags:(NSEventModifierFlags)modifierFlags {
    NSPoint point = [self convertPoint:windowPoint fromView:nil];
    NSView *contentView = self.window.contentView;
    // NSView hit testing takes a point in the receiver's superview coordinates.
    NSView *hitView = [contentView hitTest:[contentView.superview convertPoint:windowPoint fromView:nil]];
    BOOL inside = NSPointInRect(point, self.visibleRect) && (!contentView || hitView == self);
    NSRange range = NSMakeRange(NSNotFound, 0);
    if (inside && (modifierFlags & NSEventModifierFlagCommand) && !(modifierFlags & NSEventModifierFlagControl) &&
        !_lastDragEvent && !_handlingLinkClick) {
        [self URLAtPoint:point effectiveRange:&range];
    }
    [self setHoveredLinkRange:range];
    if (inside) {
        [(range.location == NSNotFound ? NSCursor.IBeamCursor : NSCursor.pointingHandCursor) set];
    }
}

// Returns the modifier keys held now. Tracking events such as mouse-entered and
// cursor-update events do not carry reliable device-independent modifier flags,
// so hover feedback for those events reads the current state instead.
- (NSEventModifierFlags)currentModifierFlags {
    return NSEvent.modifierFlags;
}

- (void)updateLinkHoverForCurrentPointer {
    if (self.window.isKeyWindow) {
        [self updateLinkHoverAtWindowPoint:self.window.mouseLocationOutsideOfEventStream
                             modifierFlags:self.currentModifierFlags];
    } else {
        [self setHoveredLinkRange:NSMakeRange(NSNotFound, 0)];
    }
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (!_linkTrackingArea) {
        _linkTrackingArea = [[NSTrackingArea alloc]
            initWithRect:NSZeroRect
                 options:NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingCursorUpdate |
                         NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
                   owner:self
                userInfo:nil];
        [self addTrackingArea:_linkTrackingArea];
    }
}

- (void)mouseEntered:(NSEvent *)event {
    [self updateLinkHoverAtWindowPoint:event.locationInWindow modifierFlags:self.currentModifierFlags];
}

- (void)mouseMoved:(NSEvent *)event {
    [self updateLinkHoverAtWindowPoint:event.locationInWindow modifierFlags:event.modifierFlags];
}

// Changing the hovered link invalidates cursor rectangles, which makes AppKit send
// cursor-update events. Their modifier flags can omit Command while it is held,
// so using them would clear the underline immediately after mouseMoved: sets it.
- (void)cursorUpdate:(NSEvent *)event {
    [self updateLinkHoverAtWindowPoint:event.locationInWindow modifierFlags:self.currentModifierFlags];
}

- (void)mouseExited:(NSEvent *)event {
    [self setHoveredLinkRange:NSMakeRange(NSNotFound, 0)];
}

- (void)openDetectedURL:(NSURL *)URL {
    [NSWorkspace.sharedWorkspace openURL:URL];
}

// MARK: Pointer selection

- (void)mouseDown:(NSEvent *)event {
    if (event.modifierFlags & NSEventModifierFlagControl) {
        NSMenu *menu = [self menuForEvent:event];
        if (menu) {
            [NSMenu popUpContextMenu:menu withEvent:event forView:self];
        }
        return;
    }
    _handlingLinkClick = NO;
    _pressedLinkURL = nil;
    if ((event.modifierFlags & NSEventModifierFlagCommand) && event.clickCount == 1) {
        _pressedLinkURL = [self URLAtPoint:[self convertPoint:event.locationInWindow fromView:nil]
                            effectiveRange:&_pressedLinkRange];
        if (_pressedLinkURL) {
            _handlingLinkClick = YES;
            _pressedLinkRevision = _buffer.revision;
            return;
        }
    }
    // A non-focusable editor selects text without taking focus from the current first responder.
    if (_focusable) {
        [self.window makeFirstResponder:self];
    }
    [self finishComposition];
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSUInteger offset = [self UTF16OffsetForDocumentPoint:point];
    _dragGranularity = event.clickCount >= 3 || point.x < NSMinX(_viewportRect) + self.gutterWidth
                           ? 2
                           : (event.clickCount == 2 ? 1 : 0);
    NSRange range = NSMakeRange(offset, 0);
    if (_dragGranularity == 1) {
        range = [self wordRangeAtOffset:offset];
    } else if (_dragGranularity == 2) {
        range = [_buffer UTF16RangeOfLine:[_buffer lineIndexForUTF16Offset:offset] includingLineEnding:YES];
    }
    _dragInitialRange = range;
    if ((event.modifierFlags & NSEventModifierFlagShift) && !_dragGranularity) {
        [self setAnchor:_anchor head:offset scroll:NO preserveX:NO];
        _dragInitialRange = NSMakeRange(_anchor, 0);
    } else {
        [self setAnchor:range.location head:NSMaxRange(range) scroll:NO preserveX:NO];
    }
}

- (void)updateDragWithEvent:(NSEvent *)event {
    [self autoscroll:event];
    NSUInteger offset = [self UTF16OffsetForDocumentPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (_dragGranularity) {
        NSRange range = _dragGranularity == 1 ? [self wordRangeAtOffset:offset]
                                              : [_buffer UTF16RangeOfLine:[_buffer lineIndexForUTF16Offset:offset]
                                                      includingLineEnding:YES];
        BOOL before = range.location < _dragInitialRange.location;
        [self setAnchor:before ? NSMaxRange(_dragInitialRange) : _dragInitialRange.location
                   head:before ? range.location : NSMaxRange(range)
                 scroll:NO
              preserveX:NO];
    } else {
        [self setAnchor:_dragInitialRange.location head:offset scroll:NO preserveX:NO];
    }
}

- (void)mouseDragged:(NSEvent *)event {
    if (_handlingLinkClick) {
        _pressedLinkURL = nil;
        return;
    }
    [self setHoveredLinkRange:NSMakeRange(NSNotFound, 0)];
    _lastDragEvent = event;
    [self updateDragWithEvent:event];
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    BOOL outside = !NSPointInRect(point, self.visibleRect);
    if (outside && !_autoscrollTimer) {
        __weak SCEEditorView *weakSelf = self;
        _autoscrollTimer = [NSTimer timerWithTimeInterval:1.0 / 30
                                                  repeats:YES
                                                    block:^(NSTimer *timer) {
                                                        SCEEditorView *editor = weakSelf;
                                                        if (editor && editor->_lastDragEvent) {
                                                            [editor updateDragWithEvent:editor->_lastDragEvent];
                                                        }
                                                    }];
        [NSRunLoop.mainRunLoop addTimer:_autoscrollTimer forMode:NSRunLoopCommonModes];
    } else if (!outside) {
        [_autoscrollTimer invalidate];
        _autoscrollTimer = nil;
    }
}

- (void)mouseUp:(NSEvent *)event {
    [_autoscrollTimer invalidate];
    _autoscrollTimer = nil;
    _lastDragEvent = nil;
    if (_handlingLinkClick) {
        NSURL *pressedURL = _pressedLinkURL;
        _handlingLinkClick = NO;
        _pressedLinkURL = nil;
        if (pressedURL && _pressedLinkRevision == _buffer.revision &&
            (event.modifierFlags & NSEventModifierFlagCommand) && !(event.modifierFlags & NSEventModifierFlagControl)) {
            NSRange range;
            NSURL *URL = [self URLAtPoint:[self convertPoint:event.locationInWindow fromView:nil]
                           effectiveRange:&range];
            if ([URL isEqual:pressedURL] && NSEqualRanges(range, _pressedLinkRange)) {
                [self openDetectedURL:URL];
            }
        }
    }
    [self updateLinkHoverAtWindowPoint:event.locationInWindow modifierFlags:event.modifierFlags];
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item {
    SEL action = item.action;
    if (action == @selector(undo:)) {
        return _editable && _editUndoManager.canUndo;
    }
    if (action == @selector(redo:)) {
        return _editable && _editUndoManager.canRedo;
    }
    if (action == @selector(copy:)) {
        return self.selectedRange.length > 0;
    }
    if (action == @selector(cut:) || action == @selector(delete:)) {
        return _editable && self.selectedRange.length > 0;
    }
    if (action == @selector(paste:)) {
        return _editable &&
               [NSPasteboard.generalPasteboard canReadItemWithDataConformingToTypes:@[ NSPasteboardTypeString ]];
    }
    if (action == @selector(selectAll:)) {
        return _buffer.lengthUTF16 > 0;
    }
    return YES;
}

// Basic native accessibility. Full parameterized text navigation is a follow-up.
- (BOOL)isAccessibilityElement {
    return YES;
}

- (NSString *)accessibilityRole {
    return NSAccessibilityTextAreaRole;
}

- (NSString *)accessibilityLabel {
    return NSLocalizedString(@"Source editor", nil);
}

- (id)accessibilityValue {
    return self.string;
}

- (BOOL)isAccessibilityFocused {
    return self.window.firstResponder == self;
}

- (NSRange)accessibilitySelectedTextRange {
    return self.selectedRange;
}

- (void)setAccessibilitySelectedTextRange:(NSRange)range {
    self.selectedRange = range;
}

- (NSString *)accessibilitySelectedText {
    return [_buffer substringWithUTF16Range:self.selectedRange];
}

- (NSInteger)accessibilityNumberOfCharacters {
    return (NSInteger)_buffer.lengthUTF16;
}

- (NSString *)accessibilityStringForRange:(NSRange)range {
    return [_buffer substringWithUTF16Range:[self clampedRange:range]];
}

@end
