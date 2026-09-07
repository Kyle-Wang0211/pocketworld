import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('staging upload does not request upsert without a SELECT policy', () {
    final source = File(
      'lib/community/publish_service.dart',
    ).readAsStringSync();
    final uploadStart = source.indexOf("from('staging').uploadBinary(");
    final finalizeStart = source.indexOf("c.functions.invoke(", uploadStart);

    expect(uploadStart, greaterThanOrEqualTo(0));
    expect(finalizeStart, greaterThan(uploadStart));
    final uploadBlock = source.substring(uploadStart, finalizeStart);
    expect(
      uploadBlock,
      isNot(contains('upsert: true')),
      reason: 'staging intentionally has no SELECT policy; Supabase upsert '
          'returns RLS 403 even for a new owner-scoped path',
    );
  });

  test('an already-landed staging object still proceeds to finalize', () {
    final source = File(
      'lib/community/publish_service.dart',
    ).readAsStringSync();
    final uploadStart = source.indexOf("from('staging').uploadBinary(");
    final finalizeStart = source.indexOf("c.functions.invoke(", uploadStart);
    final uploadBlock = source.substring(uploadStart, finalizeStart);

    expect(uploadBlock, contains('StorageException'));
    expect(uploadBlock, contains("statusCode != '409'"));
  });
}
