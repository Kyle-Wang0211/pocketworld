#import "AppDelegate.h"

#import <CommonCrypto/CommonDigest.h>
#import <Metal/Metal.h>
#import <mach/mach.h>
#import <sys/sysctl.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

extern "C" int aether_gpu_match_gemm_pairs(
    const std::uint8_t* dA,
    int nA,
    const std::uint8_t* dB,
    int nB,
    double max_ratio,
    std::uint32_t* out_pairs,
    int max_pairs,
    int* out_num_matches);

namespace {

constexpr int kDescriptorRowsA = 8192;
constexpr int kDescriptorRowsB = 8192;
constexpr int kDescriptorColumns = 128;
constexpr int kStoredMatches = 3177;
constexpr NSUInteger kWarmRunSafetyCap = 10000;
constexpr NSTimeInterval kMaximumSoakSeconds = 300.0;
constexpr NSTimeInterval kRecoveryTimeoutSeconds = 600.0;
constexpr NSUInteger kProgressWriteInterval = 25;

NSString* hexDigest(const unsigned char* digest) {
    NSMutableString* value = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; ++index) {
        [value appendFormat:@"%02x", digest[index]];
    }
    return value;
}

NSString* sha256Bytes(const void* bytes, size_t length) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes, static_cast<CC_LONG>(length), digest);
    return hexDigest(digest);
}

NSString* thermalStateName(NSProcessInfoThermalState state) {
    switch (state) {
        case NSProcessInfoThermalStateNominal: return @"nominal";
        case NSProcessInfoThermalStateFair: return @"fair";
        case NSProcessInfoThermalStateSerious: return @"serious";
        case NSProcessInfoThermalStateCritical: return @"critical";
    }
    return @"unknown";
}

uint64_t residentBytes() {
    mach_task_basic_info_data_t info{};
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    const kern_return_t result = task_info(
        mach_task_self(), MACH_TASK_BASIC_INFO,
        reinterpret_cast<task_info_t>(&info), &count);
    return result == KERN_SUCCESS ? info.resident_size : 0;
}

NSString* machineIdentifier() {
    size_t size = 0;
    sysctlbyname("hw.machine", nullptr, &size, nullptr, 0);
    std::string value(size, '\0');
    sysctlbyname("hw.machine", value.data(), &size, nullptr, 0);
    if (!value.empty() && value.back() == '\0') value.pop_back();
    return [NSString stringWithUTF8String:value.c_str()];
}

std::vector<std::uint64_t> sortedPairKeys(
    const std::uint32_t* pairs,
    size_t pairCount) {
    std::vector<std::uint64_t> keys;
    keys.reserve(pairCount);
    for (size_t index = 0; index < pairCount; ++index) {
        keys.push_back(
            (static_cast<std::uint64_t>(pairs[index * 2]) << 32) |
            pairs[index * 2 + 1]);
    }
    std::sort(keys.begin(), keys.end());
    return keys;
}

}  // namespace

@interface AppDelegate ()

@property(nonatomic, strong) UITextView* statusView;

@end


@implementation AppDelegate

- (BOOL)application:(UIApplication*)application
    didFinishLaunchingWithOptions:(NSDictionary*)launchOptions {
    (void)launchOptions;
    application.idleTimerDisabled = YES;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController* controller = [[UIViewController alloc] init];
    controller.view.backgroundColor = UIColor.systemBackgroundColor;
    self.statusView = [[UITextView alloc] initWithFrame:CGRectZero];
    self.statusView.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusView.editable = NO;
    self.statusView.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
    self.statusView.text = @"PW Match Bench\nloading cap51 pair 43↔44…";
    [controller.view addSubview:self.statusView];
    [NSLayoutConstraint activateConstraints:@[
        [self.statusView.leadingAnchor constraintEqualToAnchor:controller.view.safeAreaLayoutGuide.leadingAnchor constant:12],
        [self.statusView.trailingAnchor constraintEqualToAnchor:controller.view.safeAreaLayoutGuide.trailingAnchor constant:-12],
        [self.statusView.topAnchor constraintEqualToAnchor:controller.view.safeAreaLayoutGuide.topAnchor constant:12],
        [self.statusView.bottomAnchor constraintEqualToAnchor:controller.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
    ]];
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self runBenchmark];
    });
    return YES;
}

- (void)setStatus:(NSString*)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusView.text = status;
    });
}

- (BOOL)writeJSON:(NSDictionary*)report toURL:(NSURL*)url error:(NSError**)error {
    NSData* data = [NSJSONSerialization dataWithJSONObject:report
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:error];
    return data && [data writeToURL:url options:NSDataWritingAtomic error:error];
}

- (void)fail:(NSString*)message {
    [self setStatus:[NSString stringWithFormat:@"PW Match Bench FAILED\n\n%@", message]];
}

- (void)runBenchmark {
    @autoreleasepool {
        NSBundle* bundle = NSBundle.mainBundle;
        NSURL* descriptorAURL = [bundle URLForResource:@"desc43" withExtension:@"u8"];
        NSURL* descriptorBURL = [bundle URLForResource:@"desc44" withExtension:@"u8"];
        NSURL* storedURL = [bundle URLForResource:@"matches43_44" withExtension:@"u32"];
        if (!descriptorAURL || !descriptorBURL || !storedURL) {
            [self fail:@"bundled descriptor fixture is missing"];
            return;
        }
        NSError* error = nil;
        NSData* descriptorA = [NSData dataWithContentsOfURL:descriptorAURL options:NSDataReadingMappedIfSafe error:&error];
        NSData* descriptorB = [NSData dataWithContentsOfURL:descriptorBURL options:NSDataReadingMappedIfSafe error:&error];
        NSData* stored = [NSData dataWithContentsOfURL:storedURL options:NSDataReadingMappedIfSafe error:&error];
        if (!descriptorA || !descriptorB || !stored ||
            descriptorA.length != static_cast<NSUInteger>(kDescriptorRowsA * kDescriptorColumns) ||
            descriptorB.length != static_cast<NSUInteger>(kDescriptorRowsB * kDescriptorColumns) ||
            stored.length != static_cast<NSUInteger>(kStoredMatches * 2 * sizeof(std::uint32_t))) {
            [self fail:[NSString stringWithFormat:@"fixture load/size failure: %@", error ?: @"invalid byte count"]];
            return;
        }

        NSArray<NSURL*>* documents = [[NSFileManager defaultManager]
            URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask];
        NSURL* directory = [documents.firstObject URLByAppendingPathComponent:@"match_bench" isDirectory:YES];
        if (![[NSFileManager defaultManager] createDirectoryAtURL:directory
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:&error]) {
            [self fail:[NSString stringWithFormat:@"result directory failure: %@", error]];
            return;
        }
        const long long startedMilliseconds = llround([[NSDate date] timeIntervalSince1970] * 1000.0);
        NSURL* partialURL = [directory URLByAppendingPathComponent:@"latest.partial.json"];
        NSURL* latestURL = [directory URLByAppendingPathComponent:@"latest.json"];
        NSURL* runURL = [directory URLByAppendingPathComponent:
            [NSString stringWithFormat:@"run_%lld.json", startedMilliseconds]];
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        NSMutableDictionary* report = [@{
            @"schema_version": @2,
            @"status": @"running",
            @"started_unix_ms": @(startedMilliseconds),
            @"bundle_identifier": bundle.bundleIdentifier ?: @"",
            @"bundle_version": [bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"",
            @"device_model": machineIdentifier() ?: @"unknown",
            @"os_version": UIDevice.currentDevice.systemVersion,
            @"metal_device": device.name ?: @"unavailable",
            @"fixture": @{
                @"image_a": @43,
                @"image_b": @44,
                @"descriptor_rows_a": @(kDescriptorRowsA),
                @"descriptor_rows_b": @(kDescriptorRowsB),
                @"descriptor_columns": @(kDescriptorColumns),
                @"stored_matches": @(kStoredMatches),
                @"descriptor_a_sha256": sha256Bytes(descriptorA.bytes, descriptorA.length),
                @"descriptor_b_sha256": sha256Bytes(descriptorB.bytes, descriptorB.length),
                @"stored_pairs_sha256": sha256Bytes(stored.bytes, stored.length),
            },
            @"warm_run_target": @(kWarmRunSafetyCap),
            @"soak_max_seconds": @(kMaximumSoakSeconds),
            @"recovery_timeout_seconds": @(kRecoveryTimeoutSeconds),
            @"runs": [NSMutableArray array],
        } mutableCopy];

        const auto expectedKeys = sortedPairKeys(
            static_cast<const std::uint32_t*>(stored.bytes), kStoredMatches);
        std::vector<std::uint32_t> output(
            static_cast<size_t>(std::min(kDescriptorRowsA, kDescriptorRowsB)) * 2);
        NSMutableArray* runs = report[@"runs"];
        BOOL failed = NO;
        BOOL reachedSerious = NO;
        const auto soakStarted = std::chrono::steady_clock::now();
        for (NSUInteger index = 0; index < kWarmRunSafetyCap; ++index) {
            if (index == 0 || index % kProgressWriteInterval == 0) {
                const double elapsed = std::chrono::duration<double>(
                    std::chrono::steady_clock::now() - soakStarted).count();
                [self setStatus:[NSString stringWithFormat:
                    @"PW Match Thermal Soak\nrun %lu · %.0f/%.0fs\nthermal: %@",
                    (unsigned long)index,
                    elapsed,
                    kMaximumSoakSeconds,
                    thermalStateName(NSProcessInfo.processInfo.thermalState)]];
            }
            const NSString* thermalBefore = thermalStateName(NSProcessInfo.processInfo.thermalState);
            const uint64_t rssBefore = residentBytes();
            int outputCount = 0;
            const auto started = std::chrono::steady_clock::now();
            const int status = aether_gpu_match_gemm_pairs(
                static_cast<const std::uint8_t*>(descriptorA.bytes),
                kDescriptorRowsA,
                static_cast<const std::uint8_t*>(descriptorB.bytes),
                kDescriptorRowsB,
                0.7,
                output.data(),
                std::min(kDescriptorRowsA, kDescriptorRowsB),
                &outputCount);
            const auto finished = std::chrono::steady_clock::now();
            const size_t validCount = outputCount > 0 ? static_cast<size_t>(outputCount) : 0;
            const bool exactSequence = status == 0 && outputCount == kStoredMatches &&
                std::memcmp(output.data(), stored.bytes, stored.length) == 0;
            const bool exactSet = status == 0 && outputCount == kStoredMatches &&
                sortedPairKeys(output.data(), validCount) == expectedKeys;
            NSMutableDictionary* run = [@{
                @"index": @(index),
                @"kind": index == 0 ? @"cold" : @"warm",
                @"status_code": @(status),
                @"elapsed_seconds": @(
                    std::chrono::duration<double>(finished - started).count()),
                @"output_matches": @(outputCount),
                @"exact_sequence": @(exactSequence),
                @"exact_set": @(exactSet),
                @"thermal_before": thermalBefore,
                @"thermal_after": thermalStateName(NSProcessInfo.processInfo.thermalState),
                @"rss_before_bytes": @(rssBefore),
                @"rss_after_bytes": @(residentBytes()),
                @"output_sha256": sha256Bytes(
                    output.data(), validCount * 2 * sizeof(std::uint32_t)),
            } mutableCopy];
            [runs addObject:run];
            report[@"completed_run_count"] = @(runs.count);
            const double soakElapsed = std::chrono::duration<double>(
                std::chrono::steady_clock::now() - soakStarted).count();
            report[@"soak_elapsed_seconds"] = @(soakElapsed);
            if (index == 0 || index % kProgressWriteInterval == 0) {
                [self writeJSON:report toURL:partialURL error:nil];
            }
            if (index == 0 && status == 0) {
                NSData* pairs = [NSData dataWithBytes:output.data()
                                               length:validCount * 2 * sizeof(std::uint32_t)];
                [pairs writeToURL:[directory URLByAppendingPathComponent:@"cold_output_pairs.u32"]
                          options:NSDataWritingAtomic
                            error:nil];
            }
            if (status != 0 || !exactSet) {
                failed = YES;
                break;
            }
            if (NSProcessInfo.processInfo.thermalState >= NSProcessInfoThermalStateSerious) {
                reachedSerious = YES;
                report[@"serious_reached_run_index"] = @(index);
                report[@"serious_reached_elapsed_seconds"] = @(soakElapsed);
                break;
            }
            if (soakElapsed >= kMaximumSoakSeconds) break;
        }

        report[@"thermal_serious_reached"] = @(reachedSerious);
        BOOL recovered = NO;
        NSTimeInterval recoveryElapsed = 0.0;
        if (reachedSerious && !failed) {
            const auto recoveryStarted = std::chrono::steady_clock::now();
            while (NSProcessInfo.processInfo.thermalState >= NSProcessInfoThermalStateSerious) {
                recoveryElapsed = std::chrono::duration<double>(
                    std::chrono::steady_clock::now() - recoveryStarted).count();
                [self setStatus:[NSString stringWithFormat:
                    @"PW Match Thermal Recovery\n%.0f/%.0fs\nthermal: %@",
                    recoveryElapsed,
                    kRecoveryTimeoutSeconds,
                    thermalStateName(NSProcessInfo.processInfo.thermalState)]];
                report[@"recovery_elapsed_seconds"] = @(recoveryElapsed);
                report[@"recovery_current_thermal"] = thermalStateName(
                    NSProcessInfo.processInfo.thermalState);
                [self writeJSON:report toURL:partialURL error:nil];
                if (recoveryElapsed >= kRecoveryTimeoutSeconds) break;
                [NSThread sleepForTimeInterval:1.0];
            }
            recovered = NSProcessInfo.processInfo.thermalState <
                NSProcessInfoThermalStateSerious;
            recoveryElapsed = std::chrono::duration<double>(
                std::chrono::steady_clock::now() - recoveryStarted).count();
        }
        report[@"thermal_recovered_below_serious"] = @(recovered);
        report[@"recovery_elapsed_seconds"] = @(recoveryElapsed);
        report[@"status"] = failed
            ? @"failed"
            : (reachedSerious && recovered ? @"complete" : @"thermal_incomplete");
        report[@"finished_unix_ms"] = @(llround([[NSDate date] timeIntervalSince1970] * 1000.0));
        report[@"final_thermal_state"] = thermalStateName(NSProcessInfo.processInfo.thermalState);
        report[@"final_rss_bytes"] = @(residentBytes());
        if (![self writeJSON:report toURL:runURL error:&error] ||
            ![self writeJSON:report toURL:latestURL error:&error]) {
            [self fail:[NSString stringWithFormat:@"result write failure: %@", error]];
            return;
        }
        [[NSFileManager defaultManager] removeItemAtURL:partialURL error:nil];

        NSMutableArray<NSNumber*>* warm = [NSMutableArray array];
        for (NSDictionary* run in runs) {
            if ([run[@"kind"] isEqual:@"warm"]) [warm addObject:run[@"elapsed_seconds"]];
        }
        NSArray<NSNumber*>* sorted = [warm sortedArrayUsingSelector:@selector(compare:)];
        NSNumber* median = sorted.count ? sorted[sorted.count / 2] : @0;
        NSDictionary* cold = runs.firstObject;
        [self setStatus:[NSString stringWithFormat:
            @"PW Match Thermal %@\n\nruns: %lu\ncold: %.3f ms\nwarm median: %.3f ms\nmatches: %@/%d\nexact set: %@\nserious: %@ · recovered: %@\nthermal: %@\n\n%@",
            [report[@"status"] uppercaseString],
            (unsigned long)runs.count,
            [cold[@"elapsed_seconds"] doubleValue] * 1000.0,
            median.doubleValue * 1000.0,
            cold[@"output_matches"],
            kStoredMatches,
            [cold[@"exact_set"] boolValue] ? @"PASS" : @"FAIL",
            reachedSerious ? @"YES" : @"NO",
            recovered ? @"YES" : @"NO",
            report[@"final_thermal_state"],
            latestURL.path]];
    }
}

@end
