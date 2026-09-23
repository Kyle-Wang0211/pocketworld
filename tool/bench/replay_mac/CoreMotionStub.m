// 空实现:Mac 上没有 IMU,isGyroAvailable/isAccelerometerAvailable 恒 NO
// ⇒ 就算有人调了直播的 begin(),它也会如实返回 -1,不会假装起了传感器。
#import "CoreMotion/CoreMotionStub.h"

@implementation CMLogItem
- (NSTimeInterval)timestamp { return 0; }
@end
@implementation CMGyroData
- (CMRotationRate)rotationRate { CMRotationRate r = {0, 0, 0}; return r; }
@end
@implementation CMAccelerometerData
- (CMAcceleration)acceleration { CMAcceleration a = {0, 0, 0}; return a; }
@end
@implementation CMMotionManager
- (BOOL)isAccelerometerAvailable { return NO; }
- (BOOL)isGyroAvailable { return NO; }
- (void)startAccelerometerUpdatesToQueue:(NSOperationQueue *)queue withHandler:(CMAccelerometerHandler)handler {}
- (void)stopAccelerometerUpdates {}
- (void)startGyroUpdatesToQueue:(NSOperationQueue *)queue withHandler:(CMGyroHandler)handler {}
- (void)stopGyroUpdates {}
@end
