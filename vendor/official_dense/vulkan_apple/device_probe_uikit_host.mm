// Copyright (c) 2026, PocketWorld contributors.
// SPDX-License-Identifier: BSD-3-Clause

#import <UIKit/UIKit.h>
#import <BackgroundTasks/BackgroundTasks.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstdio>
#include <string>
#include <thread>

#include "device_probe_main.h"

namespace {

NSString* const kDenseTaskIdentifier =
    @"com.kyle.PocketWorld.DenseProbe.dense";

void PrintBackgroundState(const char* const stage, const bool gpu_supported,
                          const char* const detail) {
  std::printf(
      "{\"background_stage\":\"%s\",\"gpu_supported\":%s,"
      "\"detail\":\"%s\"}\n",
      stage, gpu_supported ? "true" : "false",
      detail == nullptr ? "" : detail);
  std::fflush(stdout);
}

}  // namespace

@interface PWDenseProbeDelegate : UIResponder <UIApplicationDelegate> {
 @private
  UIWindow* window_;
  std::atomic_bool running_;
  std::atomic_bool expired_;
}
@end

@implementation PWDenseProbeDelegate

- (void)runProbeWithTask:(BGContinuedProcessingTask*)task
    API_AVAILABLE(ios(26.0)) {
  if (running_.exchange(true)) {
    [task setTaskCompletedWithSuccess:NO];
    return;
  }
  expired_.store(false);
  task.progress.totalUnitCount = 10000;
  task.progress.completedUnitCount = 100;
  task.expirationHandler = ^{
    expired_.store(true);
    PrintBackgroundState("expired", true,
                         "system or user requested termination");
  };

  NSString* executable = [NSBundle mainBundle].executablePath;
  const char* utf8 = executable.UTF8String;
  const std::string executable_path = utf8 == nullptr ? "" : utf8;
  PWDenseProbeDelegate* const delegate = self;
  std::thread([delegate, task, executable_path]() {
    std::thread progress_thread([delegate, task]() {
      while (delegate->running_.load()) {
        std::this_thread::sleep_for(std::chrono::seconds(2));
        if (!delegate->running_.load()) break;
        const int64_t current = task.progress.completedUnitCount;
        task.progress.completedUnitCount =
            std::min<int64_t>(9900, current + 40);
      }
    });
    const int status = RunDeviceProbeSequence(executable_path.c_str());
    delegate->running_.store(false);
    progress_thread.join();
    const bool success = status == 0 && !delegate->expired_.load();
    if (success) {
      task.progress.completedUnitCount = task.progress.totalUnitCount;
    }
    [task setTaskCompletedWithSuccess:success ? YES : NO];
    PrintBackgroundState(success ? "complete" : "failed", true,
                         success ? "probe completed" : "probe failed");
    std::fflush(stdout);
    std::fflush(stderr);
    std::_Exit(success ? 0 : 1);
  }).detach();
}

- (void)registerAndSubmitContinuedTask API_AVAILABLE(ios(26.0)) {
  const BGContinuedProcessingTaskRequestResources supported =
      BGTaskScheduler.supportedResources;
  const bool gpu_supported =
      (supported & BGContinuedProcessingTaskRequestResourcesGPU) != 0;
  PrintBackgroundState("capability", gpu_supported,
                       gpu_supported ? "background GPU available"
                                     : "background GPU unavailable");
  if (!gpu_supported) return;

  const BOOL registered = [[BGTaskScheduler sharedScheduler]
      registerForTaskWithIdentifier:kDenseTaskIdentifier
                         usingQueue:dispatch_get_main_queue()
                      launchHandler:^(__kindof BGTask* delivered) {
    BGContinuedProcessingTask* continued =
        (BGContinuedProcessingTask*)delivered;
    [self runProbeWithTask:continued];
  }];
  if (!registered) {
    PrintBackgroundState("registration_failed", true,
                         "identifier rejected by Info.plist");
    return;
  }

  BGContinuedProcessingTaskRequest* request =
      [[BGContinuedProcessingTaskRequest alloc]
          initWithIdentifier:kDenseTaskIdentifier
                       title:@"PocketWorld 稠密重建"
                    subtitle:@"正在生成真彩稠密点云…"];
  request.strategy =
      BGContinuedProcessingTaskRequestSubmissionStrategyFail;
  request.requiredResources =
      BGContinuedProcessingTaskRequestResourcesGPU;
  NSError* error = nil;
  const BOOL submitted = [[BGTaskScheduler sharedScheduler]
      submitTaskRequest:request
                   error:&error];
  if (!submitted) {
    const char* detail = error.localizedDescription.UTF8String;
    PrintBackgroundState("submission_failed", true, detail);
    return;
  }
  PrintBackgroundState("submitted", true,
                       "continued GPU task accepted");
}

- (BOOL)application:(UIApplication*)application
    didFinishLaunchingWithOptions:(NSDictionary*)launchOptions {
  (void)application;
  (void)launchOptions;
  window_ = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
  UIViewController* controller = [[UIViewController alloc] init];
  controller.view.backgroundColor = [UIColor blackColor];
  window_.rootViewController = controller;
  [window_ makeKeyAndVisible];

  if (@available(iOS 26.0, *)) {
    [self registerAndSubmitContinuedTask];
  } else {
    PrintBackgroundState("unsupported_os", false,
                         "iOS 26 continued processing required");
  }
  return YES;
}

@end

int main(int argc, char** argv) {
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil,
                             NSStringFromClass([PWDenseProbeDelegate class]));
  }
}
