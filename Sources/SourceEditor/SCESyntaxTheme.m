#import "include/SCESyntaxTheme.h"

SCEEditorColorKey const SCEEditorColorBackground = @"background";
SCEEditorColorKey const SCEEditorColorText = @"text";
SCEEditorColorKey const SCEEditorColorGutterBackground = @"gutterBackground";
SCEEditorColorKey const SCEEditorColorLineNumber = @"lineNumber";
SCEEditorColorKey const SCEEditorColorCurrentLine = @"currentLine";
SCEEditorColorKey const SCEEditorColorSelection = @"selection";
SCEEditorColorKey const SCEEditorColorInactiveSelection = @"inactiveSelection";
SCEEditorColorKey const SCEEditorColorCaret = @"caret";
SCEEditorColorKey const SCEEditorColorScopeGuide = @"scopeGuide";
SCEEditorColorKey const SCEEditorColorSearchMatch = @"searchMatch";
SCEEditorColorKey const SCEEditorColorCurrentSearchMatch = @"currentSearchMatch";
SCEEditorColorKey const SCEEditorColorCurrentSearchMatchBorder = @"currentSearchMatchBorder";

@implementation SCESyntaxTheme

+ (instancetype)defaultTheme {
    static SCESyntaxTheme *theme;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        theme = [[self alloc] initWithForegroundColors:@{
            SCESyntaxTokenComment : NSColor.secondaryLabelColor,
            SCESyntaxTokenString : NSColor.systemRedColor,
            SCESyntaxTokenEscape : NSColor.systemOrangeColor,
            SCESyntaxTokenNumber : NSColor.systemBlueColor,
            SCESyntaxTokenKeyword : NSColor.systemPurpleColor,
            SCESyntaxTokenFunction : NSColor.systemBrownColor,
            SCESyntaxTokenType : NSColor.systemIndigoColor,
            SCESyntaxTokenProperty : NSColor.systemTealColor,
            SCESyntaxTokenVariable : NSColor.textColor,
            SCESyntaxTokenOperator : NSColor.textColor,
            SCESyntaxTokenPunctuation : NSColor.secondaryLabelColor,
        }];
    });
    return theme;
}

- (instancetype)initWithForegroundColors:(NSDictionary<SCESyntaxTokenKind, NSColor *> *)colors {
    return [self initWithForegroundColors:colors editorColors:@{}];
}

- (instancetype)initWithForegroundColors:(NSDictionary<SCESyntaxTokenKind, NSColor *> *)colors
                            editorColors:(NSDictionary<SCEEditorColorKey, NSColor *> *)editorColors {
    if ((self = [super init])) {
        _foregroundColors = [colors copy];
        _editorColors = [editorColors copy];
    }
    return self;
}

- (NSColor *)editorColorForKey:(SCEEditorColorKey)key {
    return _editorColors[key];
}

- (NSColor *)foregroundColorForKind:(SCESyntaxTokenKind)kind {
    NSColor *color = _foregroundColors[kind];
    while (!color) {
        NSRange separator = [kind rangeOfString:@"." options:NSBackwardsSearch];
        if (separator.location == NSNotFound) {
            break;
        }
        kind = [kind substringToIndex:separator.location];
        color = _foregroundColors[kind];
    }
    return color;
}

- (id)copyWithZone:(NSZone *)zone {
    return self;
}

@end
