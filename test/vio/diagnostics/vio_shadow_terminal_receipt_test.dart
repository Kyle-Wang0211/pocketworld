import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/diagnostics/vio_shadow_health.dart';

Map<String, Object?> validReceipt() => <String, Object?>{
  'receiptAvailable': true,
  'state': 'stopped',
  'sessionGeneration': 9,
  'nativeStartLifecycleGeneration': 17,
  'nativeLifecycleGeneration': 17,
  'nativeDestroyRc': 0,
  'nativeDestroyAcknowledged': 1,
  'terminalReceiptComplete': true,
  'workConserved': true,
  'ingressClosed': true,
  'ingressOffered': 15,
  'ingressCompleted': 15,
  'terminalIngressSequence': 15,
  'shadowRunInvalidated': false,
  'transportValid': true,
  'runCalls': 3,
  'imagesSubmitted': 3,
  'accSubmitted': 5,
  'gyroSubmitted': 7,
  'nativeCameraSubmitted': 3,
  'nativeCameraRunCalls': 3,
  'nativeAccelerationSubmitted': 5,
  'nativeGyroscopeSubmitted': 7,
  'nativeRejectedInvalidArgument': 0,
  'nativeRejectedNonMonotonic': 0,
  'nativeRejectedNotRunning': 0,
};

void main() {
  test('accepts one exact native terminal receipt', () {
    final VioShadowNativeTerminalReceipt receipt =
        VioShadowNativeTerminalReceipt.fromWire(validReceipt());
    expect(receipt.schemaValid, isTrue);
    expect(receipt.countersMatch, isTrue);
    expect(receipt.accepted, isTrue);
  });

  test('every terminal authority field fails closed', () {
    final Map<String, Object?> invalidValues = <String, Object?>{
      'receiptAvailable': false,
      'state': 'running',
      'nativeStartLifecycleGeneration': 18,
      'nativeDestroyRc': -2,
      'nativeDestroyAcknowledged': 0,
      'terminalReceiptComplete': false,
      'workConserved': false,
      'ingressClosed': false,
      'ingressCompleted': 14,
      'shadowRunInvalidated': true,
      'transportValid': false,
      'nativeCameraSubmitted': 2,
      'nativeCameraRunCalls': 2,
      'nativeAccelerationSubmitted': 4,
      'nativeGyroscopeSubmitted': 6,
    };
    for (final MapEntry<String, Object?> mutation in invalidValues.entries) {
      final Map<String, Object?> wire = validReceipt()
        ..[mutation.key] = mutation.value;
      expect(
        VioShadowNativeTerminalReceipt.fromWire(wire).accepted,
        isFalse,
        reason: mutation.key,
      );
    }
  });

  test('unavailable and stopped-looking generic snapshots are rejected', () {
    final Map<String, Object?> unavailable = validReceipt()
      ..['receiptAvailable'] = false;
    final Map<String, Object?> generic = validReceipt()
      ..remove('nativeDestroyRc')
      ..remove('nativeDestroyAcknowledged');
    expect(
      VioShadowNativeTerminalReceipt.fromWire(unavailable).accepted,
      isFalse,
    );
    expect(VioShadowNativeTerminalReceipt.fromWire(generic).accepted, isFalse);
  });
}
