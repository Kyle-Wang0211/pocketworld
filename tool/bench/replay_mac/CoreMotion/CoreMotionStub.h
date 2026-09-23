// 声明逐字对照 macOS 26.2 SDK 的 CoreMotion 头(CMLogItem.h / CMGyro.h /
// CMAccelerometer.h / CMMotionManager.h),只保留 PwXrslamLive.swift 用到的成员。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct { double x; double y; double z; } CMAcceleration;
typedef struct { double x; double y; double z; } CMRotationRate;

@interface CMLogItem : NSObject
@property(readonly, nonatomic) NSTimeInterval timestamp;
@end

@interface CMGyroData : CMLogItem
@property(readonly, nonatomic) CMRotationRate rotationRate;
@end

@interface CMAccelerometerData : CMLogItem
@property(readonly, nonatomic) CMAcceleration acceleration;
@end

typedef void (^CMAccelerometerHandler)(CMAccelerometerData * __nullable accelerometerData, NSError * __nullable error);
typedef void (^CMGyroHandler)(CMGyroData * __nullable gyroData, NSError * __nullable error);

@interface CMMotionManager : NSObject
@property(assign, nonatomic) NSTimeInterval accelerometerUpdateInterval;
@property(readonly, nonatomic, getter=isAccelerometerAvailable) BOOL accelerometerAvailable;
- (void)startAccelerometerUpdatesToQueue:(NSOperationQueue *)queue withHandler:(CMAccelerometerHandler)handler;
- (void)stopAccelerometerUpdates;
@property(assign, nonatomic) NSTimeInterval gyroUpdateInterval;
@property(readonly, nonatomic, getter=isGyroAvailable) BOOL gyroAvailable;
- (void)startGyroUpdatesToQueue:(NSOperationQueue *)queue withHandler:(CMGyroHandler)handler;
- (void)stopGyroUpdates;
@end

NS_ASSUME_NONNULL_END
