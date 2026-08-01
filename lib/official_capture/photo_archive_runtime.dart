import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'archive_audit_store.dart';
import 'archive_background_runtime.dart';
import 'database_archive_codec.dart';
import 'database_archive_ffi_codec.dart';
import 'database_archive_ffi_preprocessor.dart';
import 'database_archive_preprocessor.dart';
import 'photo_archive_codec.dart';
import 'photo_archive_coordinator.dart';
import 'photo_archive_ffi_codec.dart';

final PhotoArchiveCodec photoArchiveCodec = JxlFfiPhotoArchiveCodec();
final DatabaseArchiveCodec databaseArchiveCodec = ZpaqFfiDatabaseArchiveCodec();
final DatabaseArchivePreprocessor databaseArchivePreprocessor =
    TrackDeltaFfiDatabaseArchivePreprocessor();

const MethodChannel officialArchiveBackgroundChannel = MethodChannel(
  'pocketworld_official_archive_background',
);
final MethodChannelArchiveBackgroundScheduler archiveBackgroundScheduler =
    MethodChannelArchiveBackgroundScheduler(
      channel: officialArchiveBackgroundChannel,
    );
final OfficialArchiveAuditStore officialArchiveAuditStore =
    OfficialArchiveAuditStore(
      documentsDirectory: getApplicationDocumentsDirectory,
    );

final PhotoArchiveCoordinator photoArchiveCoordinator = PhotoArchiveCoordinator(
  codec: photoArchiveCodec,
  databaseCodec: databaseArchiveCodec,
  databasePreprocessor: databaseArchivePreprocessor,
  backgroundScheduler: archiveBackgroundScheduler,
  auditStore: officialArchiveAuditStore,
);

final OfficialArchiveBackgroundRuntime officialArchiveBackgroundRuntime =
    OfficialArchiveBackgroundRuntime(
      channel: officialArchiveBackgroundChannel,
      coordinator: photoArchiveCoordinator,
      documentsDirectory: getApplicationDocumentsDirectory,
    );
