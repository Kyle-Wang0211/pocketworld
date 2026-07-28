#import <UIKit/UIKit.h>
#import <XCTest/XCTest.h>

#import "../Runner/pw_jxl_bridge.h"

@interface PWJXLBridgeTests : XCTestCase
@end

@implementation PWJXLBridgeTests

- (void)testFileRoundTripReconstructsExactJPEGBytes {
  XCTAssertEqualObjects([NSString stringWithUTF8String:pw_jxl_version()],
                        @"0.12.0");
  XCTAssertEqualObjects(
      [NSString stringWithUTF8String:pw_jxl_revision()],
      @"a7a9c787341cf703dede03c2009fa460cae5e5df");

  UIGraphicsImageRenderer* renderer =
      [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(64, 64)];
  UIImage* image = [renderer imageWithActions:^(UIGraphicsImageRendererContext*
                                                _Nonnull context) {
    [[UIColor colorWithRed:0.2 green:0.4 blue:0.8 alpha:1.0] setFill];
    [context fillRect:CGRectMake(0, 0, 64, 64)];
  }];
  NSData* source = UIImageJPEGRepresentation(image, 0.92);
  XCTAssertNotNil(source);

  NSString* temporary = NSTemporaryDirectory();
  NSString* identifier = NSUUID.UUID.UUIDString;
  NSString* jpegPath =
      [temporary stringByAppendingPathComponent:
                     [identifier stringByAppendingString:@".jpg"]];
  NSString* jxlPath = [jpegPath stringByAppendingString:@".jxl"];
  NSString* reconstructedPath =
      [jpegPath stringByAppendingString:@".reconstructed.jpg"];
  XCTAssertTrue([source writeToFile:jpegPath atomically:YES]);

  uint64_t encodeMicros = 0;
  int32_t status = pw_jxl_encode_jpeg_file(
      jpegPath.fileSystemRepresentation, jxlPath.fileSystemRepresentation, 7,
      &encodeMicros);
  XCTAssertEqual(status, PW_JXL_OK, @"%s", pw_jxl_error_message(status));

  uint64_t decodeMicros = 0;
  status = pw_jxl_reconstruct_jpeg_file(
      jxlPath.fileSystemRepresentation,
      reconstructedPath.fileSystemRepresentation, &decodeMicros);
  XCTAssertEqual(status, PW_JXL_OK, @"%s", pw_jxl_error_message(status));

  NSData* reconstructed = [NSData dataWithContentsOfFile:reconstructedPath];
  XCTAssertEqualObjects(reconstructed, source);
  XCTAssertGreaterThan(encodeMicros, (uint64_t)0);
  XCTAssertGreaterThan(decodeMicros, (uint64_t)0);

  NSFileManager* files = NSFileManager.defaultManager;
  [files removeItemAtPath:jpegPath error:nil];
  [files removeItemAtPath:jxlPath error:nil];
  [files removeItemAtPath:reconstructedPath error:nil];
}

@end
