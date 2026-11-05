@import SourceEditor;
#import "SCEEditingChecks.h"
#import "../../Sources/SourceEditor/SCELanguageConfigurationInternal.h"
#import "../../Sources/SourceEditor/SCELineLayoutCache.h"

static NSUInteger SCEEditingCheckCount;
#define EDITING_CHECK(condition, message)                                                                              \
    do {                                                                                                               \
        SCEEditingCheckCount++;                                                                                        \
        if (!(condition)) {                                                                                            \
            fprintf(stderr, "FAIL configured editing at line %d: %s\n", __LINE__, (message));                          \
            exit(1);                                                                                                   \
        }                                                                                                              \
    } while (0)

@interface SCEEditorView (LiteralInputChecks)
- (void)insertLiteralText:(id)value replacementRange:(NSRange)replacementRange;
@end

// Keep text delivery deterministic while exercising keyDown's input scope.
// The existing keyboard checks exercise AppKit's native key interpretation.
@interface SCEConfiguredInputEditor : SCEEditorView
@property (nonatomic, copy) void (^inputAction)(SCEConfiguredInputEditor *editor);
@end

@implementation SCEConfiguredInputEditor

- (void)interpretKeyEvents:(NSArray<NSEvent *> *)events {
    if (self.inputAction) {
        self.inputAction(self);
    } else {
        [self insertText:events.firstObject.characters replacementRange:NSMakeRange(NSNotFound, 0)];
    }
}

@end

@interface SCEConfiguredContextProvider : NSObject <SCELanguageContextProvider>
@property (nonatomic) SCELanguageContext context;
@property (nonatomic) NSUInteger requestedOffset;
@property (nonatomic, strong) SCETextBuffer *receivedSnapshot;
@end

@implementation SCEConfiguredContextProvider

- (SCELanguageContext)contextAtUTF16Offset:(NSUInteger)offset inBuffer:(SCETextBuffer *)snapshot {
    self.requestedOffset = offset;
    self.receivedSnapshot = snapshot;
    return self.context;
}

@end

@interface SCEContextReadMetrics : NSObject
@property (nonatomic) NSUInteger numberOfUTF16UnitsRead;
@property (nonatomic) NSUInteger documentStringReads;
@end

@implementation SCEContextReadMetrics
@end

@interface SCEContextCountingBuffer : SCETextBuffer
@property (nonatomic, strong) SCEContextReadMetrics *metrics;
@end

@implementation SCEContextCountingBuffer

- (instancetype)initWithString:(NSString *)string {
    if ((self = [super initWithString:string])) {
        _metrics = [[SCEContextReadMetrics alloc] init];
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    SCEContextCountingBuffer *copy = [super copyWithZone:zone];
    copy.metrics = self.metrics;
    return copy;
}

- (void)getUTF16Characters:(unichar *)characters range:(NSRange)range {
    self.metrics.numberOfUTF16UnitsRead += range.length;
    [super getUTF16Characters:characters range:range];
}

- (NSString *)string {
    self.metrics.documentStringReads++;
    return [super string];
}

@end

static NSRange SCERemoveCaretMarker(NSString *markedText, NSString **text) {
    NSRange marker = [markedText rangeOfString:@"|"];
    EDITING_CHECK(marker.location != NSNotFound, "fixture must contain a caret marker");
    *text = [markedText stringByReplacingCharactersInRange:marker withString:@""];
    return NSMakeRange(marker.location, 0);
}

static void SCESetMarkedDocument(SCEEditorView *editor, NSString *markedText) {
    NSString *text;
    NSRange selection = SCERemoveCaretMarker(markedText, &text);
    editor.string = text;
    editor.selectedRange = selection;
}

static void SCEExpectMarkedDocument(SCEEditorView *editor, NSString *markedText) {
    NSString *text;
    NSRange selection = SCERemoveCaretMarker(markedText, &text);
    if (![editor.string isEqualToString:text]) {
        fprintf(stderr, "Expected: %s\nActual:   %s\n", text.UTF8String, editor.string.UTF8String);
    }
    EDITING_CHECK([editor.string isEqualToString:text], "edited document differs");
    EDITING_CHECK(NSEqualRanges(editor.selectedRange, selection), "caret position differs");
}

static void SCEPressEditingCommand(SCEEditorView *editor, SEL selector) {
    [editor doCommandBySelector:selector];
}

static void SCETypeConfiguredText(SCEEditorView *editor, NSString *text) {
    unsigned short keyCode = [text isEqualToString:@"\t"] ? 48 : [text isEqualToString:@"\r"] ? 36 : 0;
    NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                      location:NSZeroPoint
                                 modifierFlags:0
                                     timestamp:0
                                  windowNumber:editor.window.windowNumber
                                       context:nil
                                    characters:text
                   charactersIgnoringModifiers:text
                                     isARepeat:NO
                                       keyCode:keyCode];
    [editor keyDown:event];
}

static void SCECheckIndentationPreferences(void) {
    SCEEditorView *editor = [[SCEEditorView alloc] initWithFrame:NSMakeRect(0, 0, 600, 400)];
    EDITING_CHECK(editor.tabWidth == 4 && editor.indentationWidth == 0 && editor.insertsSpacesForTabs,
                  "default indentation must use four space columns");
    EDITING_CHECK(editor.isAutomaticIndentationEnabled && !editor.languageConfiguration &&
                      editor.bracketCompletionMode == SCEBracketCompletionModeDisabled,
                  "language-specific editing must be opt-in");
    SCESetMarkedDocument(editor, @"|");
    SCEPressEditingCommand(editor, @selector(insertTab:));
    SCEExpectMarkedDocument(editor, @"    |");
    [editor undo:nil];
    SCEExpectMarkedDocument(editor, @"|");
    EDITING_CHECK(!editor.undoManager.canUndo, "one Tab must produce exactly one undo operation");
    [editor redo:nil];
    SCEExpectMarkedDocument(editor, @"    |");

    SCESetMarkedDocument(editor, @" |text");
    SCEPressEditingCommand(editor, @selector(insertTab:));
    SCEExpectMarkedDocument(editor, @"    |text");
    SCESetMarkedDocument(editor, @"a\t|text");
    SCEPressEditingCommand(editor, @selector(insertTab:));
    SCEExpectMarkedDocument(editor, @"a\t    |text");
    // A combining accent adds a UTF-16 unit without adding a display column.
    SCESetMarkedDocument(editor, @"e\u0301|");
    SCEPressEditingCommand(editor, @selector(insertTab:));
    SCEExpectMarkedDocument(editor, @"e\u0301   |");

    editor.tabWidth = 2;
    SCESetMarkedDocument(editor, @"|");
    SCEPressEditingCommand(editor, @selector(insertTab:));
    SCEExpectMarkedDocument(editor, @"  |");
    editor.tabWidth = 4;
    editor.indentationWidth = 2;
    SCESetMarkedDocument(editor, @"\t|");
    SCEPressEditingCommand(editor, @selector(insertTab:));
    SCEExpectMarkedDocument(editor, @"\t  |");
    editor.insertsSpacesForTabs = NO;
    SCESetMarkedDocument(editor, @" |");
    SCEPressEditingCommand(editor, @selector(insertTab:));
    SCEExpectMarkedDocument(editor, @" \t|");
    SCESetMarkedDocument(editor, @"\t  text|");
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    SCEExpectMarkedDocument(editor, @"\t  text\n\t  |");
    editor.insertsSpacesForTabs = YES;
    SCESetMarkedDocument(editor, @"\t  text|");
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    SCEExpectMarkedDocument(editor, @"\t  text\n      |");

    editor.tabWidth = 0;
    editor.indentationWidth = NSUIntegerMax;
    EDITING_CHECK(editor.tabWidth == 1 && editor.indentationWidth == 32, "width limits must be enforced");
    editor.tabWidth = NSUIntegerMax;
    editor.indentationWidth = 0;
    EDITING_CHECK(editor.tabWidth == 32 && editor.indentationWidth == 0,
                  "zero indentation width must inherit tab width");
    editor.tabWidth = 4;
    SCESetMarkedDocument(editor, @"\ttext|");
    SCELineLayoutCache *cache = [editor valueForKey:@"layoutCache"];
    CGFloat originalTabX = [[cache layoutForLineAtIndex:0] xForUTF16Index:1];
    editor.tabWidth = 8;
    CGFloat changedTabX = [[cache layoutForLineAtIndex:0] xForUTF16Index:1];
    EDITING_CHECK(changedTabX > originalTabX, "tab width must invalidate literal-tab layout");
    SCEExpectMarkedDocument(editor, @"\ttext|");
    editor.editable = NO;
    SCEPressEditingCommand(editor, @selector(insertTab:));
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    SCEExpectMarkedDocument(editor, @"\ttext|");
    puts("PASS indentation: defaults, independent widths, tab stops, Unicode columns, literal tabs, layout, undo");
}

static void SCECheckNewlineCompletion(void) {
    SCEEditorView *editor = [[SCEEditorView alloc] initWithFrame:NSMakeRect(0, 0, 600, 400)];
    SCELanguageConfiguration *jsonConfiguration = SCELanguageConfiguration.languageConfigurationForJSON;
    editor.languageConfiguration = jsonConfiguration;
    editor.bracketCompletionMode = SCEBracketCompletionModeOnNewline;
    EDITING_CHECK(!editor.syntaxHighlighter, "completion must work without a highlighter");
    SCESetMarkedDocument(editor, @"{|");
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    SCEExpectMarkedDocument(editor, @"{\n    |\n}");
    [editor undo:nil];
    SCEExpectMarkedDocument(editor, @"{|");
    EDITING_CHECK(!editor.undoManager.canUndo, "a generated block must be one undo operation");
    [editor redo:nil];
    SCEExpectMarkedDocument(editor, @"{\n    |\n}");
    SCESetMarkedDocument(editor, @"  [|");
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    SCEExpectMarkedDocument(editor, @"  [\n      |\n  ]");
    SCESetMarkedDocument(editor, @"  {|};");
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    SCEExpectMarkedDocument(editor, @"  {\n      |\n  };");
    SCESetMarkedDocument(editor, @"{|  }");
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    SCEExpectMarkedDocument(editor, @"{\n    |\n}");
    SCESetMarkedDocument(editor, @"{|  ");
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    SCEExpectMarkedDocument(editor, @"{\n    |\n}");
    SCESetMarkedDocument(editor, @"{|\n}");
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    SCEExpectMarkedDocument(editor, @"{\n    |\n}");
    SCESetMarkedDocument(editor, @"{|\n    \"key\": 0\n}");
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    SCEExpectMarkedDocument(editor, @"{\n    |\n    \"key\": 0\n}");
    SCESetMarkedDocument(editor, @"{|\"key\": 0}");
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    SCEExpectMarkedDocument(editor, @"{\n    |\"key\": 0}");
    SCESetMarkedDocument(editor, @"{\r\n  [|");
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    SCEExpectMarkedDocument(editor, @"{\r\n  [\r\n      |\r\n  ]");

    editor.indentationWidth = 2;
    SCESetMarkedDocument(editor, @"\t{|");
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    SCEExpectMarkedDocument(editor, @"\t{\n      |\n    }");
    editor.insertsSpacesForTabs = NO;
    SCESetMarkedDocument(editor, @"\t{|");
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    SCEExpectMarkedDocument(editor, @"\t{\n\t  |\n\t}");
    editor.indentationWidth = 0;
    editor.insertsSpacesForTabs = YES;
    editor.automaticIndentationEnabled = NO;
    SCESetMarkedDocument(editor, @"  {|}");
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    SCEExpectMarkedDocument(editor, @"  {\n|}");
    editor.automaticIndentationEnabled = YES;
    editor.bracketCompletionMode = SCEBracketCompletionModeDisabled;
    SCESetMarkedDocument(editor, @"{|");
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    SCEExpectMarkedDocument(editor, @"{\n    |");
    SCESetMarkedDocument(editor, @"{|}");
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    SCEExpectMarkedDocument(editor, @"{\n    |\n}");
    editor.bracketCompletionMode = SCEBracketCompletionModeOnNewline;
    editor.languageConfiguration = nil;
    SCESetMarkedDocument(editor, @"  {|");
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    SCEExpectMarkedDocument(editor, @"  {\n  |");
    editor.languageConfiguration = jsonConfiguration;
    SCESetMarkedDocument(editor, @"\"text {|");
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    SCEExpectMarkedDocument(editor, @"\"text {\n|");

    editor.languageConfiguration = SCELanguageConfiguration.languageConfigurationForJavaScript;
    SCESetMarkedDocument(editor, @"if (ready) {|");
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    SCEExpectMarkedDocument(editor, @"if (ready) {\n    |\n}");
    // An enclosing block's closer on a following line must not satisfy a new opener.
    SCESetMarkedDocument(editor, @"function outer() {\n    inner {|\n}");
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    SCEExpectMarkedDocument(editor, @"function outer() {\n    inner {\n        |\n    }\n}");
    SCESetMarkedDocument(editor, @"function first() {|\nfunction second() {\n}");
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    SCEExpectMarkedDocument(editor, @"function first() {\n    |\n}\nfunction second() {\n}");
    SCESetMarkedDocument(editor, @"function outer() {\n    inner {|\n    }\n}");
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    SCEExpectMarkedDocument(editor, @"function outer() {\n    inner {\n        |\n    }\n}");
    SCESetMarkedDocument(editor, @"{ \"}\" {|\n}");
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    SCEExpectMarkedDocument(editor, @"{ \"}\" {\n    |\n}\n}");
    SCESetMarkedDocument(editor, @"{ x {|\n// }\n}");
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    SCEExpectMarkedDocument(editor, @"{ x {\n    |\n}\n// }\n}");
    SCESetMarkedDocument(editor, @"} {|\n}");
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    SCEExpectMarkedDocument(editor, @"} {\n    |\n}");
    SCESetMarkedDocument(editor, @"{|\n}\n}");
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    SCEExpectMarkedDocument(editor, @"{\n    |\n}\n}");
    SCESetMarkedDocument(editor, @"[ {|\n]");
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    SCEExpectMarkedDocument(editor, @"[ {\n    |\n}\n]");
    // The brace that ends a template substitution is not a code closer.
    SCESetMarkedDocument(editor, @"{\n    text = `${value}`; {|\n}");
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    SCEExpectMarkedDocument(editor, @"{\n    text = `${value}`; {\n        |\n    }\n}");
    SCESetMarkedDocument(editor, @"call(|)");
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    SCEExpectMarkedDocument(editor, @"call(\n|)");
    SCESetMarkedDocument(editor, @"// {|");
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    SCEExpectMarkedDocument(editor, @"// {\n|");
    SCESetMarkedDocument(editor, @"/* {|");
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    SCEExpectMarkedDocument(editor, @"/* {\n|");

    editor.string = @"{selected}";
    editor.selectedRange = NSMakeRange(1, 8);
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    SCEExpectMarkedDocument(editor, @"{\n|}");
    [editor undo:nil];
    EDITING_CHECK([editor.string isEqualToString:@"{selected}"] &&
                      NSEqualRanges(editor.selectedRange, NSMakeRange(1, 8)),
                  "newline replacement undo must restore the selected text and range");
    puts("PASS newline completion: JSON/JavaScript, nested indentation, existing closers, CRLF, selection, opt-out");
}

static void SCECheckTypingCompletion(void) {
    SCEConfiguredInputEditor *editor = [[SCEConfiguredInputEditor alloc] initWithFrame:NSMakeRect(0, 0, 600, 400)];
    editor.languageConfiguration = SCELanguageConfiguration.languageConfigurationForJavaScript;
    editor.bracketCompletionMode = SCEBracketCompletionModeWhileTyping;
    SCETypeConfiguredText(editor, @"{");
    SCEExpectMarkedDocument(editor, @"{|}");
    [editor undo:nil];
    SCEExpectMarkedDocument(editor, @"|");
    EDITING_CHECK(!editor.undoManager.canUndo, "typing a pair must be one undo operation");
    [editor redo:nil];
    SCEExpectMarkedDocument(editor, @"{|}");
    SCESetMarkedDocument(editor, @"|");
    SCETypeConfiguredText(editor, @"{");
    SCETypeConfiguredText(editor, @"}");
    SCEExpectMarkedDocument(editor, @"{}|");
    [editor undo:nil];
    SCEExpectMarkedDocument(editor, @"|");
    // Only generated closers are overtyped. An existing closer may belong to an
    // outer pair whose closer is missing.
    SCESetMarkedDocument(editor, @"outer(inner(value|)");
    SCETypeConfiguredText(editor, @")");
    SCEExpectMarkedDocument(editor, @"outer(inner(value)|)");
    SCESetMarkedDocument(editor, @"|\nnext");
    SCETypeConfiguredText(editor, @"(");
    SCETypeConfiguredText(editor, @"value");
    SCEExpectMarkedDocument(editor, @"(value|)\nnext");
    SCETypeConfiguredText(editor, @")");
    SCEExpectMarkedDocument(editor, @"(value)|\nnext");
    SCESetMarkedDocument(editor, @"|\nnext");
    SCETypeConfiguredText(editor, @"(");
    editor.selectedRange = NSMakeRange(4, 0);
    editor.selectedRange = NSMakeRange(1, 0);
    SCETypeConfiguredText(editor, @")");
    SCEExpectMarkedDocument(editor, @"()|)\nnext");
    SCESetMarkedDocument(editor, @"|");
    SCETypeConfiguredText(editor, @"(");
    editor.selectedRange = NSMakeRange(0, 1);
    editor.selectedRange = NSMakeRange(1, 0);
    SCETypeConfiguredText(editor, @")");
    SCEExpectMarkedDocument(editor, @"()|)");
    SCESetMarkedDocument(editor, @"|");
    SCETypeConfiguredText(editor, @"(");
    SCEExpectMarkedDocument(editor, @"(|)");
    SCESetMarkedDocument(editor, @"|}");
    SCETypeConfiguredText(editor, @"{");
    SCEExpectMarkedDocument(editor, @"{|}}");
    SCESetMarkedDocument(editor, @"|");
    SCETypeConfiguredText(editor, @"[");
    SCETypeConfiguredText(editor, @"[");
    SCEExpectMarkedDocument(editor, @"[[|]]");
    SCETypeConfiguredText(editor, @"]");
    SCETypeConfiguredText(editor, @"]");
    SCEExpectMarkedDocument(editor, @"[[]]|");
    SCESetMarkedDocument(editor, @"|text");
    SCETypeConfiguredText(editor, @"{");
    SCEExpectMarkedDocument(editor, @"{|text");
    SCESetMarkedDocument(editor, @"\"text |\"");
    SCETypeConfiguredText(editor, @"{");
    SCEExpectMarkedDocument(editor, @"\"text {|\"");
    SCESetMarkedDocument(editor, @"// |");
    SCETypeConfiguredText(editor, @"[");
    SCEExpectMarkedDocument(editor, @"// [|");
    SCESetMarkedDocument(editor, @"|");
    [editor insertText:@"{" replacementRange:NSMakeRange(NSNotFound, 0)];
    SCEExpectMarkedDocument(editor, @"{|");
    SCESetMarkedDocument(editor, @"|");
    SCETypeConfiguredText(editor, @"{}");
    SCEExpectMarkedDocument(editor, @"{}|");
    SCESetMarkedDocument(editor, @"|");
    editor.inputAction = ^(SCEConfiguredInputEditor *inputEditor) {
        [inputEditor insertText:@"{" replacementRange:NSMakeRange(0, 0)];
    };
    SCETypeConfiguredText(editor, @"{");
    SCEExpectMarkedDocument(editor, @"{|");
    // Paste uses this literal path even when invoked while interpreting a key.
    SCESetMarkedDocument(editor, @"|");
    editor.inputAction = ^(SCEConfiguredInputEditor *inputEditor) {
        [inputEditor insertLiteralText:@"{" replacementRange:NSMakeRange(NSNotFound, 0)];
    };
    SCETypeConfiguredText(editor, @"{");
    SCEExpectMarkedDocument(editor, @"{|");
    editor.inputAction = nil;

    editor.string = @"selected";
    editor.selectedRange = NSMakeRange(0, 8);
    SCETypeConfiguredText(editor, @"{");
    SCEExpectMarkedDocument(editor, @"{|");
    [editor undo:nil];
    EDITING_CHECK([editor.string isEqualToString:@"selected"] && editor.selectedRange.length == 8,
                  "typing over a selection must preserve literal replacement and undo");
    SCESetMarkedDocument(editor, @"|");
    [editor setMarkedText:@"{" selectedRange:NSMakeRange(1, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
    SCETypeConfiguredText(editor, @"{");
    SCEExpectMarkedDocument(editor, @"{|");
    [editor undo:nil];
    SCEExpectMarkedDocument(editor, @"|");
    EDITING_CHECK(!editor.undoManager.canUndo, "committing marked text must remain one undo operation");
    [editor setMarkedText:@"{" selectedRange:NSMakeRange(1, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    SCEExpectMarkedDocument(editor, @"{\n|");
    editor.string = @"";
    editor.editable = NO;
    SCETypeConfiguredText(editor, @"{");
    SCEExpectMarkedDocument(editor, @"|");
    puts("PASS typing completion: keyboard-only pairing, closer reuse, literal insertion, marked text, read-only mode");
}

static void SCEExpectContext(SCELanguageConfiguration *configuration, NSString *markedText,
                             SCELanguageContext expected) {
    NSString *text;
    NSRange selection = SCERemoveCaretMarker(markedText, &text);
    SCETextBuffer *buffer = [[SCETextBuffer alloc] initWithString:text];
    SCELanguageContext actual = [configuration contextAtUTF16Offset:selection.location inBuffer:buffer];
    if (actual != expected) {
        fprintf(stderr, "Context fixture: %s; expected %lu, actual %lu\n", markedText.UTF8String,
                (unsigned long)expected, (unsigned long)actual);
    }
    EDITING_CHECK(actual == expected, "language context differs");
}

static void SCECheckLanguageContexts(void) {
    SCELanguageConfiguration *jsonConfiguration = SCELanguageConfiguration.languageConfigurationForJSON;
    SCEExpectContext(jsonConfiguration, @"|{}", SCELanguageContextCode);
    SCEExpectContext(jsonConfiguration, @"{\"text\": \"left | right\"}", SCELanguageContextString);
    SCEExpectContext(jsonConfiguration, @"{\"text\": \"escaped \\\"|\"}", SCELanguageContextString);
    SCEExpectContext(jsonConfiguration, @"{\"text\": \"\\\\\"|}", SCELanguageContextCode);
    SCEExpectContext(jsonConfiguration, @"\"unterminated\n|", SCELanguageContextUnknown);
    SCEExpectContext(jsonConfiguration, @"/|", SCELanguageContextUnknown);
    SCELanguageConfiguration *javaScriptConfiguration = SCELanguageConfiguration.languageConfigurationForJavaScript;
    SCEExpectContext(javaScriptConfiguration, @"const text = 'value |';", SCELanguageContextString);
    SCEExpectContext(javaScriptConfiguration, @"const text = \"value |\";", SCELanguageContextString);
    SCEExpectContext(javaScriptConfiguration, @"const text = 'value \\\r\n|';", SCELanguageContextString);
    SCEExpectContext(javaScriptConfiguration, @"// comment |", SCELanguageContextComment);
    SCEExpectContext(javaScriptConfiguration, @"// comment\r\n|", SCELanguageContextCode);
    SCEExpectContext(javaScriptConfiguration, @"// comment\u2028|", SCELanguageContextCode);
    SCEExpectContext(javaScriptConfiguration, @"#!/usr/bin/env node |", SCELanguageContextComment);
    SCEExpectContext(javaScriptConfiguration, @"/* comment\n| */", SCELanguageContextComment);
    SCEExpectContext(javaScriptConfiguration, @"/* comment */ |", SCELanguageContextCode);
    SCEExpectContext(javaScriptConfiguration, @"const text = `literal |`;", SCELanguageContextString);
    SCEExpectContext(javaScriptConfiguration, @"const text = `literal ${|value}`;", SCELanguageContextCode);
    SCEExpectContext(javaScriptConfiguration, @"const text = `literal ${ {key: 1} } remaining |`;",
                     SCELanguageContextString);
    SCEExpectContext(javaScriptConfiguration, @"const text = `literal ${`nested ${value}`} remaining |`;",
                     SCELanguageContextString);
    SCEExpectContext(javaScriptConfiguration, @"const text = `literal ${`nested ${|value}`}`;", SCELanguageContextCode);
    SCEExpectContext(javaScriptConfiguration, @"const text = `escaped \\${|value}`;", SCELanguageContextString);
    SCEExpectContext(javaScriptConfiguration, @"const text = `escaped \\` |`;", SCELanguageContextString);
    SCEExpectContext(javaScriptConfiguration, @"const text = `literal ${value}`; |", SCELanguageContextCode);
    SCEExpectContext(javaScriptConfiguration, @"const pattern = /[{}|]/;", SCELanguageContextString);
    SCEExpectContext(javaScriptConfiguration, @"const pattern = /[//{}|]/;", SCELanguageContextString);
    SCEExpectContext(javaScriptConfiguration, @"return /[{}]|/;", SCELanguageContextString);
    SCEExpectContext(javaScriptConfiguration, @"const pattern = /[{}]/g; |", SCELanguageContextCode);
    SCEExpectContext(javaScriptConfiguration, @"const ratio = value / count; |", SCELanguageContextCode);
    SCEExpectContext(javaScriptConfiguration, @"value++ / count; |", SCELanguageContextCode);
    SCEExpectContext(javaScriptConfiguration, @"object.return / count; |", SCELanguageContextCode);
    SCEExpectContext(javaScriptConfiguration, @"if (ready) /[{}|]/;", SCELanguageContextString);
    SCEExpectContext(javaScriptConfiguration, @"while (next(item)) /[{}|]/;", SCELanguageContextString);
    SCEExpectContext(javaScriptConfiguration, @"if /* head */ (ready) /[{}|]/;", SCELanguageContextString);
    SCEExpectContext(javaScriptConfiguration, @"return (value + 1) / count; |", SCELanguageContextCode);
    SCEExpectContext(javaScriptConfiguration, @"call(value) / count; |", SCELanguageContextCode);
    SCEExpectContext(javaScriptConfiguration, @"if (ready) (value) / count; |", SCELanguageContextCode);
    SCEExpectContext(javaScriptConfiguration, @"object.if (value) / count; |", SCELanguageContextCode);
    SCEExpectContext(javaScriptConfiguration, @"value) / count; |", SCELanguageContextUnknown);
    SCEExpectContext(javaScriptConfiguration, @"}\n/[{}|]/;", SCELanguageContextUnknown);
    SCEExpectContext(javaScriptConfiguration, @"let value\n/[{}|]/;", SCELanguageContextUnknown);
    SCEExpectContext(javaScriptConfiguration, @"break\n/[{}|]/;", SCELanguageContextUnknown);
    SCEExpectContext(javaScriptConfiguration, @"const pattern = /[[abc]|]/v;", SCELanguageContextUnknown);
    SCEExpectContext(javaScriptConfiguration, @"const \\u0061 = 1; |", SCELanguageContextUnknown);
    SCEExpectContext(javaScriptConfiguration, @"await /[{}|]/;", SCELanguageContextUnknown);
    SCEExpectContext(javaScriptConfiguration, @"of / \" / [|text\";", SCELanguageContextUnknown);
    SCEExpectContext(javaScriptConfiguration, @"const values = [.../[{}|]/];", SCELanguageContextUnknown);

    NSString *prefix = [@"" stringByPaddingToLength:200000 withString:@" \n" startingAtIndex:0];
    SCEContextCountingBuffer *largeBuffer = [[SCEContextCountingBuffer alloc] initWithString:prefix];
    EDITING_CHECK([jsonConfiguration contextAtUTF16Offset:prefix.length
                                                 inBuffer:largeBuffer] == SCELanguageContextUnknown,
                  "a distant uncached context must defer rather than scan without a bound");
    EDITING_CHECK(largeBuffer.metrics.numberOfUTF16UnitsRead <= 131072 && largeBuffer.metrics.documentStringReads == 0,
                  "context lookup must bound rope reads without materializing the document");
    largeBuffer.metrics.numberOfUTF16UnitsRead = 0;
    EDITING_CHECK([jsonConfiguration contextAtUTF16Offset:prefix.length inBuffer:largeBuffer] == SCELanguageContextCode,
                  "subsequent lookup must resume the cached prefix");
    EDITING_CHECK(largeBuffer.metrics.numberOfUTF16UnitsRead <= 131072, "resumed lookup must also bound work");
    largeBuffer.metrics.numberOfUTF16UnitsRead = 0;
    EDITING_CHECK([jsonConfiguration contextAtUTF16Offset:prefix.length
                                                 inBuffer:largeBuffer] == SCELanguageContextCode &&
                      largeBuffer.metrics.numberOfUTF16UnitsRead == 0,
                  "a repeated lookup must reuse its checkpoint");

    SCETextBuffer *base = [[SCETextBuffer alloc] initWithString:@"xx"];
    SCETextBuffer *stringBranch = [base copy];
    SCETextBuffer *codeBranch = [base copy];
    [stringBranch replaceCharactersInUTF16Range:NSMakeRange(0, 1) withString:@"\""];
    [codeBranch replaceCharactersInUTF16Range:NSMakeRange(0, 1) withString:@" "];
    EDITING_CHECK(stringBranch.revision == codeBranch.revision &&
                      [stringBranch.documentIdentifier isEqual:codeBranch.documentIdentifier],
                  "fixture branches must share document identity and revision");
    EDITING_CHECK([jsonConfiguration contextAtUTF16Offset:2 inBuffer:stringBranch] == SCELanguageContextString &&
                      [jsonConfiguration contextAtUTF16Offset:2 inBuffer:codeBranch] == SCELanguageContextCode,
                  "context caches must distinguish independently edited snapshots");

    SCEEditorView *editor = [[SCEEditorView alloc] initWithFrame:NSMakeRect(0, 0, 600, 400)];
    editor.languageConfiguration = jsonConfiguration;
    editor.bracketCompletionMode = SCEBracketCompletionModeOnNewline;
    SCESetMarkedDocument(editor, @"\"{|");
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    [editor undo:nil];
    [editor insertText:@"" replacementRange:NSMakeRange(0, 1)];
    editor.selectedRange = NSMakeRange(1, 0);
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    SCEExpectMarkedDocument(editor, @"{\n    |\n}");
    NSString *checkpointPrefix = [@"" stringByPaddingToLength:5000 withString:@" \n" startingAtIndex:0];
    SCESetMarkedDocument(editor, [checkpointPrefix stringByAppendingString:@"{|"]);
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    [editor undo:nil];
    [editor insertText:@"\"" replacementRange:NSMakeRange(0, 0)];
    editor.selectedRange = NSMakeRange(editor.string.length, 0);
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    EDITING_CHECK(![editor.string containsString:@"}"], "an earlier edit must invalidate later lexical checkpoints");
    [editor undo:nil];
    [editor undo:nil];
    editor.selectedRange = NSMakeRange(editor.string.length, 0);
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    SCEExpectMarkedDocument(editor, [checkpointPrefix stringByAppendingString:@"{\n    |\n}"]);
    puts(
        "PASS language contexts: escapes, comments, templates, regex/division, bounded reads, snapshot identity, edits");
}

static void SCECheckNativeEditingCommands(void) {
    NSScrollView *scroll = [SCEEditorView scrollableEditorView];
    SCEEditorView *editor = (SCEEditorView *)scroll.documentView;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 600, 400)
                                                   styleMask:NSWindowStyleMaskTitled
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.releasedWhenClosed = NO;
    window.contentView = scroll;
    [window makeFirstResponder:editor];
    editor.languageConfiguration = SCELanguageConfiguration.languageConfigurationForJSON;
    editor.bracketCompletionMode = SCEBracketCompletionModeWhileTyping;
    SCETypeConfiguredText(editor, @"{");
    SCEExpectMarkedDocument(editor, @"{|}");
    SCETypeConfiguredText(editor, @"\r");
    SCEExpectMarkedDocument(editor, @"{\n    |\n}");
    SCETypeConfiguredText(editor, @"\t");
    SCEExpectMarkedDocument(editor, @"{\n        |\n}");
    [window close];
    puts("PASS native configured input: AppKit bracket typing, Return, and Tab command routing");
}

static void SCECheckCustomLanguageConfiguration(void) {
    SCEConfiguredContextProvider *provider = [[SCEConfiguredContextProvider alloc] init];
    provider.context = SCELanguageContextCode;
    SCEBracketPair *pair = [[SCEBracketPair alloc] initWithOpeningCharacter:'<'
                                                           closingCharacter:'>'
                                                           expandsOnNewline:YES];
    NSMutableArray<SCEBracketPair *> *pairs = [NSMutableArray arrayWithObject:pair];
    SCELanguageConfiguration *configuration = [[SCELanguageConfiguration alloc] initWithBracketPairs:pairs
                                                                                     contextProvider:provider];
    [pairs removeAllObjects];
    EDITING_CHECK(configuration.bracketPairs.count == 1 && [configuration copy] == configuration && [pair copy] == pair,
                  "configurations and bracket pairs must be immutable copies");
    SCEEditorView *editor = [[SCEEditorView alloc] initWithFrame:NSMakeRect(0, 0, 600, 400)];
    editor.languageConfiguration = configuration;
    editor.bracketCompletionMode = SCEBracketCompletionModeOnNewline;
    // The supplementary character occupies two UTF-16 units before the opener.
    SCESetMarkedDocument(editor, @"\U0001f642 <|");
    SCEPressEditingCommand(editor, @selector(insertNewline:));
    SCEExpectMarkedDocument(editor, @"\U0001f642 <\n    |\n>");
    EDITING_CHECK(provider.requestedOffset == 3, "custom providers must receive UTF-16 offsets");
    [provider.receivedSnapshot replaceCharactersInUTF16Range:NSMakeRange(0, 0) withString:@"independent"];
    SCEExpectMarkedDocument(editor, @"\U0001f642 <\n    |\n>");
    for (NSNumber *context in
         @[ @(SCELanguageContextUnknown), @(SCELanguageContextString), @(SCELanguageContextComment) ]) {
        provider.context = context.unsignedIntegerValue;
        SCESetMarkedDocument(editor, @"<|");
        SCEPressEditingCommand(editor, @selector(insertNewline:));
        SCEExpectMarkedDocument(editor, @"<\n|");
    }
    BOOL raised = NO;
    @try {
        (void)[[SCEBracketPair alloc] initWithOpeningCharacter:'<' closingCharacter:'<' expandsOnNewline:YES];
    } @catch (NSException *exception) {
        raised = [exception.name isEqual:NSInvalidArgumentException];
    }
    EDITING_CHECK(raised, "ambiguous same-character pairs must be rejected");
    raised = NO;
    @try {
        (void)[[SCELanguageConfiguration alloc] initWithBracketPairs:@[ pair, pair ] contextProvider:provider];
    } @catch (NSException *exception) {
        raised = [exception.name isEqual:NSInvalidArgumentException];
    }
    EDITING_CHECK(raised, "duplicate bracket characters must be rejected");

    SCESetMarkedDocument(editor, @"|");
    SCEPressEditingCommand(editor, @selector(insertTab:));
    editor.languageConfiguration = SCELanguageConfiguration.languageConfigurationForJSON;
    editor.indentationWidth = 2;
    editor.bracketCompletionMode = SCEBracketCompletionModeWhileTyping;
    SCEExpectMarkedDocument(editor, @"    |");
    [editor undo:nil];
    SCEExpectMarkedDocument(editor, @"|");
    puts(
        "PASS language configuration: custom pairs, UTF-16 snapshots, context exclusions, validation, undo preservation");
}

NSUInteger SCECheckConfiguredEditing(void) {
    SCECheckIndentationPreferences();
    SCECheckNewlineCompletion();
    SCECheckTypingCompletion();
    SCECheckLanguageContexts();
    SCECheckCustomLanguageConfiguration();
    SCECheckNativeEditingCommands();
    return SCEEditingCheckCount;
}
