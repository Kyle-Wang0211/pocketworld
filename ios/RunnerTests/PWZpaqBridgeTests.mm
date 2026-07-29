#import <XCTest/XCTest.h>

#import "../Runner/pw_zpaq_bridge.h"

@interface PWZpaqBridgeTests : XCTestCase
@end

@implementation PWZpaqBridgeTests

- (void)testMethod5RoundTripRestoresExactBytes {
  XCTAssertEqualObjects([NSString stringWithUTF8String:pw_zpaq_version()],
                        @"7.15");
  XCTAssertEqualObjects(
      [NSString stringWithUTF8String:pw_zpaq_revision()],
      @"e85ec2529eb0ba22ceaeabd461e55357ef099b80f61c14f377b429ea3d49d418");

  NSMutableData* source = [NSMutableData dataWithLength:1024 * 1024];
  uint8_t* bytes = static_cast<uint8_t*>(source.mutableBytes);
  for (NSUInteger index = 0; index < source.length; ++index) {
    bytes[index] = static_cast<uint8_t>((index / 4096) % 7);
  }

  NSString* prefix = [NSTemporaryDirectory()
      stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
  NSString* sourcePath = [prefix stringByAppendingString:@".db"];
  NSString* archivePath = [sourcePath stringByAppendingString:@".zpaq"];
  NSString* restoredPath = [sourcePath stringByAppendingString:@".restored"];
  NSFileManager* files = NSFileManager.defaultManager;

  @try {
    XCTAssertTrue([source writeToFile:sourcePath atomically:YES]);
    uint64_t generation = pw_zpaq_cancellation_generation();
    int32_t status = pw_zpaq_compress_file(
        sourcePath.fileSystemRepresentation,
        archivePath.fileSystemRepresentation, 5, generation);
    XCTAssertEqual(status, PW_ZPAQ_OK, @"%s: %s",
                   pw_zpaq_error_message(status), pw_zpaq_last_error());

    generation = pw_zpaq_cancellation_generation();
    status = pw_zpaq_decompress_file(archivePath.fileSystemRepresentation,
                                     restoredPath.fileSystemRepresentation,
                                     generation);
    XCTAssertEqual(status, PW_ZPAQ_OK, @"%s: %s",
                   pw_zpaq_error_message(status), pw_zpaq_last_error());

    NSData* restored = [NSData dataWithContentsOfFile:restoredPath];
    XCTAssertEqualObjects(restored, source);
    XCTAssertLessThan(
        [files attributesOfItemAtPath:archivePath error:nil].fileSize,
        source.length);
  } @finally {
    [files removeItemAtPath:sourcePath error:nil];
    [files removeItemAtPath:archivePath error:nil];
    [files removeItemAtPath:restoredPath error:nil];
  }
}

@end
