#import <Foundation/Foundation.h>
@import SourceEditorTreeSitter;

static NSUInteger SECheckCount;
#define CHECK(condition, message)                                                                                      \
    do {                                                                                                               \
        SECheckCount++;                                                                                                \
        if (!(condition)) {                                                                                            \
            fprintf(stderr, "FAIL Tree-sitter at line %d: %s\n", __LINE__, message);                                   \
            exit(1);                                                                                                   \
        }                                                                                                              \
    } while (0)

static SETreeSitterHighlighter *SEProvider(SETreeSitterLanguage language) {
    NSError *error = nil;
    SETreeSitterHighlighter *provider = [[SETreeSitterHighlighter alloc] initWithLanguage:language error:&error];
    if (!provider)
        NSLog(@"%@", error);
    CHECK(provider != nil, "grammar and highlight query must load");
    return provider;
}

static SESyntaxHighlightResult *SEHighlight(
    SETreeSitterHighlighter *provider, SETextBuffer *buffer, NSRange range, SETextEdit *edit) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block SESyntaxHighlightResult *result;
    __block BOOL offMain;
    [provider highlightBuffer:buffer
                   UTF16Range:range
                    afterEdit:edit
                   completion:^(SESyntaxHighlightResult *value) {
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

static SESyntaxTokenKind SEKindAt(SESyntaxHighlightResult *result, NSUInteger offset) {
    SESyntaxTokenKind kind = nil;
    for (SESyntaxToken *token in result.tokens) {
        if (NSLocationInRange(offset, token.range))
            kind = token.kind;
    }
    return kind;
}

static void SECheckKind(SESyntaxHighlightResult *result, NSString *text, NSString *substring, NSUInteger relative,
    SESyntaxTokenKind expected) {
    NSRange range = [text rangeOfString:substring];
    CHECK(range.location != NSNotFound, "test substring must exist");
    if (![SEKindAt(result, range.location + relative) isEqualToString:expected]) {
        NSLog(@"Expected %@ for %@, got %@", expected, substring, SEKindAt(result, range.location + relative));
        CHECK(NO, "semantic token differs");
    }
    SECheckCount++;
}

static void SECheckLanguages(void) {
    NSString *json = @"{\"键🙂\": \"hello\\nworld\", \"n\": -12.5e2, \"ok\": true, \"empty\": null}";
    SETextBuffer *buffer = [[SETextBuffer alloc] initWithString:json];
    SESyntaxHighlightResult *result
        = SEHighlight(SEProvider(SETreeSitterLanguageJSON), buffer, NSMakeRange(0, buffer.lengthUTF16), nil);
    SECheckKind(result, json, @"键🙂", 0, SESyntaxTokenProperty);
    SECheckKind(result, json, @"hello", 0, SESyntaxTokenString);
    SECheckKind(result, json, @"\\n", 0, SESyntaxTokenEscape);
    SECheckKind(result, json, @"-12.5e2", 0, SESyntaxTokenNumber);
    SECheckKind(result, json, @"true", 0, SESyntaxTokenKeyword);
    SECheckKind(result, json, @"null", 0, SESyntaxTokenKeyword);
    SECheckKind(result, json, @"{", 0, SESyntaxTokenPunctuation);

    NSString *javascript
        = @"const answer = 42;\nasync function greet(name) {\n// 中文🙂\nreturn `Hello ${name.toUpperCase()} ${42 + 1}!`;\n}\n"
           "class Greeter {}\nconst f = () => true;\nconst pattern = /x+/gi;\nconst nested = `outer ${`inner ${answer}`}`;";
    buffer = [[SETextBuffer alloc] initWithString:javascript];
    result = SEHighlight(SEProvider(SETreeSitterLanguageJavaScript), buffer, NSMakeRange(0, buffer.lengthUTF16), nil);
    SECheckKind(result, javascript, @"const", 0, SESyntaxTokenKeyword);
    SECheckKind(result, javascript, @"greet", 0, SESyntaxTokenFunction);
    SECheckKind(result, javascript, @"// 中文🙂", 0, SESyntaxTokenComment);
    SECheckKind(result, javascript, @"Hello", 0, SESyntaxTokenString);
    SECheckKind(result, javascript, @"${name", 0, SESyntaxTokenPunctuation);
    SECheckKind(result, javascript, @"${name", 2, SESyntaxTokenVariable);
    SECheckKind(result, javascript, @"toUpperCase", 0, SESyntaxTokenFunction);
    SECheckKind(result, javascript, @"42", 0, SESyntaxTokenNumber);
    SECheckKind(result, javascript, @"Greeter", 0, SESyntaxTokenType);
    SECheckKind(result, javascript, @"f =", 0, SESyntaxTokenFunction);
    SECheckKind(result, javascript, @"/x+/gi", 1, SESyntaxTokenString);
    SECheckKind(result, javascript, @"inner", 0, SESyntaxTokenString);
    SECheckKind(result, javascript, @"${answer", 2, SESyntaxTokenVariable);

    NSString *opening = @"const text = \"";
    NSMutableString *boundary = [opening mutableCopy];
    [boundary appendString:[@" " stringByPaddingToLength:4095 - opening.length withString:@" " startingAtIndex:0]];
    [boundary appendString:@"🙂\";\r\nconst after = 123;"];
    buffer = [[SETextBuffer alloc] initWithString:boundary];
    result = SEHighlight(SEProvider(SETreeSitterLanguageJavaScript), buffer, NSMakeRange(0, buffer.lengthUTF16), nil);
    SECheckKind(result, boundary, @"🙂", 0, SESyntaxTokenString);
    SECheckKind(result, boundary, @"after", 0, SESyntaxTokenVariable);
    SECheckKind(result, boundary, @"123", 0, SESyntaxTokenNumber);
    NSError *error = nil;
    CHECK([[SETreeSitterHighlighter alloc] initWithLanguage:(SETreeSitterLanguage)NSUIntegerMax error:&error] == nil
            && error != nil,
        "unsupported languages must return an error instead of crashing");
    puts(
        "PASS languages: JSON keys/escapes/numbers, JavaScript functions/classes/regex/templates, Unicode chunk boundaries");
}

static uint64_t SERandomState = 0x329a871;

static NSUInteger SERandom(NSUInteger count) {
    SERandomState ^= SERandomState << 13;
    SERandomState ^= SERandomState >> 7;
    SERandomState ^= SERandomState << 17;
    return count ? SERandomState % count : 0;
}

static void SECheckIncremental(SETreeSitterLanguage language, NSString *initial) {
    SETreeSitterHighlighter *provider = SEProvider(language);
    SETreeSitterHighlighter *reference = SEProvider(language);
    SETextBuffer *buffer = [[SETextBuffer alloc] initWithString:initial];
    SEHighlight(provider, buffer, NSMakeRange(0, buffer.lengthUTF16), nil);
    NSArray<NSString *> *insertions = @[ @"x", @"\n", @"\r\n", @"/*ok*/", @"\"中文🙂\"", @" ", @"42", @"", @"`x${1}`" ];
    for (NSUInteger i = 0; i < 120; i++) {
        @autoreleasepool {
            NSString *text = buffer.string;
            NSUInteger start = SERandom(text.length + 1);
            if (start < text.length)
                start = [text rangeOfComposedCharacterSequenceAtIndex:start].location;
            NSUInteger end = MIN(text.length, start + SERandom(5));
            if (end < text.length)
                end = [text rangeOfComposedCharacterSequenceAtIndex:end].location;
            NSString *insertion = insertions[SERandom(insertions.count)];
            SETextBuffer *before = [buffer copy];
            NSRange range = NSMakeRange(start, end - start);
            [buffer replaceCharactersInUTF16Range:range withString:insertion];
            SETextEdit *edit = [[SETextEdit alloc] initWithRange:range
                                             insertedLengthUTF16:insertion.length
                                                          before:before
                                                           after:buffer];
            SESyntaxHighlightResult *incremental
                = SEHighlight(provider, buffer, NSMakeRange(0, buffer.lengthUTF16), edit);
            [reference cancelPendingRequests];
            SESyntaxHighlightResult *fresh = SEHighlight(reference, buffer, NSMakeRange(0, buffer.lengthUTF16), nil);
            CHECK([incremental.tokens isEqualToArray:fresh.tokens],
                "incremental captures must equal a fresh parse after each Unicode/multiline edit");
        }
    }
    CHECK([[provider valueForKey:@"incrementalParseCount"] unsignedIntegerValue] > 80,
        "local edits must reuse the previous syntax tree");
    printf("PASS incremental %s: 120 edits match a fresh parse, including malformed intermediate syntax\n",
        language == SETreeSitterLanguageJSON ? "JSON" : "JavaScript");
}

static void SECheckViewportAndIdentity(void) {
    NSMutableString *text = [NSMutableString string];
    for (NSUInteger i = 0; i < 20000; i++)
        [text appendFormat:@"const value%lu = %lu;\n", (unsigned long)i, (unsigned long)i];
    SETextBuffer *buffer = [[SETextBuffer alloc] initWithString:text];
    SETreeSitterHighlighter *provider = SEProvider(SETreeSitterLanguageJavaScript);
    NSRange first = [buffer UTF16RangeOfLine:10000 includingLineEnding:YES];
    SESyntaxHighlightResult *result = SEHighlight(provider, buffer, first, nil);
    CHECK(result.tokens.count > 0 && result.tokens.count < 20,
        "query results must stay bounded by the viewport instead of the whole document");
    NSUInteger parses = [[provider valueForKey:@"parseCount"] unsignedIntegerValue];
    NSRange second = [buffer UTF16RangeOfLine:15000 includingLineEnding:YES];
    SEHighlight(provider, buffer, second, nil);
    CHECK([[provider valueForKey:@"parseCount"] unsignedIntegerValue] == parses,
        "scrolling must query the existing tree without parsing again");
    SETextBuffer *other = [[SETextBuffer alloc] initWithString:@"// independent document"];
    result = SEHighlight(provider, other, NSMakeRange(0, other.lengthUTF16), nil);
    CHECK([SEKindAt(result, 0) isEqualToString:SESyntaxTokenComment],
        "equal revisions from a different document must not reuse the old tree");
    buffer = [[SETextBuffer alloc] initWithString:@"/* first\n中文🙂 middle\nlast */\nconst n = 1;"];
    NSRange middle = [buffer UTF16RangeOfLine:1 includingLineEnding:YES];
    result = SEHighlight(provider, buffer, middle, nil);
    CHECK([SEKindAt(result, middle.location) isEqualToString:SESyntaxTokenComment],
        "viewport captures must include multiline scopes starting above the viewport");
    CHECK(result.tokens.firstObject.range.location < middle.location,
        "multiline captures must retain their full document range");
    puts("PASS viewport: 20k-line bounded queries, scrolling without reparsing, document identity, multiline scopes");
}

static void SECheckCoalescingAndCancellation(void) {
    SETreeSitterHighlighter *provider = SEProvider(SETreeSitterLanguageJavaScript);
    dispatch_queue_t queue = [provider valueForKey:@"queue"];
    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    dispatch_async(queue, ^{
        dispatch_semaphore_wait(gate, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
    });
    SETextBuffer *buffer = [[SETextBuffer alloc] initWithString:@"const value = 0;"];
    __block BOOL obsoleteCalled = NO;
    for (NSUInteger i = 0; i < 100; i++) {
        SETextBuffer *before = [buffer copy];
        [buffer replaceCharactersInUTF16Range:NSMakeRange(buffer.lengthUTF16, 0) withString:@" "];
        SETextEdit *edit = [[SETextEdit alloc] initWithRange:NSMakeRange(before.lengthUTF16, 0)
                                         insertedLengthUTF16:1
                                                      before:before
                                                       after:buffer];
        [provider highlightBuffer:buffer
                       UTF16Range:NSMakeRange(0, buffer.lengthUTF16)
                        afterEdit:edit
                       completion:^(SESyntaxHighlightResult *value) {
                           obsoleteCalled = YES;
                       }];
    }
    // Queue the final request before releasing the worker gate.
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block SESyntaxHighlightResult *result;
    [provider highlightBuffer:buffer
                   UTF16Range:NSMakeRange(0, buffer.lengthUTF16)
                    afterEdit:nil
                   completion:^(SESyntaxHighlightResult *value) {
                       result = value;
                       dispatch_semaphore_signal(done);
                   }];
    dispatch_semaphore_signal(gate);
    CHECK(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)) == 0,
        "coalesced request must complete");
    CHECK(result.revision == buffer.revision && [[provider valueForKey:@"parseCount"] unsignedIntegerValue] == 1,
        "queued edits must coalesce into one parse of the latest snapshot");
    CHECK(!obsoleteCalled, "superseded pending completions must be dropped");

    gate = dispatch_semaphore_create(0);
    dispatch_async(queue, ^{
        dispatch_semaphore_wait(gate, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
    });
    [provider highlightBuffer:buffer
                   UTF16Range:NSMakeRange(0, buffer.lengthUTF16)
                    afterEdit:nil
                   completion:^(SESyntaxHighlightResult *value) {
                       obsoleteCalled = YES;
                   }];
    [provider cancelPendingRequests];
    SETextBuffer *fresh = [[SETextBuffer alloc] initWithString:@"const fresh = 7;"];
    dispatch_semaphore_signal(gate);
    result = SEHighlight(provider, fresh, NSMakeRange(0, fresh.lengthUTF16), nil);
    CHECK(!obsoleteCalled && [SEKindAt(result, 0) isEqualToString:SESyntaxTokenKeyword],
        "cancellation must discard pending work and allow reuse for a new document");
    puts("PASS scheduling: request coalescing, pending cancellation, provider reuse");
}

void SECheckTreeSitter(void) {
    SECheckLanguages();
    SECheckIncremental(SETreeSitterLanguageJSON, @"{\r\n\"name\": \"中文🙂\",\r\n\"n\": 1\r\n}");
    SECheckIncremental(
        SETreeSitterLanguageJavaScript, @"const name = '中文🙂';\nfunction greet(x) { return `hello ${x}`; }\n");
    SECheckViewportAndIdentity();
    SECheckCoalescingAndCancellation();
    printf("All %lu Tree-sitter checks passed.\n", (unsigned long)SECheckCount);
}
