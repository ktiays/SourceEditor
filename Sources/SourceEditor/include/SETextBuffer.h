#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A persistent, balanced rope of bounded UTF-16 chunks. Not thread-safe for
/// mutation. A copy shares immutable nodes and can be read on another queue.
/// All offsets and NSRanges in this API count UTF-16 code units, never bytes.
/// Lines are zero-based. LF and CRLF are preserved; a final newline adds an
/// empty last line. Standalone CR line endings aren't indexed in this version.
@interface SETextBuffer : NSObject <NSCopying>

- (instancetype)initWithString:(NSString *)string NS_DESIGNATED_INITIALIZER;

- (instancetype)init;

@property (nonatomic, readonly) NSUInteger lengthUTF16;
@property (nonatomic, readonly) NSUInteger lineCount;
@property (nonatomic, readonly) NSUInteger revision;
/// Shared by copies; distinguishes independent documents with equal revisions.
@property (nonatomic, readonly, copy) NSUUID *documentIdentifier;

/// Materializes the whole document, O(document length). Avoid on the input path.
@property (nonatomic, readonly, copy) NSString *string;

- (NSString *)substringWithUTF16Range:(NSRange)range;

/// Copies directly from Rope leaves without materializing an NSString.
- (void)getUTF16Characters:(unichar *_Nullable)characters range:(NSRange)range;

- (NSUInteger)lineIndexForUTF16Offset:(NSUInteger)offset;

- (NSRange)UTF16RangeOfLine:(NSUInteger)lineIndex includingLineEnding:(BOOL)includeEnding;

- (void)replaceCharactersInUTF16Range:(NSRange)range withString:(NSString *)string;

@end

NS_ASSUME_NONNULL_END
