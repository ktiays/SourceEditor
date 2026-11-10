#import <Foundation/Foundation.h>

/// Checks file-backed text buffers and the fragmented layout of long lines.
NSUInteger SCECheckLargeDocuments(void);

/// Prints load and long-line timings. Debug builds are unoptimized.
void SCEBenchmarkLargeDocuments(void);
