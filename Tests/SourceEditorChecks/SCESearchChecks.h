#import <Foundation/Foundation.h>

/// Checks line-local query classification and the editor's incremental,
/// viewport-first search of large documents.
NSUInteger SCECheckIncrementalSearch(void);

/// Prints the latency of the first viewport matches, complete results, and edits.
void SCEBenchmarkSearch(void);
