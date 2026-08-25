// PocketWorld Android capture — process-death attribution.
//
// PROBLEM
//   A capture session that ends because the OS killed the process looks exactly
//   like a user abandoning the app: the next launch just finds a half-written
//   session. Attribution has to come from the platform, after the fact, via
//   ActivityManager.getHistoricalProcessExitReasons(packageName, pid, maxNum)
//   -> List<ApplicationExitInfo>   (API 30).
//
//   The case that matters for a native VIO pipeline is Android 17's memory
//   limiter. Google's own words (Android Developers Blog, 2026-06,
//   "Prioritizing Memory Efficiency: Essential Steps for Android 17"):
//
//     "If an app exceeds those limits, Android will kill the process with no
//      associated stack trace."
//     "call getDescription() within ApplicationExitInfo. If the system applied
//      a limit, the exit reason is reported as REASON_OTHER and the description
//      string will contain MemoryLimiter:AnonSwap"
//
//   Two consequences that shape this module:
//     1. The reason code is REASON_OTHER (13) — the SAME bucket as ordinary
//        uninteresting system kills. The description substring is the only
//        discriminator. Matching on the reason code alone is useless; matching
//        on the code alone would also swallow every unrelated REASON_OTHER.
//     2. There is no stack trace and no crash. If we do not classify this at
//        the next launch, the failure mode is invisible forever.
//
//   xrslam's map + feature buffers are native anonymous memory, i.e. exactly
//   what AnonSwap accounts. This is the single most likely way a long capture
//   dies on Android 17, and it is the one death that leaves no other trace.
//
// FAIL-SAFE CONTRACT
//   The triage is append-only and watermark-based. `unreported()` returns every
//   record strictly newer than the watermark, oldest first, and the watermark
//   only advances when the caller confirms the batch was persisted. A crash
//   between read and persist re-delivers; it never skips. No record is ever
//   dropped, deduplicated away, or rewritten.

/// ApplicationExitInfo.REASON_* — platform values, API 30/31.
class ExitReason {
  static const int unknown = 0;
  static const int exitSelf = 1;
  static const int signaled = 2;
  static const int lowMemory = 3;
  static const int crash = 4;
  static const int crashNative = 5;
  static const int anr = 6;
  static const int initializationFailure = 7;
  static const int permissionChange = 8;
  static const int excessiveResourceUsage = 9;
  static const int userRequested = 10;
  static const int userStopped = 11;
  static const int dependencyDied = 12;
  static const int other = 13;
  static const int freezer = 14; // API 31
  static const int packageStateChange = 15; // API 31
  static const int packageUpdated = 16; // API 31
}

/// One ApplicationExitInfo, marshalled across the platform channel.
class ExitRecord {
  const ExitRecord({
    required this.timestampMs,
    required this.pid,
    required this.reason,
    required this.description,
    this.subReason = 0,
    this.status = 0,
    this.importance = 0,
    this.rssKb = 0,
    this.pssKb = 0,
    this.processName = '',
  });

  /// ApplicationExitInfo.getTimestamp() — wall clock ms.
  final int timestampMs;
  final int pid;

  /// getReason()
  final int reason;

  /// getDescription(). May be null on the platform side; marshal null as ''.
  final String description;

  final int subReason;
  final int status;
  final int importance;
  final int rssKb;
  final int pssKb;
  final String processName;
}

enum ExitClass {
  /// Android 17 memory limiter: REASON_OTHER + description contains
  /// "MemoryLimiter:AnonSwap". Silent, no stack trace, native-memory driven.
  memoryLimiterAnonSwap,

  /// REASON_OTHER + "MemoryLimiter" but a suffix we do not recognise. Reported
  /// separately rather than folded into the AnonSwap bucket, because folding
  /// would make a future platform change look like our known failure.
  memoryLimiterOther,

  /// Classic lowmemorykiller. Different mechanism, different fix.
  lowMemoryKill,

  /// Native crash — has a tombstone, unlike the memory limiter.
  nativeCrash,

  /// Managed (Java/Kotlin/Dart) crash.
  managedCrash,

  anr,

  /// System killed us for background resource use.
  excessiveResourceUsage,

  /// User swiped away, force-stopped, or we exited ourselves. Not a fault.
  benign,

  /// Everything else, including unrecognised REASON_OTHER.
  otherOrUnknown,
}

class ExitFinding {
  const ExitFinding({
    required this.record,
    required this.exitClass,
    required this.capturePipelineSuspect,
  });

  final ExitRecord record;
  final ExitClass exitClass;

  /// True when this death plausibly killed a capture session mid-flight and
  /// therefore must be surfaced, not logged and forgotten.
  final bool capturePipelineSuspect;
}

/// Exact substring published by Google. Case is significant: getDescription()
/// returns the platform's own string, so a case-insensitive match would only
/// widen the net for strings the platform never emits.
const String kMemoryLimiterTag = 'MemoryLimiter';
const String kMemoryLimiterAnonSwapTag = 'MemoryLimiter:AnonSwap';

class ExitTriage {
  ExitTriage({int watermarkMs = 0}) : _watermarkMs = watermarkMs;

  int _watermarkMs;

  /// Timestamp of the newest record the caller has confirmed persisted.
  int get watermarkMs => _watermarkMs;

  static ExitClass classify(ExitRecord r) {
    if (r.reason == ExitReason.other) {
      if (r.description.contains(kMemoryLimiterAnonSwapTag)) {
        return ExitClass.memoryLimiterAnonSwap;
      }
      if (r.description.contains(kMemoryLimiterTag)) {
        return ExitClass.memoryLimiterOther;
      }
      return ExitClass.otherOrUnknown;
    }
    switch (r.reason) {
      case ExitReason.lowMemory:
        return ExitClass.lowMemoryKill;
      case ExitReason.crashNative:
        return ExitClass.nativeCrash;
      case ExitReason.crash:
        return ExitClass.managedCrash;
      case ExitReason.anr:
        return ExitClass.anr;
      case ExitReason.excessiveResourceUsage:
        return ExitClass.excessiveResourceUsage;
      case ExitReason.exitSelf:
      case ExitReason.userRequested:
      case ExitReason.userStopped:
      case ExitReason.packageUpdated:
      case ExitReason.packageStateChange:
      case ExitReason.permissionChange:
        return ExitClass.benign;
      default:
        return ExitClass.otherOrUnknown;
    }
  }

  static bool isCapturePipelineSuspect(ExitClass c) {
    switch (c) {
      case ExitClass.memoryLimiterAnonSwap:
      case ExitClass.memoryLimiterOther:
      case ExitClass.lowMemoryKill:
      case ExitClass.nativeCrash:
      case ExitClass.managedCrash:
      case ExitClass.anr:
      case ExitClass.excessiveResourceUsage:
        return true;
      case ExitClass.benign:
      case ExitClass.otherOrUnknown:
        return false;
    }
  }

  /// Every record strictly newer than the watermark, oldest first.
  ///
  /// getHistoricalProcessExitReasons returns newest-first; we re-sort so the
  /// caller replays history in the order it happened. Ties on timestamp are
  /// broken by pid so the order is total and stable across launches.
  List<ExitFinding> unreported(List<ExitRecord> records) {
    final fresh = records.where((r) => r.timestampMs > _watermarkMs).toList()
      ..sort((a, b) {
        final t = a.timestampMs.compareTo(b.timestampMs);
        return t != 0 ? t : a.pid.compareTo(b.pid);
      });
    return fresh.map((r) {
      final c = classify(r);
      return ExitFinding(
        record: r,
        exitClass: c,
        capturePipelineSuspect: isCapturePipelineSuspect(c),
      );
    }).toList();
  }

  /// Advance the watermark ONLY after the batch is durably persisted.
  /// Never moves backwards, so a stale confirmation cannot re-open old records.
  void confirmPersisted(List<ExitFinding> reported) {
    for (final f in reported) {
      if (f.record.timestampMs > _watermarkMs) {
        _watermarkMs = f.record.timestampMs;
      }
    }
  }
}
