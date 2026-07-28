import 'photo_archive_codec.dart';
import 'photo_archive_coordinator.dart';
import 'photo_archive_ffi_codec.dart';

final PhotoArchiveCodec photoArchiveCodec = JxlFfiPhotoArchiveCodec();

final PhotoArchiveCoordinator photoArchiveCoordinator = PhotoArchiveCoordinator(
  codec: photoArchiveCodec,
);
