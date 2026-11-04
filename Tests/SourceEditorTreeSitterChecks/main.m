#import <Foundation/Foundation.h>
@import SourceEditorTreeSitter;

void SECheckTreeSitter(void);

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSError *error = nil;
        SETreeSitterHighlighter *json = [[SETreeSitterHighlighter alloc] initWithLanguage:SETreeSitterLanguageJSON
                                                                                    error:&error];
        if (!json) {
            NSLog(@"%@", error);
            return 1;
        }
        SETreeSitterHighlighter *javascript =
            [[SETreeSitterHighlighter alloc] initWithLanguage:SETreeSitterLanguageJavaScript error:&error];
        if (!javascript) {
            NSLog(@"%@", error);
            return 1;
        }
        puts("Tree-sitter grammars and queries loaded.");
        SECheckTreeSitter();
    }
    return 0;
}
