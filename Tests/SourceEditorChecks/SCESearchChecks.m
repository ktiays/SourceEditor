@import SourceEditor;
#import <time.h>
#import "SCESearchChecks.h"
#import "../../Sources/SourceEditor/SCETextSearchMatching.h"
#import "../../Sources/SourceEditor/SCEEditorViewInternal.h"

static NSUInteger SCESearchCheckCount;
#define SEARCH_CHECK(condition, message)                                                                               \
    do {                                                                                                               \
        SCESearchCheckCount++;                                                                                         \
        if (!(condition)) {                                                                                            \
            fprintf(stderr, "FAIL search at line %d: %s\n", __LINE__, (message));                                      \
            exit(1);                                                                                                   \
        }                                                                                                              \
    } while (0)

static uint64_t SCESearchRandomState = 0x9e3779b9;

static NSUInteger SCESearchRandom(NSUInteger upper) {
    SCESearchRandomState ^= SCESearchRandomState << 13;
    SCESearchRandomState ^= SCESearchRandomState >> 7;
    SCESearchRandomState ^= SCESearchRandomState << 17;
    return upper ? (NSUInteger)(SCESearchRandomState % upper) : 0;
}

static double SCESearchMilliseconds(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6;
}

static SCETextSearchQuery *SCEQuery(NSString *pattern, SCETextSearchOptions options) {
    return [[SCETextSearchQuery alloc] initWithPattern:pattern options:options];
}

// The matches of a whole-document search of the editor's current text.
static NSArray<NSValue *> *SCEReferenceMatches(SCEEditorView *editor) {
    return [editor.searchQuery rangesOfMatchesInBuffer:editor.bufferSnapshot
                                          maximumCount:SCETextSearchDefaultMaximumMatchCount
                                                 error:NULL];
}

static BOOL SCEWaitUntilSearchCompletes(SCEEditorView *editor) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30];
    while (editor.isSearchPending && deadline.timeIntervalSinceNow > 0) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.005, true);
    }
    // Let a coalesced notification for the final results run.
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
    return !editor.isSearchPending;
}

static NSUInteger SCEIndexOfReferenceMatchAtOrAfter(NSArray<NSValue *> *matches, NSUInteger offset) {
    for (NSUInteger index = 0; index < matches.count; index++) {
        if (matches[index].rangeValue.location >= offset) {
            return index;
        }
    }
    return NSNotFound;
}

static NSUInteger SCEIndexOfReferenceMatchEndingAtOrBefore(NSArray<NSValue *> *matches, NSUInteger offset) {
    for (NSUInteger index = matches.count; index > 0; index--) {
        if (NSMaxRange(matches[index - 1].rangeValue) <= offset) {
            return index - 1;
        }
    }
    return NSNotFound;
}

static NSString *SCESearchDocument(NSUInteger lineCount) {
    NSMutableString *text = [NSMutableString stringWithCapacity:lineCount * 32];
    for (NSUInteger line = 0; line < lineCount; line++) {
        if (line % 97 == 3) {
            [text appendFormat:@"%lu needle and Needle_x\n", (unsigned long)line];
        } else if (line % 251 == 7) {
            // CRLF line endings and a match that ends at the line ending.
            [text appendFormat:@"%lu crlf needle\r\n", (unsigned long)line];
        } else {
            [text appendFormat:@"%lu plain text for searching\n", (unsigned long)line];
        }
    }
    return text;
}

static void SCECheckLineLocality(void) {
    NSDictionary<NSString *, NSNumber *> *regularExpressions = @{
        @"foo\\w+" : @NO,
        @"\\bfoo\\b" : @NO,
        @"^t\\w+$" : @NO,
        @"(?i)abc" : @NO,
        @"(?<name>x)\\k<name>" : @NO,
        @"[\\^a]" : @NO,
        @"a\\\\nb" : @NO,
        @"\\d+\\.\\d*" : @NO,
        @"a\\nb" : @YES,
        @"\\s+" : @YES,
        @"[^a]" : @YES,
        @"\\W" : @YES,
        @"(?s)a.b" : @YES,
        @"(?is:a.b)" : @YES,
        @"\\p{L}" : @YES,
        @"\\Aabc" : @YES,
        @"abc\\z" : @YES,
        @"[[:space:]]" : @YES,
        @"\\x0a" : @YES,
        @"\\R" : @YES,
    };
    for (NSString *pattern in regularExpressions) {
        SCETextSearchQuery *query = SCEQuery(pattern, SCETextSearchOptionRegularExpression);
        SEARCH_CHECK(query.canMatchAcrossLines == regularExpressions[pattern].boolValue,
                     ([NSString stringWithFormat:@"line locality of /%@/ differs", pattern].UTF8String));
    }
    SEARCH_CHECK(!SCEQuery(@"\\s+", 0).canMatchAcrossLines, "a literal pattern without a line feed stays in lines");
    SEARCH_CHECK(SCEQuery(@"a\nb", SCETextSearchOptionWholeWord).canMatchAcrossLines,
                 "a literal pattern with a line feed must search the whole document");

    // Searching each line separately must reproduce whole-document matches,
    // including anchors, word boundaries, lookarounds, and CRLF endings.
    NSString *text = @"alpha beta\r\nbeta\n\nbetamax beta_x\n beta\r\nbeta";
    SCETextBuffer *buffer = [[SCETextBuffer alloc] initWithString:text];
    NSArray<SCETextSearchQuery *> *queries = @[
        SCEQuery(@"beta", SCETextSearchOptionWholeWord), SCEQuery(@"^beta", SCETextSearchOptionRegularExpression),
        SCEQuery(@"beta$", SCETextSearchOptionRegularExpression),
        SCEQuery(@"(?<!a)beta(?!x)", SCETextSearchOptionRegularExpression),
        SCEQuery(@"\\bbeta\\B", SCETextSearchOptionRegularExpression), SCEQuery(@"a\r", 0)
    ];
    for (SCETextSearchQuery *query in queries) {
        SEARCH_CHECK(!query.canMatchAcrossLines, "the equivalence queries must stay within lines");
        NSMutableData *lineMatches = [NSMutableData data];
        for (NSUInteger line = 0; line < buffer.lineCount; line++) {
            NSRange range = [buffer UTF16RangeOfLine:line includingLineEnding:YES];
            [lineMatches appendData:[query rangeDataOfMatchesInBuffer:buffer
                                                           UTF16Range:range
                                                         maximumCount:100
                                                          isCancelled:nil
                                                                error:NULL]];
        }
        NSData *whole = [query rangeDataOfMatchesInString:text maximumCount:100 isCancelled:nil error:NULL];
        SEARCH_CHECK([lineMatches isEqualToData:whole],
                     ([NSString stringWithFormat:@"line-by-line matches of \"%@\" differ", query.pattern].UTF8String));
    }
    puts("PASS search line locality: conservative regular expression classification, line-by-line equivalence");
}

static void SCECheckProgressiveSearch(void) {
    SCEEditorView *editor = [[SCEEditorView alloc] initWithFrame:NSMakeRect(0, 0, 600, 400)];
    editor.string = SCESearchDocument(60000);
    editor.selectedRange = NSMakeRange(0, 0);
    __block NSUInteger notifications = 0;
    id observer = [NSNotificationCenter.defaultCenter addObserverForName:SCEEditorSearchResultsDidChangeNotification
                                                                  object:editor
                                                                   queue:nil
                                                              usingBlock:^(NSNotification *note) {
                                                                  notifications++;
                                                              }];
    editor.searchQuery = SCEQuery(@"needle", 0);
    NSArray<NSValue *> *reference = SCEReferenceMatches(editor);
    SEARCH_CHECK(reference.count > 600, "the reference search must find matches throughout the document");
    SEARCH_CHECK(editor.isSearchPending, "a large document must continue searching in the background");
    NSArray<NSValue *> *initial = editor.searchMatchRanges;
    SEARCH_CHECK(initial.count >= 2 && initial.count < reference.count &&
                     [initial isEqualToArray:[reference subarrayWithRange:NSMakeRange(0, initial.count)]],
                 "the viewport must be searched synchronously before the rest of the document");
    SEARCH_CHECK([editor canSelectNextSearchMatchFromUTF16OffsetWithoutSearching:0],
                 "a viewport match after the caret must be selectable without searching");
    NSUInteger farOffset = editor.bufferSnapshot.lengthUTF16 * 3 / 5;
    SEARCH_CHECK(![editor canSelectNextSearchMatchFromUTF16OffsetWithoutSearching:farOffset],
                 "unsearched lines after an offset must leave its next match undetermined");

    // Navigation searches only toward the requested match.
    editor.selectedRange = NSMakeRange(farOffset, 0);
    NSUInteger expected = SCEIndexOfReferenceMatchAtOrAfter(reference, farOffset);
    SEARCH_CHECK([editor selectNextSearchMatch] && NSEqualRanges(editor.selectedRange, reference[expected].rangeValue),
                 "next-match navigation into unsearched text must find the document's next match");
    SEARCH_CHECK(editor.isSearchPending && editor.numberOfSearchMatches < reference.count,
                 "navigation must not search the whole document");
    NSUInteger backOffset = editor.bufferSnapshot.lengthUTF16 / 3;
    editor.selectedRange = NSMakeRange(backOffset, 0);
    expected = SCEIndexOfReferenceMatchEndingAtOrBefore(reference, backOffset);
    SEARCH_CHECK([editor selectPreviousSearchMatch] &&
                     NSEqualRanges(editor.selectedRange, reference[expected].rangeValue),
                 "previous-match navigation into unsearched text must find the document's previous match");
    SEARCH_CHECK(SCEWaitUntilSearchCompletes(editor), "the background search must complete");
    SEARCH_CHECK([editor.searchMatchRanges isEqualToArray:reference],
                 "progressive results must equal a whole-document search");
    SEARCH_CHECK(notifications > 1, "background progress must post notifications");
    editor.selectedRange = NSMakeRange(NSMaxRange(reference.lastObject.rangeValue), 0);
    SEARCH_CHECK([editor selectNextSearchMatch] && NSEqualRanges(editor.selectedRange, reference[0].rangeValue),
                 "next-match navigation must wrap to the first match");

    // Edits during the background search, including pastes longer than the
    // synchronous limit, must converge to a whole-document search of the result.
    NSMutableString *paste = [NSMutableString string];
    while (paste.length < 50000) {
        [paste appendString:@"pasted needle line\n"];
    }
    for (NSUInteger round = 0; round < 3; round++) {
        editor.searchQuery = nil;
        editor.searchQuery =
            SCEQuery(round == 1 ? @"needle and" : @"needle", round == 2 ? SCETextSearchOptionWholeWord : 0);
        for (NSUInteger edit = 0; edit < 60; edit++) {
            NSUInteger length = editor.bufferSnapshot.lengthUTF16;
            NSUInteger location = SCESearchRandom(length + 1);
            NSRange range = NSMakeRange(location, MIN(length - location, SCESearchRandom(40)));
            NSArray<NSString *> *insertions = @[ @"", @"x", @"needle", @"nee", @"dle\n", @"\r\nneedle and\n", paste ];
            NSString *insertion = insertions[SCESearchRandom(edit % 20 == 5 ? insertions.count : insertions.count - 1)];
            [editor insertText:insertion replacementRange:range];
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.0005, true);
        }
        SEARCH_CHECK(SCEWaitUntilSearchCompletes(editor), "the search must complete after edits");
        SEARCH_CHECK([editor.searchMatchRanges isEqualToArray:SCEReferenceMatches(editor)],
                     "incremental results after edits must equal a whole-document search");
    }

    // An edit in a finished search updates its lines without a new search.
    editor.selectedRange = NSMakeRange(0, 0);
    [editor insertText:@"needle " replacementRange:NSMakeRange(0, 0)];
    SEARCH_CHECK(!editor.isSearchPending && [editor.searchMatchRanges isEqualToArray:SCEReferenceMatches(editor)],
                 "a short edit must search its lines synchronously");
    [NSNotificationCenter.defaultCenter removeObserver:observer];
    puts("PASS progressive search: synchronous viewport, lazy navigation, background completion, edits during search");
}

static void SCECheckWholeDocumentSearch(void) {
    SCEEditorView *editor = [[SCEEditorView alloc] initWithFrame:NSMakeRect(0, 0, 600, 400)];
    NSMutableString *text = [NSMutableString string];
    for (NSUInteger line = 0; line < 8000; line++) {
        [text appendString:line % 13 == 0 ? @"value =\n  42;\n" : @"value = 7;\n"];
    }
    editor.string = text;
    editor.searchQuery = SCEQuery(@"=\\s+42", SCETextSearchOptionRegularExpression);
    SEARCH_CHECK(editor.searchQuery.canMatchAcrossLines && editor.isSearchPending,
                 "a query that crosses lines must search the whole document in the background");
    SEARCH_CHECK(SCEWaitUntilSearchCompletes(editor), "the whole-document search must complete");
    NSArray<NSValue *> *reference = SCEReferenceMatches(editor);
    SEARCH_CHECK(reference.count > 600 && [editor.searchMatchRanges isEqualToArray:reference],
                 "whole-document results must include matches across line endings");
    NSRange second = reference[1].rangeValue;
    [editor insertText:@"XY" replacementRange:NSMakeRange(second.location + 1, 0)];
    SEARCH_CHECK(editor.isSearchPending && editor.numberOfSearchMatches == reference.count - 1,
                 "an edit must remove the intersecting match and wait for a new whole-document search");
    SEARCH_CHECK(NSEqualRanges(editor.searchMatchRanges[1].rangeValue,
                               NSMakeRange(reference[2].rangeValue.location + 2, reference[2].rangeValue.length)),
                 "matches after the edit must move with the text");
    editor.selectedRange = NSMakeRange(0, 0);
    SEARCH_CHECK([editor selectNextSearchMatch] && !editor.isSearchPending,
                 "navigation must complete a stale whole-document search synchronously");
    SEARCH_CHECK([editor.searchMatchRanges isEqualToArray:SCEReferenceMatches(editor)],
                 "the synchronous whole-document search must match the edited text");
    puts("PASS whole-document search: multiline matches, edits, synchronous navigation");
}

static void SCECheckSearchLimit(void) {
    SCEEditorView *editor = [[SCEEditorView alloc] initWithFrame:NSMakeRect(0, 0, 600, 400)];
    // Concurrent chunks may finish after the limit is reached, so the document
    // holds far more matches than the limit plus every chunk in flight.
    NSMutableString *text = [NSMutableString stringWithCapacity:1600000];
    for (NSUInteger line = 0; line < 400000; line++) {
        [text appendString:@"a a\n"];
    }
    editor.string = text;
    editor.searchQuery = SCEQuery(@"a", 0);
    SEARCH_CHECK(SCEWaitUntilSearchCompletes(editor), "a search with too many matches must stop");
    SEARCH_CHECK(editor.isSearchResultTruncated &&
                     editor.numberOfSearchMatches >= SCETextSearchDefaultMaximumMatchCount &&
                     editor.numberOfSearchMatches < 800000,
                 "the background search must stop collecting at the match limit");
    editor.selectedRange = NSMakeRange(text.length - 7, 0);
    SEARCH_CHECK([editor selectNextSearchMatch] && NSEqualRanges(editor.selectedRange, NSMakeRange(text.length - 6, 1)),
                 "navigation must still find matches in text the limited search skipped");
    puts("PASS search limit: background collection stops, navigation continues");
}

NSUInteger SCECheckIncrementalSearch(void) {
    SCECheckLineLocality();
    SCECheckProgressiveSearch();
    SCECheckWholeDocumentSearch();
    SCECheckSearchLimit();
    return SCESearchCheckCount;
}

void SCEBenchmarkSearch(void) {
    SCEEditorView *editor = [[SCEEditorView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
    editor.string = SCESearchDocument(1000000);
    SCETextBuffer *snapshot = editor.bufferSnapshot;
    SCETextSearchQuery *query = SCEQuery(@"needle", 0);
    double start = SCESearchMilliseconds();
    NSData *whole = [query rangeDataOfMatchesInString:snapshot.string
                                         maximumCount:SCETextSearchDefaultMaximumMatchCount
                                          isCancelled:nil
                                                error:NULL];
    double wholeMS = SCESearchMilliseconds() - start;
    start = SCESearchMilliseconds();
    editor.searchQuery = query;
    double viewportMS = SCESearchMilliseconds() - start;
    NSUInteger viewportMatches = editor.numberOfSearchMatches;
    SCEWaitUntilSearchCompletes(editor);
    double completeMS = SCESearchMilliseconds() - start;
    SEARCH_CHECK(editor.numberOfSearchMatches == whole.length / sizeof(NSRange),
                 "benchmark results must equal a whole-document search");
    double editSamples = 0;
    double plainEditSamples = 0;
    editor.searchQuery = nil;
    for (NSUInteger edit = 0; edit < 200; edit++) {
        NSUInteger location = SCESearchRandom(snapshot.lengthUTF16);
        double tick = SCESearchMilliseconds();
        [editor insertText:@"needle" replacementRange:NSMakeRange(location, 0)];
        plainEditSamples += SCESearchMilliseconds() - tick;
    }
    editor.searchQuery = query;
    SCEWaitUntilSearchCompletes(editor);
    for (NSUInteger edit = 0; edit < 200; edit++) {
        NSUInteger location = SCESearchRandom(snapshot.lengthUTF16);
        double tick = SCESearchMilliseconds();
        [editor insertText:@"needle" replacementRange:NSMakeRange(location, 0)];
        editSamples += SCESearchMilliseconds() - tick;
        SEARCH_CHECK(!editor.isSearchPending, "a typed edit must leave current results");
    }
    printf("SEARCH BENCH (debug build): %.1f Mi UTF-16 units, %lu matches: whole-document search %.0f ms; "
           "editor viewport %.2f ms (%lu matches), complete %.0f ms; edit %.3f ms with search, %.3f ms without\n",
           snapshot.lengthUTF16 / 1048576.0, (unsigned long)(whole.length / sizeof(NSRange)), wholeMS, viewportMS,
           (unsigned long)viewportMatches, completeMS, editSamples / 200, plainEditSamples / 200);
}
