import 'dart:async';

import 'official_highres_reconstruction_input.dart';

/// Operational liveness ceiling for one native high-resolution transaction.
/// It is not a photographic cadence or selection parameter.
const Duration kOfficialHighResTerminalTimeout = Duration(seconds: 8);

Future<T> awaitOfficialHighResTerminal<T>(
  Future<T> operation, {
  Duration timeout = kOfficialHighResTerminalTimeout,
  FutureOr<void> Function(T value)? onLateCompletion,
}) async {
  if (timeout <= Duration.zero) {
    throw ArgumentError.value(timeout, 'timeout', 'must be positive');
  }
  var expired = false;
  if (onLateCompletion != null) {
    operation.then<void>((value) {
      if (!expired) return;
      unawaited(
        Future<void>.sync(() => onLateCompletion(value)).catchError((_) {}),
      );
    }, onError: (_, _) {});
  }
  return operation.timeout(
    timeout,
    onTimeout: () {
      expired = true;
      throw OfficialHighResCaptureException(
        OfficialHighResInputFailure.captureTimedOut,
        message:
            'native high-resolution transaction did not terminate within '
            '${timeout.inMilliseconds} ms',
      );
    },
  );
}
