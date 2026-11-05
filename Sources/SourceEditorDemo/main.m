#import <AppKit/AppKit.h>
#import "SCEStatusBarView.h"
@import SourceEditor;
@import SourceEditorTreeSitter;

typedef NS_ENUM(NSInteger, SCEDemoSyntaxLanguage) {
    SCEDemoSyntaxLanguagePlainText,
    SCEDemoSyntaxLanguageJSON,
    SCEDemoSyntaxLanguageJavaScript,
};

@interface SCEDemoDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) SCEEditorView *editor;
@property (nonatomic, strong) SCEStatusBarView *statusBar;
@property (nonatomic, strong) SCEFindBarView *findBar;
@property (nonatomic, strong) NSMenu *syntaxMenu;
// Available syntax languages in display order.
@property (nonatomic, copy) NSArray<NSNumber *> *availableLanguages;
@property (nonatomic) SCEDemoSyntaxLanguage syntaxLanguage;
@end

// Status bar configuration is read from user defaults and launch arguments.
// Each value is an array or a comma-separated string:
//   SCEStatusBarItems   line, column, lineCount, language (all by default)
//   SCESyntaxLanguages  plaintext, json, javascript (all by default)
// An empty value hides the corresponding control; one language displays a fixed label.
static NSString *const SCEDemoStatusBarItemsKey = @"SCEStatusBarItems";
static NSString *const SCEDemoSyntaxLanguagesKey = @"SCESyntaxLanguages";

static NSArray<NSString *> *SCEDemoStringList(NSString *key, NSArray<NSString *> *defaultValue) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:key];
    NSArray *components = nil;
    if ([value isKindOfClass:NSArray.class]) {
        components = value;
    } else if ([value isKindOfClass:NSString.class]) {
        components = [value componentsSeparatedByString:@","];
    } else {
        return defaultValue;
    }
    NSMutableArray<NSString *> *list = [NSMutableArray array];
    for (id component in components) {
        if (![component isKindOfClass:NSString.class]) {
            continue;
        }
        NSString *trimmed = [component stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length > 0) {
            [list addObject:trimmed];
        }
    }
    return list;
}

static NSString *SCEDemoSyntaxLanguageName(SCEDemoSyntaxLanguage language) {
    switch (language) {
        case SCEDemoSyntaxLanguagePlainText:
            return @"Plain Text";
        case SCEDemoSyntaxLanguageJSON:
            return @"JSON";
        case SCEDemoSyntaxLanguageJavaScript:
            return @"JavaScript";
    }
    return @"Plain Text";
}

@implementation SCEDemoDelegate

- (void)loadConfiguration {
    NSDictionary<NSString *, NSNumber *> *identifiers = @{
        @"plaintext" : @(SCEDemoSyntaxLanguagePlainText),
        @"json" : @(SCEDemoSyntaxLanguageJSON),
        @"javascript" : @(SCEDemoSyntaxLanguageJavaScript),
    };
    NSMutableArray<NSNumber *> *languages = [NSMutableArray array];
    for (NSString *name in SCEDemoStringList(SCEDemoSyntaxLanguagesKey, @[ @"plaintext", @"json", @"javascript" ])) {
        NSNumber *language = identifiers[name.lowercaseString];
        if (!language) {
            NSLog(@"Ignoring unknown syntax language \"%@\"", name);
        } else if (![languages containsObject:language]) {
            [languages addObject:language];
        }
    }
    self.availableLanguages = languages;
}

- (NSArray<SCEStatusBarItem> *)configuredStatusBarItems {
    NSArray<SCEStatusBarItem> *known =
        @[ SCEStatusBarItemLine, SCEStatusBarItemColumn, SCEStatusBarItemLineCount, SCEStatusBarItemLanguage ];
    NSMutableArray<SCEStatusBarItem> *items = [NSMutableArray array];
    for (NSString *name in SCEDemoStringList(SCEDemoStatusBarItemsKey, known)) {
        NSUInteger index = [known indexOfObjectPassingTest:^BOOL(NSString *item, NSUInteger idx, BOOL *stop) {
            return [item caseInsensitiveCompare:name] == NSOrderedSame;
        }];
        if (index == NSNotFound) {
            NSLog(@"Ignoring unknown status bar item \"%@\"", name);
        } else {
            [items addObject:known[index]];
        }
    }
    return items;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [self loadConfiguration];
    [self createMenus];
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1000, 720)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                        NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.title = @"SourceEditor";
    self.window.minSize = NSMakeSize(420, 300);
    self.window.delegate = self;
    self.window.releasedWhenClosed = NO;
    NSScrollView *scroll = [SCEEditorView scrollableEditorView];
    scroll.automaticallyAdjustsContentInsets = NO;
    self.editor = (SCEEditorView *)scroll.documentView;
    self.editor.string = @"// SourceEditor · Objective-C + Core Text\n"
                          "// A native editing surface, packaged with SwiftPM.\n"
                          "// Command-click documentation: https://developer.apple.com/documentation/appkit/\n"
                          "// Right-click a selection for editing commands.\n"
                          "\n"
                          "#import <AppKit/AppKit.h>\n"
                          "@import SourceEditor;\n"
                          "\n"
                          "@interface SCEDocumentViewController : NSViewController\n"
                          "@property (nonatomic, strong) SCEEditorView *editor;\n"
                          "@end\n"
                          "\n"
                          "@implementation SCEDocumentViewController\n"
                          "\n"
                          "- (void)loadView {\n"
                          "    NSScrollView *scroll = [SCEEditorView scrollableEditorView];\n"
                          "    self.editor = (SCEEditorView *)scroll.documentView;\n"
                          "    self.editor.font = [NSFont monospacedSystemFontOfSize:12\n"
                          "                                                weight:NSFontWeightRegular];\n"
                          "    self.editor.string = @\"Document text.\";\n"
                          "    self.view = scroll;\n"
                          "}\n"
                          "\n"
                          "@end\n"
                          "\n"
                          "// Input methods: test composition and candidate placement here.\n"
                          "// Grapheme boundaries: test combining marks and joined emoji sequences.\n"
                          "// Font fallback: test characters outside the editor font's coverage.\n"
                          "// Tabs:\tcolumn one\tcolumn two\n"
                          "\n"
                          "// Test typing, selection, undo, redo, and horizontal scrolling.\n";
    NSView *content = self.window.contentView;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:scroll];
    self.statusBar = [[SCEStatusBarView alloc] initWithFrame:NSZeroRect];
    self.statusBar.translatesAutoresizingMaskIntoConstraints = NO;
    NSMutableArray<NSString *> *languageTitles = [NSMutableArray array];
    for (NSNumber *language in self.availableLanguages) {
        [languageTitles addObject:SCEDemoSyntaxLanguageName(language.integerValue)];
    }
    self.statusBar.languageTitles = languageTitles;
    self.statusBar.items = [self configuredStatusBarItems];
    __weak SCEDemoDelegate *weakSelf = self;
    self.statusBar.languageSelectionHandler = ^(NSUInteger index) {
        [weakSelf selectSyntaxLanguage:weakSelf.availableLanguages[index].integerValue];
    };
    [content addSubview:self.statusBar];
    CGFloat statusBarInset = self.statusBar.hasVisibleItems ? SCEStatusBarHeight : 0;
    self.statusBar.hidden = !self.statusBar.hasVisibleItems;
    scroll.contentInsets = NSEdgeInsetsMake(0, 0, statusBarInset, 0);
    scroll.scrollerInsets = NSEdgeInsetsMake(0, 0, statusBarInset, 0);
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:content.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        [self.statusBar.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [self.statusBar.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [self.statusBar.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        [self.statusBar.heightAnchor constraintEqualToConstant:SCEStatusBarHeight],
    ]];
    [self createFindBarInView:content];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(updateStatus:)
                                               name:SCEEditorTextDidChangeNotification
                                             object:self.editor];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(updateStatus:)
                                               name:SCEEditorSelectionDidChangeNotification
                                             object:self.editor];
    SCEDemoSyntaxLanguage initialLanguage = self.availableLanguages.count > 0
                                                ? self.availableLanguages.firstObject.integerValue
                                                : SCEDemoSyntaxLanguagePlainText;
    [self selectSyntaxLanguage:initialLanguage];
    [self updateStatus:nil];
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self.editor];
    [NSApp activateIgnoringOtherApps:YES];
}

// The find bar floats over the top trailing corner of the editor. It stays in
// the view hierarchy while hidden so that its search string persists.
- (void)createFindBarInView:(NSView *)content {
    self.findBar = [[SCEFindBarView alloc] initWithFrame:NSZeroRect];
    self.findBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.findBar.editor = self.editor;
    self.findBar.hidden = YES;
    __weak SCEDemoDelegate *weakSelf = self;
    self.findBar.dismissalHandler = ^{
        [weakSelf setFindBarVisible:NO];
    };
    [content addSubview:self.findBar];
    [NSLayoutConstraint activateConstraints:@[
        [self.findBar.topAnchor constraintEqualToAnchor:content.topAnchor constant:12],
        [self.findBar.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
        [self.findBar.leadingAnchor constraintGreaterThanOrEqualToAnchor:content.leadingAnchor constant:20],
    ]];
}

- (void)setFindBarVisible:(BOOL)visible {
    if (visible == !self.findBar.hidden) {
        return;
    }
    if (visible) {
        self.findBar.alphaValue = 0;
        self.findBar.hidden = NO;
    }
    [NSAnimationContext
        runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.18;
            self.findBar.animator.alphaValue = visible ? 1 : 0;
        }
        completionHandler:^{
            if (!visible && self.findBar.alphaValue == 0) {
                self.findBar.hidden = YES;
            }
        }];
}

- (void)showFindBar:(id)sender {
    [self setFindBarVisible:YES];
    [self.findBar beginSearch];
}

- (void)findNextMatch:(id)sender {
    if (!self.findBar.isSearching) {
        [self showFindBar:sender];
    }
    [self.findBar findNext:sender];
}

- (void)findPreviousMatch:(id)sender {
    if (!self.findBar.isSearching) {
        [self showFindBar:sender];
    }
    [self.findBar findPrevious:sender];
}

- (void)useSelectionForFind:(id)sender {
    NSRange selection = self.editor.selectedRange;
    if (!selection.length) {
        return;
    }
    self.findBar.searchString = [self.editor.bufferSnapshot substringWithUTF16Range:selection];
    if (!self.findBar.isSearching) {
        [self setFindBarVisible:YES];
        [self.findBar beginSearch];
    }
    // Return focus to the editor so that Command-G continues from the selection.
    [self.window makeFirstResponder:self.editor];
}

- (void)updateStatus:(NSNotification *)notification {
    SCETextBuffer *snapshot = self.editor.bufferSnapshot;
    NSUInteger offset = self.editor.selectedRange.location;
    NSUInteger line = [snapshot lineIndexForUTF16Offset:offset];
    NSRange range = [snapshot UTF16RangeOfLine:line includingLineEnding:NO];
    [self.statusBar setLine:line + 1 column:offset - range.location + 1 lineCount:snapshot.lineCount];
}

- (NSMenuItem *)addItem:(NSString *)title action:(SEL)action key:(NSString *)key toMenu:(NSMenu *)menu {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key];
    [menu addItem:item];
    return item;
}

- (void)createMenus {
    NSMenu *main = [[NSMenu alloc] init];
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    [main addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"SourceEditor"];
    appItem.submenu = appMenu;
    [self addItem:@"About SourceEditor" action:@selector(orderFrontStandardAboutPanel:) key:@"" toMenu:appMenu];
    [appMenu addItem:NSMenuItem.separatorItem];
    [self addItem:@"Hide SourceEditor" action:@selector(hide:) key:@"h" toMenu:appMenu];
    [appMenu addItem:NSMenuItem.separatorItem];
    [self addItem:@"Quit SourceEditor" action:@selector(terminate:) key:@"q" toMenu:appMenu];
    NSMenuItem *editItem = [[NSMenuItem alloc] init];
    [main addItem:editItem];
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
    editItem.submenu = edit;
    [self addItem:@"Undo" action:@selector(undo:) key:@"z" toMenu:edit];
    NSMenuItem *redo = [self addItem:@"Redo" action:@selector(redo:) key:@"z" toMenu:edit];
    redo.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [edit addItem:NSMenuItem.separatorItem];
    [self addItem:@"Cut" action:@selector(cut:) key:@"x" toMenu:edit];
    [self addItem:@"Copy" action:@selector(copy:) key:@"c" toMenu:edit];
    [self addItem:@"Paste" action:@selector(paste:) key:@"v" toMenu:edit];
    [self addItem:@"Select All" action:@selector(selectAll:) key:@"a" toMenu:edit];
    [edit addItem:NSMenuItem.separatorItem];
    NSMenuItem *findItem = [self addItem:@"Find" action:nil key:@"" toMenu:edit];
    NSMenu *find = [[NSMenu alloc] initWithTitle:@"Find"];
    findItem.submenu = find;
    [self addItem:@"Find\u2026" action:@selector(showFindBar:) key:@"f" toMenu:find].target = self;
    [self addItem:@"Find Next" action:@selector(findNextMatch:) key:@"g" toMenu:find].target = self;
    NSMenuItem *findPrevious = [self addItem:@"Find Previous"
                                      action:@selector(findPreviousMatch:)
                                         key:@"g"
                                      toMenu:find];
    findPrevious.target = self;
    findPrevious.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [self addItem:@"Use Selection for Find" action:@selector(useSelectionForFind:) key:@"e" toMenu:find].target = self;
    NSMenuItem *viewItem = [[NSMenuItem alloc] init];
    [main addItem:viewItem];
    NSMenu *view = [[NSMenu alloc] initWithTitle:@"View"];
    viewItem.submenu = view;
    [self addItem:@"Increase Font Size" action:@selector(increaseFont:) key:@"+" toMenu:view].target = self;
    [self addItem:@"Decrease Font Size" action:@selector(decreaseFont:) key:@"-" toMenu:view].target = self;
    [self addItem:@"Toggle Line Numbers" action:@selector(toggleLineNumbers:) key:@"" toMenu:view].target = self;
    [self addItem:@"Toggle Scope Guide" action:@selector(toggleScopeGuide:) key:@"" toMenu:view].target = self;
    // Display a syntax menu when multiple languages are available.
    if (self.availableLanguages.count > 1) {
        NSMenuItem *syntaxItem = [[NSMenuItem alloc] init];
        [main addItem:syntaxItem];
        self.syntaxMenu = [[NSMenu alloc] initWithTitle:@"Syntax"];
        syntaxItem.submenu = self.syntaxMenu;
        for (NSNumber *language in self.availableLanguages) {
            NSMenuItem *item = [self addItem:SCEDemoSyntaxLanguageName(language.integerValue)
                                      action:@selector(changeSyntaxLanguage:)
                                         key:@""
                                      toMenu:self.syntaxMenu];
            item.target = self;
            item.tag = language.integerValue;
        }
    }
    NSApp.mainMenu = main;
}

- (void)updateSyntaxLanguageSelection {
    NSUInteger index = [self.availableLanguages indexOfObject:@(self.syntaxLanguage)];
    if (index != NSNotFound) {
        self.statusBar.selectedLanguageIndex = index;
    }
    for (NSMenuItem *item in self.syntaxMenu.itemArray) {
        item.state = item.tag == self.syntaxLanguage ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

- (void)changeSyntaxLanguage:(NSMenuItem *)sender {
    [self selectSyntaxLanguage:sender.tag];
}

- (void)selectSyntaxLanguage:(SCEDemoSyntaxLanguage)syntaxLanguage {
    if (![self.availableLanguages containsObject:@(syntaxLanguage)]) {
        syntaxLanguage = SCEDemoSyntaxLanguagePlainText;
    }
    SCETreeSitterHighlighter *highlighter = nil;
    if (syntaxLanguage == SCEDemoSyntaxLanguageJSON) {
        NSError *error = nil;
        highlighter = [[SCETreeSitterHighlighter alloc] initWithLanguage:SCETreeSitterLanguageJSON error:&error];
        if (!highlighter) {
            NSLog(@"Could not load syntax highlighter: %@", error.localizedDescription);
            syntaxLanguage = SCEDemoSyntaxLanguagePlainText;
        }
    }
    self.editor.syntaxHighlighter = highlighter;
    switch (syntaxLanguage) {
        case SCEDemoSyntaxLanguageJSON:
            self.editor.languageConfiguration = SCELanguageConfiguration.languageConfigurationForJSON;
            break;
        case SCEDemoSyntaxLanguageJavaScript:
            self.editor.languageConfiguration = SCELanguageConfiguration.languageConfigurationForJavaScript;
            break;
        case SCEDemoSyntaxLanguagePlainText:
            self.editor.languageConfiguration = nil;
            break;
    }
    self.editor.bracketCompletionMode =
        self.editor.languageConfiguration ? SCEBracketCompletionModeOnNewline : SCEBracketCompletionModeDisabled;
    self.syntaxLanguage = syntaxLanguage;
    [self updateSyntaxLanguageSelection];
    [self.window makeFirstResponder:self.editor];
}

- (void)increaseFont:(id)sender {
    self.editor.font = [NSFont monospacedSystemFontOfSize:MIN(40, self.editor.font.pointSize + 1)
                                                   weight:NSFontWeightRegular];
}

- (void)decreaseFont:(id)sender {
    self.editor.font = [NSFont monospacedSystemFontOfSize:MAX(9, self.editor.font.pointSize - 1)
                                                   weight:NSFontWeightRegular];
}

- (void)toggleLineNumbers:(id)sender {
    self.editor.showsLineNumbers = !self.editor.showsLineNumbers;
}

- (void)toggleScopeGuide:(id)sender {
    self.editor.showsScopeGuide = !self.editor.showsScopeGuide;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *application = NSApplication.sharedApplication;
        [application setActivationPolicy:NSApplicationActivationPolicyRegular];
        SCEDemoDelegate *delegate = [[SCEDemoDelegate alloc] init];
        application.delegate = delegate;
        [application run];
        (void)delegate;
    }
    return 0;
}
