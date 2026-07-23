import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/reconstruction_route_release_gate.dart';

void main() {
  test(
    'release gate waits for worker teardown and pops exactly once',
    () async {
      final gate = ReconstructionRouteReleaseGate();
      final teardown = Completer<void>();
      final order = <String>[];
      var pops = 0;

      final first = gate.release(
        releaseResources: () async {
          order.add('release-start');
          await teardown.future;
          order.add('release-end');
        },
        revealRoot: () {
          order.add('pop');
          pops++;
        },
      );
      final duplicate = gate.release(
        releaseResources: () async => order.add('duplicate-release'),
        revealRoot: () => pops++,
      );

      expect(gate.isReleasing, isTrue);
      expect(pops, 0);
      expect(await duplicate, isFalse);

      teardown.complete();

      expect(await first, isTrue);
      expect(order, <String>['release-start', 'release-end', 'pop']);
      expect(pops, 1);
      expect(gate.isReleasing, isFalse);
    },
  );
}
