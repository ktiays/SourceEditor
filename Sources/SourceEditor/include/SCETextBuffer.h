#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A persistent, balanced rope of bounded UTF-16 chunks. Not thread-safe for
/// mutation. A copy shares immutable nodes and can be read on another queue.
/// All offsets and NSRanges in this API count UTF-16 code units, never bytes.
/// Line indices start at zero. LF and CRLF are preserved; a final newline adds
/// an empty last line. Standalone CR line endings are not indexed.
@interface SCETextBuffer : NSObject <NSCopying>

- (instancetype)initWithString:(NSString *)string NS_DESIGNATED_INITIALIZER;

- (instancetype)init;

/// Creates a buffer that reads a UTF-8 file on demand instead of decoding it up
/// front. Files on local volumes are memory-mapped read-only; files on other
/// volumes are read into memory. Loading scans the bytes once, in parallel, to
/// index UTF-16 lengths and line feeds; unedited text is decoded only when read,
/// through a small bounded cache, so memory use does not grow with file size.
///
/// A leading UTF-8 byte order mark is not part of the text. Each maximal ill-formed
/// subsequence decodes to one U+FFFD REPLACEMENT CHARACTER. Use initWithString:
/// for other encodings.
///
/// The mapping lasts as long as this buffer or any copy that shares unedited text.
/// Replacing the file, as atomic saves do, does not affect the buffer. Truncating
/// the file in place while it is mapped makes later reads of the removed pages
/// terminate the process, so do not use this initializer for files that other
/// processes rewrite in place.
- (nullable instancetype)initWithContentsOfURL:(NSURL *)url error:(NSError **)error;

@property (nonatomic, readonly) NSUInteger lengthUTF16;
@property (nonatomic, readonly) NSUInteger lineCount;
@property (nonatomic, readonly) NSUInteger revision;
/// Shared by copies; distinguishes independent documents with equal revisions.
@property (nonatomic, readonly, copy) NSUUID *documentIdentifier;

/// Materializes the whole document, O(document length). Avoid on the input path.
@property (nonatomic, readonly, copy) NSString *string;

- (NSString *)substringWithUTF16Range:(NSRange)range;

/// Copies directly from rope leaves without materializing an NSString.
- (void)getUTF16Characters:(unichar *_Nullable)characters range:(NSRange)range;

- (NSUInteger)lineIndexForUTF16Offset:(NSUInteger)offset;

- (NSRange)UTF16RangeOfLine:(NSUInteger)lineIndex includingLineEnding:(BOOL)includeEnding;

- (void)replaceCharactersInUTF16Range:(NSRange)range withString:(NSString *)string;

/// Replaces range with the text of buffer by sharing its immutable nodes, in
/// O(log n) time and without reading the text. Later edits to either buffer do
/// not affect the other.
- (void)replaceCharactersInUTF16Range:(NSRange)range withBuffer:(SCETextBuffer *)buffer;

@end

NS_ASSUME_NONNULL_END
