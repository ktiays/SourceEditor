#import <AppKit/AppKit.h>
#import "SEStatusBarView.h"
@import SourceEditor;
@import SourceEditorTreeSitter;

typedef NS_ENUM(NSInteger, SEDemoSyntaxLanguage) {
    SEDemoSyntaxLanguagePlainText,
    SEDemoSyntaxLanguageJSON,
    SEDemoSyntaxLanguageJavaScript,
};

@interface SEDemoDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) SEEditorView *editor;
@property (nonatomic, strong) SEStatusBarView *statusBar;
@property (nonatomic, strong) NSMenu *syntaxMenu;
// The languages the user can pick from, in display order.
@property (nonatomic, copy) NSArray<NSNumber *> *availableLanguages;
@property (nonatomic) SEDemoSyntaxLanguage syntaxLanguage;
@end

// Status bar configuration, read from user defaults so it can also be passed
// as launch arguments. Each value is an array or a comma-separated string:
//   SEStatusBarItems   line, column, lineCount, language (all by default)
//   SESyntaxLanguages  plaintext, json, javascript (all by default)
// An empty value hides that part; a single language is fixed.
static NSString *const SEDemoStatusBarItemsKey = @"SEStatusBarItems";
static NSString *const SEDemoSyntaxLanguagesKey = @"SESyntaxLanguages";

static NSArray<NSString *> *SEDemoStringList(NSString *key, NSArray<NSString *> *defaultValue) {
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

static NSString *SEDemoSyntaxLanguageName(SEDemoSyntaxLanguage language) {
    switch (language) {
    case SEDemoSyntaxLanguagePlainText:
        return @"Plain Text";
    case SEDemoSyntaxLanguageJSON:
        return @"JSON";
    case SEDemoSyntaxLanguageJavaScript:
        return @"JavaScript";
    }
    return @"Plain Text";
}

@implementation SEDemoDelegate

- (void)loadConfiguration {
    NSDictionary<NSString *, NSNumber *> *identifiers = @{
        @"plaintext" : @(SEDemoSyntaxLanguagePlainText),
        @"json" : @(SEDemoSyntaxLanguageJSON),
        @"javascript" : @(SEDemoSyntaxLanguageJavaScript),
    };
    NSMutableArray<NSNumber *> *languages = [NSMutableArray array];
    for (NSString *name in SEDemoStringList(SEDemoSyntaxLanguagesKey, @[ @"plaintext", @"json", @"javascript" ])) {
        NSNumber *language = identifiers[name.lowercaseString];
        if (!language) {
            NSLog(@"Ignoring unknown syntax language \"%@\"", name);
        } else if (![languages containsObject:language]) {
            [languages addObject:language];
        }
    }
    self.availableLanguages = languages;
}

- (NSArray<SEStatusBarItem> *)configuredStatusBarItems {
    NSArray<SEStatusBarItem> *known =
        @[ SEStatusBarItemLine, SEStatusBarItemColumn, SEStatusBarItemLineCount, SEStatusBarItemLanguage ];
    NSMutableArray<SEStatusBarItem> *items = [NSMutableArray array];
    for (NSString *name in SEDemoStringList(SEDemoStatusBarItemsKey, known)) {
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
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
        | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.title = @"SourceEditor";
    self.window.minSize = NSMakeSize(420, 300);
    self.window.delegate = self;
    self.window.releasedWhenClosed = NO;
    NSScrollView *scroll = [SEEditorView scrollableEditorView];
    scroll.automaticallyAdjustsContentInsets = NO;
    self.editor = (SEEditorView *)scroll.documentView;
    self.editor.string = @"// SourceEditor · Objective-C + Core Text\n"
                          "// A native editing surface, packaged with SwiftPM.\n"
                          "\n"
                          "#import <AppKit/AppKit.h>\n"
                          "@import SourceEditor;\n"
                          "\n"
                          "@interface WorkspaceController : NSViewController\n"
                          "@property (nonatomic, strong) SEEditorView *editor;\n"
                          "@end\n"
                          "\n"
                          "@implementation WorkspaceController\n"
                          "\n"
                          "- (void)loadView {\n"
                          "    NSScrollView *scroll = [SEEditorView scrollableEditorView];\n"
                          "    self.editor = (SEEditorView *)scroll.documentView;\n"
                          "    self.editor.font = [NSFont monospacedSystemFontOfSize:12\n"
                          "                                                weight:NSFontWeightRegular];\n"
                          "    self.editor.string = @\"Hello, native editor.\";\n"
                          "    self.view = scroll;\n"
                          "}\n"
                          "\n"
                          "@end\n"
                          "\n"
                          "// 输入法：可以直接在这里输入中文、日本語、한국어。\n"
                          "// Graphemes: café  café  👨‍👩‍👧‍👦  🏳️‍🌈  👍🏽\n"
                          "// Font fallback: ∑ λ → ≠ ≤ ≥ · Ελληνικά · العربية\n"
                          "// Tabs:\tcolumn one\tcolumn two\n"
                          "\n"
                          "// Try typing, selecting, undo/redo and horizontal scrolling.\n";
    NSView *content = self.window.contentView;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:scroll];
    self.statusBar = [[SEStatusBarView alloc] initWithFrame:NSZeroRect];
    self.statusBar.translatesAutoresizingMaskIntoConstraints = NO;
    NSMutableArray<NSString *> *languageTitles = [NSMutableArray array];
    for (NSNumber *language in self.availableLanguages) {
        [languageTitles addObject:SEDemoSyntaxLanguageName(language.integerValue)];
    }
    self.statusBar.languageTitles = languageTitles;
    self.statusBar.items = [self configuredStatusBarItems];
    __weak SEDemoDelegate *weakSelf = self;
    self.statusBar.languageSelectionHandler = ^(NSUInteger index) {
        [weakSelf selectSyntaxLanguage:weakSelf.availableLanguages[index].integerValue];
    };
    [content addSubview:self.statusBar];
    CGFloat statusBarInset = self.statusBar.hasVisibleItems ? SEStatusBarHeight : 0;
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
        [self.statusBar.heightAnchor constraintEqualToConstant:SEStatusBarHeight],
    ]];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(updateStatus:)
                                               name:SEEditorTextDidChangeNotification
                                             object:self.editor];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(updateStatus:)
                                               name:SEEditorSelectionDidChangeNotification
                                             object:self.editor];
    SEDemoSyntaxLanguage initialLanguage = self.availableLanguages.count > 0
        ? self.availableLanguages.firstObject.integerValue
        : SEDemoSyntaxLanguagePlainText;
    [self selectSyntaxLanguage:initialLanguage];
    [self updateStatus:nil];
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self.editor];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)updateStatus:(NSNotification *)notification {
    SETextBuffer *snapshot = self.editor.bufferSnapshot;
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
    NSMenuItem *viewItem = [[NSMenuItem alloc] init];
    [main addItem:viewItem];
    NSMenu *view = [[NSMenu alloc] initWithTitle:@"View"];
    viewItem.submenu = view;
    [self addItem:@"Increase Font Size" action:@selector(increaseFont:) key:@"+" toMenu:view].target = self;
    [self addItem:@"Decrease Font Size" action:@selector(decreaseFont:) key:@"-" toMenu:view].target = self;
    [self addItem:@"Toggle Line Numbers" action:@selector(toggleLineNumbers:) key:@"" toMenu:view].target = self;
    [self addItem:@"Toggle Scope Guide" action:@selector(toggleScopeGuide:) key:@"" toMenu:view].target = self;
    // The menu only offers a choice; with zero or one language there is none.
    if (self.availableLanguages.count > 1) {
        NSMenuItem *syntaxItem = [[NSMenuItem alloc] init];
        [main addItem:syntaxItem];
        self.syntaxMenu = [[NSMenu alloc] initWithTitle:@"Syntax"];
        syntaxItem.submenu = self.syntaxMenu;
        for (NSNumber *language in self.availableLanguages) {
            NSMenuItem *item = [self addItem:SEDemoSyntaxLanguageName(language.integerValue)
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

- (void)selectSyntaxLanguage:(SEDemoSyntaxLanguage)syntaxLanguage {
    if (![self.availableLanguages containsObject:@(syntaxLanguage)]) {
        syntaxLanguage = SEDemoSyntaxLanguagePlainText;
    }
    SETreeSitterHighlighter *highlighter = nil;
    if (syntaxLanguage != SEDemoSyntaxLanguagePlainText) {
        NSError *error = nil;
        SETreeSitterLanguage language
            = syntaxLanguage == SEDemoSyntaxLanguageJSON ? SETreeSitterLanguageJSON : SETreeSitterLanguageJavaScript;
        highlighter = [[SETreeSitterHighlighter alloc] initWithLanguage:language error:&error];
        if (!highlighter) {
            NSLog(@"Could not load syntax highlighter: %@", error.localizedDescription);
            syntaxLanguage = SEDemoSyntaxLanguagePlainText;
        }
    }
    self.editor.syntaxHighlighter = highlighter;
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
        SEDemoDelegate *delegate = [[SEDemoDelegate alloc] init];
        application.delegate = delegate;
        [application run];
        (void)delegate;
    }
    return 0;
}
