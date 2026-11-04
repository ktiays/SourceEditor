#import <Foundation/Foundation.h>
@import SourceEditorTreeSitter;

void SCECheckTreeSitter(void);

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSError *error = nil;
        SCETreeSitterHighlighter *json = [[SCETreeSitterHighlighter alloc] initWithLanguage:SCETreeSitterLanguageJSON
                                                                                      error:&error];
        if (!json) {
            NSLog(@"%@", error);
            return 1;
        }
        SCETreeSitterHighlighter *javascript =
            [[SCETreeSitterHighlighter alloc] initWithLanguage:SCETreeSitterLanguageJavaScript error:&error];
        if (!javascript) {
            NSLog(@"%@", error);
            return 1;
        }
        puts("Tree-sitter grammars and queries loaded.");
        SCECheckTreeSitter();
    }
    return 0;
}
