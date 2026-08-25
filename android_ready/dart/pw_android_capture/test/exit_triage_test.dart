import 'package:pw_android_capture/pw_android_capture.dart';
import 'package:test/test.dart';

ExitRecord rec({
  required int t,
  required int reason,
  String description = '',
  int pid = 100,
}) =>
    ExitRecord(
        timestampMs: t, pid: pid, reason: reason, description: description);

void main() {
  group('Android 17 memory limiter', () {
    test('REASON_OTHER + MemoryLimiter:AnonSwap is its own class', () {
      // Google's published shape: the reason code is the generic bucket and the
      // description substring is the only discriminator.
      final f = ExitTriage.classify(rec(
        t: 1,
        reason: ExitReason.other,
        description: 'MemoryLimiter:AnonSwap limit exceeded (rss=812MB)',
      ));
      expect(f, ExitClass.memoryLimiterAnonSwap);
      expect(ExitTriage.isCapturePipelineSuspect(f), isTrue);
    });

    test('the substring is found wherever it sits in the description', () {
      for (final d in <String>[
        'MemoryLimiter:AnonSwap',
        'process killed: MemoryLimiter:AnonSwap',
        'MemoryLimiter:AnonSwap; pid 1234; anon=900MB',
      ]) {
        expect(ExitTriage.classify(rec(t: 1, reason: ExitReason.other, description: d)),
            ExitClass.memoryLimiterAnonSwap,
            reason: d);
      }
    });

    test('an unrecognised MemoryLimiter suffix is NOT folded into AnonSwap', () {
      // Folding would make a future platform string look like the failure we
      // already know how to fix.
      expect(
          ExitTriage.classify(rec(
              t: 1,
              reason: ExitReason.other,
              description: 'MemoryLimiter:SomethingElse')),
          ExitClass.memoryLimiterOther);
    });

    test('the reason code alone never triggers it', () {
      expect(
          ExitTriage.classify(rec(
              t: 1, reason: ExitReason.other, description: 'system shutdown')),
          ExitClass.otherOrUnknown);
      expect(
          ExitTriage.classify(
              rec(t: 1, reason: ExitReason.other, description: '')),
          ExitClass.otherOrUnknown);
    });

    test('the description alone never triggers it either', () {
      // Same string under a different reason code is a different event.
      expect(
          ExitTriage.classify(rec(
              t: 1,
              reason: ExitReason.lowMemory,
              description: 'MemoryLimiter:AnonSwap')),
          ExitClass.lowMemoryKill);
    });

    test('the platform lowmemorykiller stays a separate diagnosis', () {
      expect(ExitTriage.classify(rec(t: 1, reason: ExitReason.lowMemory)),
          ExitClass.lowMemoryKill);
    });
  });

  group('classification of the rest', () {
    test('faults vs non-faults', () {
      const cases = <int, ExitClass>{
        ExitReason.crashNative: ExitClass.nativeCrash,
        ExitReason.crash: ExitClass.managedCrash,
        ExitReason.anr: ExitClass.anr,
        ExitReason.excessiveResourceUsage: ExitClass.excessiveResourceUsage,
        ExitReason.exitSelf: ExitClass.benign,
        ExitReason.userRequested: ExitClass.benign,
        ExitReason.userStopped: ExitClass.benign,
        ExitReason.packageUpdated: ExitClass.benign,
        ExitReason.unknown: ExitClass.otherOrUnknown,
        ExitReason.signaled: ExitClass.otherOrUnknown,
        ExitReason.freezer: ExitClass.otherOrUnknown,
      };
      cases.forEach((reason, want) {
        expect(ExitTriage.classify(rec(t: 1, reason: reason)), want,
            reason: 'reason=$reason');
      });
    });

    test('a user swipe-away is not reported as a capture failure', () {
      expect(ExitTriage.isCapturePipelineSuspect(ExitClass.benign), isFalse);
    });
  });

  group('watermark: never skip, re-deliver instead', () {
    final history = <ExitRecord>[
      rec(t: 300, reason: ExitReason.other, description: 'MemoryLimiter:AnonSwap', pid: 3),
      rec(t: 100, reason: ExitReason.userRequested, pid: 1),
      rec(t: 200, reason: ExitReason.crashNative, pid: 2),
    ];

    test('returns oldest-first regardless of platform ordering', () {
      // getHistoricalProcessExitReasons returns newest-first.
      final t = ExitTriage();
      final found = t.unreported(history);
      expect(found.map((f) => f.record.timestampMs).toList(), [100, 200, 300]);
    });

    test('nothing is delivered twice once persistence is confirmed', () {
      final t = ExitTriage();
      final first = t.unreported(history);
      expect(first.length, 3);
      t.confirmPersisted(first);
      expect(t.watermarkMs, 300);
      expect(t.unreported(history), isEmpty);

      final later = [...history, rec(t: 400, reason: ExitReason.anr, pid: 4)];
      final second = t.unreported(later);
      expect(second.map((f) => f.record.timestampMs).toList(), [400]);
    });

    test('a crash between read and persist re-delivers, it does not skip', () {
      final t = ExitTriage();
      final batch = t.unreported(history);
      expect(batch.length, 3);
      // confirmPersisted deliberately NOT called: we died before writing.
      expect(t.watermarkMs, 0);
      expect(t.unreported(history).length, 3);
    });

    test('a partial confirmation only advances past what was persisted', () {
      final t = ExitTriage();
      final batch = t.unreported(history);
      t.confirmPersisted(batch.take(2).toList());
      expect(t.watermarkMs, 200);
      expect(t.unreported(history).map((f) => f.record.timestampMs).toList(),
          [300]);
    });

    test('the watermark never moves backwards', () {
      final t = ExitTriage(watermarkMs: 500);
      t.confirmPersisted(t.unreported(history));
      expect(t.watermarkMs, 500);
      final old = ExitTriage(watermarkMs: 500)
        ..confirmPersisted([
          ExitFinding(
            record: rec(t: 10, reason: ExitReason.anr),
            exitClass: ExitClass.anr,
            capturePipelineSuspect: true,
          )
        ]);
      expect(old.watermarkMs, 500);
    });

    test('ties on timestamp are broken deterministically by pid', () {
      final t = ExitTriage();
      final same = <ExitRecord>[
        rec(t: 700, reason: ExitReason.anr, pid: 9),
        rec(t: 700, reason: ExitReason.anr, pid: 2),
        rec(t: 700, reason: ExitReason.anr, pid: 5),
      ];
      expect(t.unreported(same).map((f) => f.record.pid).toList(), [2, 5, 9]);
    });
  });
}
