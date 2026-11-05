@import SourceEditor;
#import "SCEInteractionChecks.h"
#import "../../Sources/SourceEditor/SCELineLayoutCache.h"

static NSUInteger SCEInteractionCheckCount;
#define INTERACTION_CHECK(condition, message)                                                                          \
    do {                                                                                                               \
        SCEInteractionCheckCount++;                                                                                    \
        if (!(condition)) {                                                                                            \
            fprintf(stderr, "FAIL interaction at line %d: %s\n", __LINE__, message);                                   \
            exit(1);                                                                                                   \
        }                                                                                                              \
    } while (0)

@interface SCEEditorView (InteractionChecks)
- (void)openDetectedURL:(NSURL *)URL;
- (NSEventModifierFlags)currentModifierFlags;

@end

// Record browser requests without launching another application during checks,
// and simulate the keyboard's modifier state independently of the physical keys.
@interface SCEInteractionEditorView : SCEEditorView
@property (nonatomic, copy) NSURL *openedURL;
@property (nonatomic) NSUInteger openCount;
@property (nonatomic) NSEventModifierFlags simulatedModifierFlags;
@end

@implementation SCEInteractionEditorView

- (void)openDetectedURL:(NSURL *)URL {
    self.openedURL = URL;
    self.openCount++;
}

- (NSEventModifierFlags)currentModifierFlags {
    return self.simulatedModifierFlags;
}

@end

@interface SCEContextMenuDelegate : NSObject <SCEEditorViewDelegate>
@property (nonatomic) NSUInteger mode;
@property (nonatomic) NSUInteger requestCount;
@property (nonatomic) NSRange selectionAtRequest;
@property (nonatomic, strong) NSMenu *receivedMenu;
@property (nonatomic, strong) NSEvent *receivedEvent;
@end

@implementation SCEContextMenuDelegate

- (NSMenu *)editorView:(SCEEditorView *)editorView menu:(NSMenu *)menu forEvent:(NSEvent *)event {
    self.requestCount++;
    self.selectionAtRequest = editorView.selectedRange;
    self.receivedMenu = menu;
    self.receivedEvent = event;
    if (self.mode == 2) {
        return nil;
    }
    if (self.mode == 1) {
        NSMenu *replacement = [[NSMenu alloc] initWithTitle:@"Document Commands"];
        NSMenuItem *item = [replacement addItemWithTitle:@"Select Document"
                                                  action:@selector(selectAll:)
                                           keyEquivalent:@""];
        item.target = editorView;
        return replacement;
    }
    NSInteger pasteIndex = [menu indexOfItemWithTarget:editorView andAction:@selector(paste:)];
    if (pasteIndex != -1) {
        [menu removeItemAtIndex:pasteIndex];
    }
    NSMenuItem *item = [menu addItemWithTitle:@"Select Document" action:@selector(selectAll:) keyEquivalent:@""];
    item.target = editorView;
    return menu;
}

@end

static NSPoint SCEPointForTextOffset(SCEEditorView *editor, NSUInteger offset) {
    NSRect screenRect = [editor firstRectForCharacterRange:NSMakeRange(offset, 1) actualRange:NULL];
    NSRect windowRect = [editor.window convertRectFromScreen:screenRect];
    return [editor convertPoint:NSMakePoint(NSMidX(windowRect), NSMidY(windowRect)) fromView:nil];
}

static NSEvent *SCEPointerEvent(SCEEditorView *editor, NSEventType type, NSPoint point,
                                NSEventModifierFlags modifiers) {
    return [NSEvent mouseEventWithType:type
                              location:[editor convertPoint:point toView:nil]
                         modifierFlags:modifiers
                             timestamp:NSProcessInfo.processInfo.systemUptime
                          windowNumber:editor.window.windowNumber
                               context:nil
                           eventNumber:0
                            clickCount:1
                              pressure:1];
}

static NSMenuItem *SCEItemForAction(NSMenu *menu, SEL action) {
    for (NSMenuItem *item in menu.itemArray) {
        if (item.action == action) {
            return item;
        }
    }
    return nil;
}

// Main-menu items reach the editor through the responder chain. A standalone
// item validates commands that the context menu intentionally omits.
static NSMenuItem *SCECommandItem(SEL action) {
    return [[NSMenuItem alloc] initWithTitle:@"" action:action keyEquivalent:@""];
}

static void SCECheckContextMenus(SCEInteractionEditorView *editor) {
    editor.string = @"alpha beta gamma\n\nlast";
    editor.selectedRange = NSMakeRange(0, 10);
    NSPoint point = SCEPointForTextOffset(editor, 7);
    NSEvent *event = SCEPointerEvent(editor, NSEventTypeRightMouseDown, point, 0);
    NSMenu *menu = [editor menuForEvent:event];
    INTERACTION_CHECK(NSEqualRanges(editor.selectedRange, NSMakeRange(0, 10)),
                      "a context click inside the selection must preserve it");
    SEL actions[] = {@selector(cut:), @selector(copy:), @selector(paste:)};
    INTERACTION_CHECK(menu.numberOfItems == sizeof(actions) / sizeof(*actions),
                      "the default context menu must contain only Cut, Copy, and Paste");
    for (NSUInteger index = 0; index < sizeof(actions) / sizeof(*actions); index++) {
        NSMenuItem *item = [menu itemAtIndex:(NSInteger)index];
        INTERACTION_CHECK(item.action == actions[index] && item.target == editor,
                          "Cut, Copy, and Paste must appear in order and target the clicked editor");
    }
    SEL omittedActions[] = {@selector(undo:), @selector(redo:), @selector(delete:), @selector(selectAll:)};
    for (NSUInteger index = 0; index < sizeof(omittedActions) / sizeof(*omittedActions); index++) {
        INTERACTION_CHECK(!SCEItemForAction(menu, omittedActions[index]),
                          "the context menu must omit Undo, Redo, Delete, and Select All");
    }
    INTERACTION_CHECK(![editor validateUserInterfaceItem:SCECommandItem(@selector(undo:))],
                      "Undo must be disabled without an edit");
    INTERACTION_CHECK(![editor validateUserInterfaceItem:SCECommandItem(@selector(redo:))],
                      "Redo must be disabled without an undone edit");
    INTERACTION_CHECK(
        [editor validateUserInterfaceItem:SCEItemForAction(menu, @selector(paste:))] ==
            [NSPasteboard.generalPasteboard canReadItemWithDataConformingToTypes:@[ NSPasteboardTypeString ]],
        "Paste availability must follow the system pasteboard");

    editor.selectedRange = NSMakeRange(0, 0);
    menu = [editor menuForEvent:event];
    INTERACTION_CHECK(NSEqualRanges(editor.selectedRange, NSMakeRange(6, 4)),
                      "a context click outside the selection must select the pointed-to word");
    NSMenu *nextMenu = [editor menuForEvent:event];
    INTERACTION_CHECK(menu != nextMenu, "each context-menu request must receive a fresh menu");
    INTERACTION_CHECK([NSApp sendAction:@selector(delete:) to:editor from:nil],
                      "the Delete command must dispatch to the editor");
    INTERACTION_CHECK([editor.string isEqualToString:@"alpha  gamma\n\nlast"],
                      "Delete must remove exactly the context-click selection");
    [editor undo:nil];
    INTERACTION_CHECK([editor.string isEqualToString:@"alpha beta gamma\n\nlast"] &&
                          NSEqualRanges(editor.selectedRange, NSMakeRange(6, 4)),
                      "one undo must restore deleted text and its selection");
    INTERACTION_CHECK([editor validateUserInterfaceItem:SCECommandItem(@selector(redo:))],
                      "Redo must be enabled after undoing Delete");
    [editor redo:nil];
    INTERACTION_CHECK([editor.string isEqualToString:@"alpha  gamma\n\nlast"], "Redo must repeat Delete");
    NSString *before = editor.string;
    [editor delete:nil];
    INTERACTION_CHECK([editor.string isEqualToString:before], "Delete must leave an empty caret unchanged");

    editor.string = @"alpha beta gamma\n\nlast";
    editor.selectedRange = NSMakeRange(0, 0);
    editor.editable = NO;
    editor.focusable = NO;
    [editor.window makeFirstResponder:editor.window];
    menu = [editor menuForEvent:event];
    [menu update];
    INTERACTION_CHECK(editor.window.firstResponder != editor, "a non-focusable context click must preserve focus");
    INTERACTION_CHECK(SCEItemForAction(menu, @selector(copy:)).enabled,
                      "Copy must remain available in a non-focusable read-only editor");
    INTERACTION_CHECK(!SCEItemForAction(menu, @selector(cut:)).enabled &&
                          !SCEItemForAction(menu, @selector(paste:)).enabled,
                      "read-only context menus must disable Cut and Paste");
    SEL mutationActions[] = {@selector(undo:), @selector(redo:), @selector(delete:)};
    for (NSUInteger index = 0; index < sizeof(mutationActions) / sizeof(*mutationActions); index++) {
        INTERACTION_CHECK(![editor validateUserInterfaceItem:SCECommandItem(mutationActions[index])],
                          "read-only editors must disable every mutation command");
    }
    [editor delete:nil];
    INTERACTION_CHECK([editor.string isEqualToString:@"alpha beta gamma\n\nlast"],
                      "read-only Delete must leave the document unchanged");

    editor.selectedRange = NSMakeRange(0, 18);
    NSPoint blankLinePoint = SCEPointForTextOffset(editor, 17);
    blankLinePoint.x += 100;
    [editor menuForEvent:SCEPointerEvent(editor, NSEventTypeRightMouseDown, blankLinePoint, 0)];
    INTERACTION_CHECK(NSEqualRanges(editor.selectedRange, NSMakeRange(0, 18)),
                      "a context click on a selected empty line must preserve a multiline selection");

    SCEContextMenuDelegate *delegate = [[SCEContextMenuDelegate alloc] init];
    editor.delegate = delegate;
    editor.selectedRange = NSMakeRange(0, 0);
    menu = [editor menuForEvent:event];
    INTERACTION_CHECK(delegate.receivedEvent == event && NSEqualRanges(delegate.selectionAtRequest, NSMakeRange(6, 4)),
                      "the delegate must receive the original event after the context selection is established");
    INTERACTION_CHECK(menu == delegate.receivedMenu && !SCEItemForAction(menu, @selector(paste:)) &&
                          [menu itemWithTitle:@"Select Document"],
                      "a delegate must be able to remove and append menu items");
    delegate.mode = 1;
    menu = [editor menuForEvent:event];
    INTERACTION_CHECK(menu != delegate.receivedMenu && menu.numberOfItems == 1,
                      "a delegate must be able to replace the entire menu");
    delegate.mode = 2;
    INTERACTION_CHECK(![editor menuForEvent:event], "a delegate must be able to suppress the menu");
    NSUInteger requestCount = delegate.requestCount;
    [editor mouseDown:SCEPointerEvent(editor, NSEventTypeLeftMouseDown, point, NSEventModifierFlagControl)];
    INTERACTION_CHECK(delegate.requestCount == requestCount + 1,
                      "Control-click must use the same menu customization path");

    NSMenu *template = [[NSMenu alloc] initWithTitle:@"Document Commands"];
    [template addItemWithTitle:@"Document Action" action:NULL keyEquivalent:@""];
    editor.menu = template;
    delegate.mode = 0;
    menu = [editor menuForEvent:event];
    INTERACTION_CHECK(menu != template && menu.numberOfItems == 2 && template.numberOfItems == 1,
                      "customizing a copied NSView.menu must not mutate the integrator's template");
    editor.menu = nil;
    delegate = nil;
    INTERACTION_CHECK(editor.delegate == nil, "the editor must not retain its menu delegate");
    editor.editable = YES;
    editor.focusable = YES;

    point = NSMakePoint(NSMaxX(editor.visibleRect) - 10, NSMaxY(editor.visibleRect) - 10);
    [editor menuForEvent:SCEPointerEvent(editor, NSEventTypeRightMouseDown, point, 0)];
    INTERACTION_CHECK(editor.selectedRange.length == 0 && editor.selectedRange.location == editor.string.length,
                      "a context click below the text must place an empty caret at the document end");
    editor.string = @"";
    menu = [editor menuForEvent:event];
    INTERACTION_CHECK(![editor validateUserInterfaceItem:SCEItemForAction(menu, @selector(copy:))] &&
                          ![editor validateUserInterfaceItem:SCECommandItem(@selector(delete:))] &&
                          ![editor validateUserInterfaceItem:SCECommandItem(@selector(selectAll:))],
                      "selection commands must be disabled for an empty document");
    puts(
        "PASS context menus: Cut, Copy, and Paste only, selection, validation, read-only focus, delegate customization, Control-click");
}

static NSData *SCERenderInteractionText(SCEEditorView *editor) {
    size_t width = (size_t)NSWidth(editor.bounds);
    size_t height = (size_t)NSHeight(editor.bounds);
    NSMutableData *pixels = [NSMutableData dataWithLength:width * height * 4];
    CGColorSpaceRef colors = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmap = CGBitmapContextCreate(pixels.mutableBytes, width, height, 8, width * 4, colors,
                                                kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colors);
    NSGraphicsContext *graphics = [NSGraphicsContext graphicsContextWithCGContext:bitmap flipped:NO];
    NSView *surface = editor.subviews[1];
    [surface displayRectIgnoringOpacity:surface.bounds inContext:graphics];
    CGContextRelease(bitmap);
    return pixels;
}

static void SCECheckLinks(SCEInteractionEditorView *editor) {
    // A surrogate-pair emoji and CRLF exercise document-wide UTF-16 ranges.
    editor.string = @"\U0001f642 see (https://example.com/docs?q=1#part),\r\n"
                     "http://example.org/path and www.example.net.\n"
                     "user@example.com file:///tmp/document.txt custom-editor://open\n";
    NSString *text = editor.string;
    NSString *address = @"https://example.com/docs?q=1#part";
    NSRange expectedRange = [text rangeOfString:address];
    NSPoint point = SCEPointForTextOffset(editor, expectedRange.location + 8);
    NSRange range;
    NSURL *URL = [editor URLAtPoint:point effectiveRange:&range];
    INTERACTION_CHECK(editor.isAutomaticLinkDetectionEnabled, "automatic link detection must default to enabled");
    INTERACTION_CHECK([URL.absoluteString isEqualToString:address] && NSEqualRanges(range, expectedRange),
                      "link detection must preserve URL components, UTF-16 offsets, and exclude enclosing punctuation");
    NSRange secondRange = [text rangeOfString:@"http://example.org/path"];
    NSURL *secondURL = [editor URLAtPoint:SCEPointForTextOffset(editor, secondRange.location + 8)
                           effectiveRange:&range];
    INTERACTION_CHECK([secondURL.scheme isEqualToString:@"http"] && NSEqualRanges(range, secondRange),
                      "HTTP links after CRLF must have document-relative UTF-16 ranges");
    NSRange bareRange = [text rangeOfString:@"www.example.net"];
    NSURL *bareURL = [editor URLAtPoint:SCEPointForTextOffset(editor, bareRange.location + 4) effectiveRange:&range];
    INTERACTION_CHECK([bareURL.host isEqualToString:@"www.example.net"] && NSEqualRanges(range, bareRange),
                      "Foundation-recognized web addresses must omit trailing sentence punctuation");
    NSArray<NSString *> *nonWebText = @[ @"user@example.com", @"file:///tmp/document.txt", @"custom-editor://open" ];
    for (NSString *value in nonWebText) {
        NSRange valueRange = [text rangeOfString:value];
        INTERACTION_CHECK(![editor URLAtPoint:SCEPointForTextOffset(editor, valueRange.location + 3)
                               effectiveRange:&range] &&
                              range.location == NSNotFound,
                          "non-web URL schemes and email addresses must not activate browser links");
    }
    NSPoint gutterPoint = point;
    gutterPoint.x = NSMinX(editor.visibleRect) + 5;
    INTERACTION_CHECK(![editor URLAtPoint:gutterPoint effectiveRange:&range] && range.location == NSNotFound,
                      "the gutter must never activate a link");
    NSPoint trailingPoint = point;
    trailingPoint.x = NSMaxX(editor.visibleRect) - 5;
    INTERACTION_CHECK(![editor URLAtPoint:trailingPoint effectiveRange:NULL],
                      "empty space after a URL must not activate its nearest caret position");
    NSPoint lastCharacterPoint = SCEPointForTextOffset(editor, NSMaxRange(expectedRange) - 1);
    lastCharacterPoint.x += 1;
    INTERACTION_CHECK([editor URLAtPoint:lastCharacterPoint effectiveRange:NULL],
                      "the trailing half of the URL's last glyph must remain clickable");

    SCELineLayoutCache *cache = [editor valueForKey:@"layoutCache"];
    NSUInteger builds = cache.totalLayoutBuildCount;
    NSData *plainPixels = SCERenderInteractionText(editor);
    [editor mouseMoved:SCEPointerEvent(editor, NSEventTypeMouseMoved, point, NSEventModifierFlagCommand)];
    INTERACTION_CHECK(NSEqualRanges([[editor valueForKey:@"hoveredLinkRange"] rangeValue], expectedRange),
                      "Command-hover must activate the pointed-to URL range");
    NSData *hoverPixels = SCERenderInteractionText(editor);
    INTERACTION_CHECK(![plainPixels isEqualToData:hoverPixels], "Command-hover must visibly draw the link underline");
    const uint8_t *plain = plainPixels.bytes;
    const uint8_t *hover = hoverPixels.bytes;
    size_t width = (size_t)NSWidth(editor.bounds);
    BOOL confined = YES;
    NSPoint start = SCEPointForTextOffset(editor, expectedRange.location);
    NSPoint end = SCEPointForTextOffset(editor, NSMaxRange(expectedRange) - 1);
    CGFloat lineHeight = [[editor valueForKey:@"lineHeight"] doubleValue];
    for (size_t index = 0; index < plainPixels.length; index += 4) {
        if (memcmp(plain + index, hover + index, 4)) {
            CGFloat x = (index / 4) % width;
            CGFloat y = (index / 4) / width;
            BOOL inside = x >= start.x - 10 && x <= end.x + 10 && fabs(y - start.y) < lineHeight / 2;
            if (confined && !inside) {
                fprintf(stderr, "Hover pixel outside link at (%.1f, %.1f); endpoints %s, %s; line height %.1f\n", x, y,
                        NSStringFromPoint(start).UTF8String, NSStringFromPoint(end).UTF8String, lineHeight);
            }
            confined &= inside;
        }
    }
    INTERACTION_CHECK(confined, "hover rendering must change pixels only along the recognized URL");
    [editor mouseMoved:SCEPointerEvent(editor, NSEventTypeMouseMoved, point, 0)];
    INTERACTION_CHECK([plainPixels isEqualToData:SCERenderInteractionText(editor)],
                      "releasing Command must remove the underline without changing the text");
    INTERACTION_CHECK(cache.totalLayoutBuildCount == builds, "hover feedback must not rebuild Core Text layouts");
    NSView *overlay = [[NSView alloc] initWithFrame:NSMakeRect(point.x - 5, point.y - 5, 10, 10)];
    [editor addSubview:overlay];
    [editor mouseMoved:SCEPointerEvent(editor, NSEventTypeMouseMoved, point, NSEventModifierFlagCommand)];
    INTERACTION_CHECK([[editor valueForKey:@"hoveredLinkRange"] rangeValue].location == NSNotFound,
                      "a control over the editor must not activate links behind it");
    [overlay removeFromSuperview];

    editor.selectedRange = NSMakeRange(0, 2);
    NSRange selection = editor.selectedRange;
    editor.editable = NO;
    editor.focusable = NO;
    [editor mouseDown:SCEPointerEvent(editor, NSEventTypeLeftMouseDown, point, NSEventModifierFlagCommand)];
    INTERACTION_CHECK(editor.openCount == 0, "pressing a link must wait for mouse release before opening it");
    [editor mouseUp:SCEPointerEvent(editor, NSEventTypeLeftMouseUp, point, NSEventModifierFlagCommand)];
    INTERACTION_CHECK(
        editor.openCount == 1 && [editor.openedURL isEqual:URL] && NSEqualRanges(editor.selectedRange, selection) &&
            [editor.string isEqualToString:text],
        "Command-click must open the detected URL in read-only mode while preserving document and selection");
    [editor mouseDown:SCEPointerEvent(editor, NSEventTypeLeftMouseDown, point, 0)];
    [editor mouseUp:SCEPointerEvent(editor, NSEventTypeLeftMouseUp, point, 0)];
    INTERACTION_CHECK(editor.openCount == 1 && editor.selectedRange.length == 0,
                      "an ordinary click must place the caret without opening the URL");
    [editor mouseDown:SCEPointerEvent(editor, NSEventTypeLeftMouseDown, point, NSEventModifierFlagCommand)];
    [editor mouseUp:SCEPointerEvent(editor, NSEventTypeLeftMouseUp, point, 0)];
    INTERACTION_CHECK(editor.openCount == 1, "releasing Command before mouse-up must cancel URL opening");
    [editor mouseDown:SCEPointerEvent(editor, NSEventTypeLeftMouseDown, point, NSEventModifierFlagCommand)];
    [editor mouseDragged:SCEPointerEvent(editor, NSEventTypeLeftMouseDragged, NSMakePoint(point.x + 10, point.y),
                                         NSEventModifierFlagCommand)];
    [editor mouseUp:SCEPointerEvent(editor, NSEventTypeLeftMouseUp, point, NSEventModifierFlagCommand)];
    INTERACTION_CHECK(editor.openCount == 1, "dragging a pressed link must cancel URL opening");
    [editor mouseDown:SCEPointerEvent(editor, NSEventTypeLeftMouseDown, point, NSEventModifierFlagCommand)];
    [editor mouseUp:SCEPointerEvent(editor, NSEventTypeLeftMouseUp, trailingPoint, NSEventModifierFlagCommand)];
    INTERACTION_CHECK(editor.openCount == 1, "releasing outside the pressed link must cancel URL opening");
    [editor mouseMoved:SCEPointerEvent(editor, NSEventTypeMouseMoved, point, NSEventModifierFlagCommand)];
    [editor mouseExited:SCEPointerEvent(editor, NSEventTypeMouseMoved, point, NSEventModifierFlagCommand)];
    INTERACTION_CHECK([[editor valueForKey:@"hoveredLinkRange"] rangeValue].location == NSNotFound,
                      "leaving the editor must clear link hover feedback");
    [editor mouseDown:SCEPointerEvent(editor, NSEventTypeLeftMouseDown, point, NSEventModifierFlagCommand)];
    editor.automaticLinkDetectionEnabled = NO;
    [editor mouseUp:SCEPointerEvent(editor, NSEventTypeLeftMouseUp, point, NSEventModifierFlagCommand)];
    INTERACTION_CHECK(![editor URLAtPoint:point effectiveRange:&range] && range.location == NSNotFound &&
                          editor.openCount == 1,
                      "disabling detection must cancel pending clicks and stop URL hit testing");
    editor.automaticLinkDetectionEnabled = YES;
    editor.editable = YES;
    editor.focusable = YES;
    [editor mouseDown:SCEPointerEvent(editor, NSEventTypeLeftMouseDown, point, NSEventModifierFlagCommand)];
    [editor insertText:@"x" replacementRange:NSMakeRange(expectedRange.location, 5)];
    [editor mouseUp:SCEPointerEvent(editor, NSEventTypeLeftMouseUp, point, NSEventModifierFlagCommand)];
    INTERACTION_CHECK(editor.openCount == 1, "editing the document must invalidate a pending URL click");
    editor.string = @"plain document text";
    INTERACTION_CHECK(![editor URLAtPoint:point effectiveRange:NULL],
                      "replacing the document must invalidate cached URLs");
    puts(
        "PASS links: UTF-16 detection, punctuation, web schemes, glyph hit testing, hover pixels, read-only clicks, cancellation");
}

static NSEvent *SCETrackingEvent(SCEEditorView *editor, NSEventType type, NSPoint point,
                                 NSEventModifierFlags modifiers) {
    return [NSEvent enterExitEventWithType:type
                                  location:[editor convertPoint:point toView:nil]
                             modifierFlags:modifiers
                                 timestamp:NSProcessInfo.processInfo.systemUptime
                              windowNumber:editor.window.windowNumber
                                   context:nil
                               eventNumber:0
                            trackingNumber:0
                                  userData:NULL];
}

// Integrators host the editor as the document view of a scroll view. Changing the
// hovered link invalidates cursor rectangles, and AppKit then sends cursor-update
// events whose modifier flags can contain only the device-dependent Command bit
// (0x8). Those events must not clear the underline while Command remains held.
static void SCECheckLinkHoverTrackingEvents(void) {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 900, 400)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.releasedWhenClosed = NO;
    NSScrollView *scroll = [SCEInteractionEditorView scrollableEditorView];
    scroll.frame = window.contentView.bounds;
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [window.contentView addSubview:scroll];
    SCEInteractionEditorView *editor = (SCEInteractionEditorView *)scroll.documentView;
    editor.string = @"// Documentation: https://example.com/documentation/\n";
    [window layoutIfNeeded];
    NSRange expectedRange = [editor.string rangeOfString:@"https://example.com/documentation/"];
    NSPoint point = SCEPointForTextOffset(editor, expectedRange.location + 8);
    const NSEventModifierFlags deviceCommandOnly = 0x8;

    editor.simulatedModifierFlags = NSEventModifierFlagCommand;
    [editor mouseMoved:SCEPointerEvent(editor, NSEventTypeMouseMoved, point, NSEventModifierFlagCommand)];
    INTERACTION_CHECK(NSEqualRanges([[editor valueForKey:@"hoveredLinkRange"] rangeValue], expectedRange),
                      "Command-hover must activate links in an editor hosted by a scroll view");
    [editor cursorUpdate:SCETrackingEvent(editor, NSEventTypeCursorUpdate, point, deviceCommandOnly)];
    INTERACTION_CHECK(NSEqualRanges([[editor valueForKey:@"hoveredLinkRange"] rangeValue], expectedRange),
                      "a cursor update must keep the underline while Command remains held");

    [editor mouseExited:SCETrackingEvent(editor, NSEventTypeMouseExited, point, 0)];
    [editor mouseEntered:SCETrackingEvent(editor, NSEventTypeMouseEntered, point, 0)];
    INTERACTION_CHECK(NSEqualRanges([[editor valueForKey:@"hoveredLinkRange"] rangeValue], expectedRange),
                      "entering the editor with Command held must underline the link under the pointer");

    editor.simulatedModifierFlags = 0;
    [editor cursorUpdate:SCETrackingEvent(editor, NSEventTypeCursorUpdate, point, NSEventModifierFlagCommand)];
    INTERACTION_CHECK([[editor valueForKey:@"hoveredLinkRange"] rangeValue].location == NSNotFound,
                      "a cursor update after Command is released must clear the underline");
    [window close];
    puts("PASS link hover tracking: scroll-hosted editor, cursor updates, and mouse-entered events");
}

NSUInteger SCECheckEditorInteractions(void) {
    SCEInteractionCheckCount = 0;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 900, 400)
                                                   styleMask:NSWindowStyleMaskTitled
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.releasedWhenClosed = NO;
    SCEInteractionEditorView *editor = [[SCEInteractionEditorView alloc] initWithFrame:NSMakeRect(0, 0, 900, 400)];
    window.contentView = editor;
    SCECheckContextMenus(editor);
    SCECheckLinks(editor);
    [window close];
    SCECheckLinkHoverTrackingEvents();
    return SCEInteractionCheckCount;
}
