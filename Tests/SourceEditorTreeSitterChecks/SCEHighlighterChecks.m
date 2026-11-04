#import <Foundation/Foundation.h>
@import SourceEditorTreeSitter;

static NSUInteger SCECheckCount;
#define CHECK(condition, message)                                                                                      \
    do {                                                                                                               \
        SCECheckCount++;                                                                                               \
        if (!(condition)) {                                                                                            \
            fprintf(stderr, "FAIL Tree-sitter at line %d: %s\n", __LINE__, message);                                   \
            exit(1);                                                                                                   \
        }                                                                                                              \
    } while (0)

static SCETreeSitterHighlighter *SCECreateHighlighter(SCETreeSitterLanguage language) {
    NSError *error = nil;
    SCETreeSitterHighlighter *highlighter = [[SCETreeSitterHighlighter alloc] initWithLanguage:language error:&error];
    if (!highlighter) {
        NSLog(@"%@", error);
    }
    CHECK(highlighter != nil, "grammar and highlight query must load");
    return highlighter;
}

static SCESyntaxHighlightResult *SCEHighlight(SCETreeSitterHighlighter *highlighter, SCETextBuffer *buffer,
                                              NSRange range, SCETextEdit *edit) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block SCESyntaxHighlightResult *result;
    __block BOOL offMain;
    [highlighter highlightBuffer:buffer
                      UTF16Range:range
                       afterEdit:edit
                      completion:^(SCESyntaxHighlightResult *value) {
                          result = value;
                          offMain = !NSThread.isMainThread;
                          dispatch_semaphore_signal(done);
                      }];
    CHECK(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)) == 0,
          "highlight request must complete");
    CHECK(result != nil && result.revision == buffer.revision && NSEqualRanges(result.coveredRange, range),
          "highlight result metadata differs");
    CHECK(offMain, "parsing and query evaluation must stay off the main thread");
    return result;
}

static SCESyntaxTokenKind SCEKindAt(SCESyntaxHighlightResult *result, NSUInteger offset) {
    SCESyntaxTokenKind kind = nil;
    for (SCESyntaxToken *token in result.tokens) {
        if (NSLocationInRange(offset, token.range)) {
            kind = token.kind;
        }
    }
    return kind;
}

static void SCECheckKind(SCESyntaxHighlightResult *result, NSString *text, NSString *substring, NSUInteger relative,
                         SCESyntaxTokenKind expected) {
    NSRange range = [text rangeOfString:substring];
    CHECK(range.location != NSNotFound, "test substring must exist");
    if (![SCEKindAt(result, range.location + relative) isEqualToString:expected]) {
        NSLog(@"Expected %@ for %@, got %@", expected, substring, SCEKindAt(result, range.location + relative));
        CHECK(NO, "semantic token differs");
    }
    SCECheckCount++;
}

static void SCECheckLanguages(void) {
    // Escaped CJK characters and emoji verify token ranges across UTF-16 sequences.
    NSString *json = @"{\"\u952e\U0001f642\": \"line\\nbreak\", \"n\": -12.5e2, \"ok\": true, \"empty\": null}";
    SCETextBuffer *buffer = [[SCETextBuffer alloc] initWithString:json];
    SCESyntaxHighlightResult *result =
        SCEHighlight(SCECreateHighlighter(SCETreeSitterLanguageJSON), buffer, NSMakeRange(0, buffer.lengthUTF16), nil);
    SCECheckKind(result, json, @"\u952e\U0001f642", 0, SCESyntaxTokenProperty);
    SCECheckKind(result, json, @"line", 0, SCESyntaxTokenString);
    SCECheckKind(result, json, @"\\n", 0, SCESyntaxTokenEscape);
    SCECheckKind(result, json, @"-12.5e2", 0, SCESyntaxTokenNumber);
    SCECheckKind(result, json, @"true", 0, SCESyntaxTokenKeyword);
    SCECheckKind(result, json, @"null", 0, SCESyntaxTokenKeyword);
    SCECheckKind(result, json, @"{", 0, SCESyntaxTokenPunctuation);

    NSString *javascript =
        @"const lineCount = 42;\nasync function formatLine(title) {\n// \u4e2d\u6587\U0001f642\nreturn `Line ${title.toUpperCase()} ${42 + 1}!`;\n}\n"
         "class Document {}\nconst isEditable = () => true;\nconst pattern = /x+/gi;\nconst nested = `outer ${`inner ${lineCount}`}`;";
    buffer = [[SCETextBuffer alloc] initWithString:javascript];
    result = SCEHighlight(SCECreateHighlighter(SCETreeSitterLanguageJavaScript), buffer,
                          NSMakeRange(0, buffer.lengthUTF16), nil);
    SCECheckKind(result, javascript, @"const", 0, SCESyntaxTokenKeyword);
    SCECheckKind(result, javascript, @"formatLine", 0, SCESyntaxTokenFunction);
    SCECheckKind(result, javascript, @"// \u4e2d\u6587\U0001f642", 0, SCESyntaxTokenComment);
    SCECheckKind(result, javascript, @"Line ${", 0, SCESyntaxTokenString);
    SCECheckKind(result, javascript, @"${title", 0, SCESyntaxTokenPunctuation);
    SCECheckKind(result, javascript, @"${title", 2, SCESyntaxTokenVariable);
    SCECheckKind(result, javascript, @"toUpperCase", 0, SCESyntaxTokenFunction);
    SCECheckKind(result, javascript, @"42", 0, SCESyntaxTokenNumber);
    SCECheckKind(result, javascript, @"Document", 0, SCESyntaxTokenType);
    SCECheckKind(result, javascript, @"isEditable =", 0, SCESyntaxTokenFunction);
    SCECheckKind(result, javascript, @"/x+/gi", 1, SCESyntaxTokenString);
    SCECheckKind(result, javascript, @"inner", 0, SCESyntaxTokenString);
    SCECheckKind(result, javascript, @"${lineCount", 2, SCESyntaxTokenVariable);

    NSString *opening = @"const text = \"";
    NSMutableString *boundary = [opening mutableCopy];
    [boundary appendString:[@" " stringByPaddingToLength:4095 - opening.length withString:@" " startingAtIndex:0]];
    [boundary appendString:@"\U0001f642\";\r\nconst after = 123;"];
    buffer = [[SCETextBuffer alloc] initWithString:boundary];
    result = SCEHighlight(SCECreateHighlighter(SCETreeSitterLanguageJavaScript), buffer,
                          NSMakeRange(0, buffer.lengthUTF16), nil);
    SCECheckKind(result, boundary, @"\U0001f642", 0, SCESyntaxTokenString);
    SCECheckKind(result, boundary, @"after", 0, SCESyntaxTokenVariable);
    SCECheckKind(result, boundary, @"123", 0, SCESyntaxTokenNumber);
    NSError *error = nil;
    CHECK([[SCETreeSitterHighlighter alloc] initWithLanguage:(SCETreeSitterLanguage)NSUIntegerMax
                                                       error:&error] == nil &&
              error != nil,
          "unsupported languages must return an error instead of crashing");
    puts(
        "PASS languages: JSON keys/escapes/numbers, JavaScript functions/classes/regex/templates, Unicode chunk boundaries");
}

static uint64_t SCERandomState = 0x329a871;

static NSUInteger SCERandom(NSUInteger count) {
    SCERandomState ^= SCERandomState << 13;
    SCERandomState ^= SCERandomState >> 7;
    SCERandomState ^= SCERandomState << 17;
    return count ? SCERandomState % count : 0;
}

static void SCECheckIncremental(SCETreeSitterLanguage language, NSString *initial) {
    SCETreeSitterHighlighter *highlighter = SCECreateHighlighter(language);
    SCETreeSitterHighlighter *reference = SCECreateHighlighter(language);
    SCETextBuffer *buffer = [[SCETextBuffer alloc] initWithString:initial];
    SCEHighlight(highlighter, buffer, NSMakeRange(0, buffer.lengthUTF16), nil);
    NSArray<NSString *> *insertions =
        @[ @"x", @"\n", @"\r\n", @"/*ok*/", @"\"\u4e2d\u6587\U0001f642\"", @" ", @"42", @"", @"`x${1}`" ];
    for (NSUInteger i = 0; i < 120; i++) {
        @autoreleasepool {
            NSString *text = buffer.string;
            NSUInteger start = SCERandom(text.length + 1);
            if (start < text.length) {
                start = [text rangeOfComposedCharacterSequenceAtIndex:start].location;
            }
            NSUInteger end = MIN(text.length, start + SCERandom(5));
            if (end < text.length) {
                end = [text rangeOfComposedCharacterSequenceAtIndex:end].location;
            }
            NSString *insertion = insertions[SCERandom(insertions.count)];
            SCETextBuffer *before = [buffer copy];
            NSRange range = NSMakeRange(start, end - start);
            [buffer replaceCharactersInUTF16Range:range withString:insertion];
            SCETextEdit *edit = [[SCETextEdit alloc] initWithRange:range
                                               insertedLengthUTF16:insertion.length
                                                      beforeBuffer:before
                                                       afterBuffer:buffer];
            SCESyntaxHighlightResult *incremental =
                SCEHighlight(highlighter, buffer, NSMakeRange(0, buffer.lengthUTF16), edit);
            [reference cancelPendingRequests];
            SCESyntaxHighlightResult *fresh = SCEHighlight(reference, buffer, NSMakeRange(0, buffer.lengthUTF16), nil);
            CHECK([incremental.tokens isEqualToArray:fresh.tokens],
                  "incremental captures must equal a fresh parse after each Unicode/multiline edit");
        }
    }
    CHECK([[highlighter valueForKey:@"incrementalParseCount"] unsignedIntegerValue] > 80,
          "local edits must reuse the previous syntax tree");
    printf("PASS incremental %s: 120 edits match a fresh parse, including malformed intermediate syntax\n",
           language == SCETreeSitterLanguageJSON ? "JSON" : "JavaScript");
}

static void SCECheckViewportAndIdentity(void) {
    NSMutableString *text = [NSMutableString string];
    for (NSUInteger i = 0; i < 20000; i++) {
        [text appendFormat:@"const value%lu = %lu;\n", (unsigned long)i, (unsigned long)i];
    }
    SCETextBuffer *buffer = [[SCETextBuffer alloc] initWithString:text];
    SCETreeSitterHighlighter *highlighter = SCECreateHighlighter(SCETreeSitterLanguageJavaScript);
    NSRange first = [buffer UTF16RangeOfLine:10000 includingLineEnding:YES];
    SCESyntaxHighlightResult *result = SCEHighlight(highlighter, buffer, first, nil);
    CHECK(result.tokens.count > 0 && result.tokens.count < 20,
          "query results must stay bounded by the viewport instead of the whole document");
    NSUInteger parses = [[highlighter valueForKey:@"parseCount"] unsignedIntegerValue];
    NSRange second = [buffer UTF16RangeOfLine:15000 includingLineEnding:YES];
    SCEHighlight(highlighter, buffer, second, nil);
    CHECK([[highlighter valueForKey:@"parseCount"] unsignedIntegerValue] == parses,
          "scrolling must query the existing tree without parsing again");
    SCETextBuffer *other = [[SCETextBuffer alloc] initWithString:@"// independent document"];
    result = SCEHighlight(highlighter, other, NSMakeRange(0, other.lengthUTF16), nil);
    CHECK([SCEKindAt(result, 0) isEqualToString:SCESyntaxTokenComment],
          "equal revisions from a different document must not reuse the old tree");
    buffer = [[SCETextBuffer alloc] initWithString:@"/* first\n\u4e2d\u6587\U0001f642 middle\nlast */\nconst n = 1;"];
    NSRange middle = [buffer UTF16RangeOfLine:1 includingLineEnding:YES];
    result = SCEHighlight(highlighter, buffer, middle, nil);
    CHECK([SCEKindAt(result, middle.location) isEqualToString:SCESyntaxTokenComment],
          "viewport captures must include multiline scopes starting above the viewport");
    CHECK(result.tokens.firstObject.range.location < middle.location,
          "multiline captures must retain their full document range");
    puts("PASS viewport: 20k-line bounded queries, scrolling without reparsing, document identity, multiline scopes");
}

static void SCECheckCoalescingAndCancellation(void) {
    SCETreeSitterHighlighter *highlighter = SCECreateHighlighter(SCETreeSitterLanguageJavaScript);
    dispatch_queue_t queue = [highlighter valueForKey:@"queue"];
    dispatch_semaphore_t parsingSemaphore = dispatch_semaphore_create(0);
    dispatch_async(queue, ^{
        dispatch_semaphore_wait(parsingSemaphore, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
    });
    SCETextBuffer *buffer = [[SCETextBuffer alloc] initWithString:@"const value = 0;"];
    __block BOOL obsoleteCalled = NO;
    for (NSUInteger i = 0; i < 100; i++) {
        SCETextBuffer *before = [buffer copy];
        [buffer replaceCharactersInUTF16Range:NSMakeRange(buffer.lengthUTF16, 0) withString:@" "];
        SCETextEdit *edit = [[SCETextEdit alloc] initWithRange:NSMakeRange(before.lengthUTF16, 0)
                                           insertedLengthUTF16:1
                                                  beforeBuffer:before
                                                   afterBuffer:buffer];
        [highlighter highlightBuffer:buffer
                          UTF16Range:NSMakeRange(0, buffer.lengthUTF16)
                           afterEdit:edit
                          completion:^(SCESyntaxHighlightResult *value) {
                              obsoleteCalled = YES;
                          }];
    }
    // Queue the final request before releasing the parsing semaphore.
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block SCESyntaxHighlightResult *result;
    [highlighter highlightBuffer:buffer
                      UTF16Range:NSMakeRange(0, buffer.lengthUTF16)
                       afterEdit:nil
                      completion:^(SCESyntaxHighlightResult *value) {
                          result = value;
                          dispatch_semaphore_signal(done);
                      }];
    dispatch_semaphore_signal(parsingSemaphore);
    CHECK(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)) == 0,
          "coalesced request must complete");
    CHECK(result.revision == buffer.revision && [[highlighter valueForKey:@"parseCount"] unsignedIntegerValue] == 1,
          "queued edits must coalesce into one parse of the latest snapshot");
    CHECK(!obsoleteCalled, "superseded pending completions must be dropped");

    parsingSemaphore = dispatch_semaphore_create(0);
    dispatch_async(queue, ^{
        dispatch_semaphore_wait(parsingSemaphore, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
    });
    [highlighter highlightBuffer:buffer
                      UTF16Range:NSMakeRange(0, buffer.lengthUTF16)
                       afterEdit:nil
                      completion:^(SCESyntaxHighlightResult *value) {
                          obsoleteCalled = YES;
                      }];
    [highlighter cancelPendingRequests];
    SCETextBuffer *fresh = [[SCETextBuffer alloc] initWithString:@"const fresh = 7;"];
    dispatch_semaphore_signal(parsingSemaphore);
    result = SCEHighlight(highlighter, fresh, NSMakeRange(0, fresh.lengthUTF16), nil);
    CHECK(!obsoleteCalled && [SCEKindAt(result, 0) isEqualToString:SCESyntaxTokenKeyword],
          "cancellation must discard pending work and allow reuse for a new document");
    puts("PASS scheduling: request coalescing, pending cancellation, highlighter reuse");
}

void SCECheckTreeSitter(void) {
    SCECheckLanguages();
    SCECheckIncremental(SCETreeSitterLanguageJSON, @"{\r\n\"name\": \"\u4e2d\u6587\U0001f642\",\r\n\"n\": 1\r\n}");
    SCECheckIncremental(
        SCETreeSitterLanguageJavaScript,
        @"const title = '\u4e2d\u6587\U0001f642';\nfunction formatLine(text) { return `line ${text}`; }\n");
    SCECheckViewportAndIdentity();
    SCECheckCoalescingAndCancellation();
    printf("All %lu Tree-sitter checks passed.\n", (unsigned long)SCECheckCount);
}
