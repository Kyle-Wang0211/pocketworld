// Independent native-library resolver for the "官方" capture stack.
//
// The self-developed stack resolves symbols from the process image. This
// resolver intentionally does not: it opens only the embedded
// PWOfficialSfm.framework/PWOfficialSfm binary, validates an official-prefixed
// ABI symbol, and fails closed when that framework is absent or incomplete.

import 'dart:ffi';
import 'dart:io';

/// FFI lookup or call failed. Carries a human-readable reason; not meant
/// to be caught and recovered from — surfaced to UI for diagnosis.
class OfficialFfiResolutionError implements Exception {
  final String message;
  const OfficialFfiResolutionError(this.message);
  @override
  String toString() => 'OfficialFfiResolutionError: $message';
}

typedef _OfficialOptionsDefaultProbe = Void Function(Pointer<Void>);

/// Static-only namespace for the official capture framework.
class OfficialAetherFfi {
  OfficialAetherFfi._();

  static DynamicLibrary? _cachedLibrary;

  static List<String> _candidateLibraryPaths() {
    final candidates = <String>[];
    final seen = <String>{};

    void add(String path) {
      if (path.isEmpty) return;
      final normalized = File(path).absolute.path;
      if (!normalized.endsWith('/PWOfficialSfm.framework/PWOfficialSfm')) {
        return;
      }
      if (seen.add(normalized)) {
        candidates.add(normalized);
      }
    }

    add(Platform.environment['PW_OFFICIAL_SFM_FRAMEWORK'] ?? '');
    final executableDir = File(Platform.resolvedExecutable).absolute.parent;
    // iOS: Runner.app/Runner -> Runner.app/Frameworks/...
    add(
      '${executableDir.path}/Frameworks/'
      'PWOfficialSfm.framework/PWOfficialSfm',
    );
    // macOS: Runner.app/Contents/MacOS/Runner -> Contents/Frameworks/...
    add(
      '${executableDir.parent.path}/Frameworks/'
      'PWOfficialSfm.framework/PWOfficialSfm',
    );
    return candidates;
  }

  static DynamicLibrary _resolveLibrary() {
    if (_cachedLibrary != null) return _cachedLibrary!;

    Object? lastOpenError;
    final existingCandidates = <String>[];
    for (final path in _candidateLibraryPaths()) {
      if (!File(path).existsSync()) continue;
      existingCandidates.add(path);
      try {
        final lib = DynamicLibrary.open(path);
        lib.lookup<NativeFunction<_OfficialOptionsDefaultProbe>>(
          'pwofficial_options_default',
        );
        _cachedLibrary = lib;
        return lib;
      } catch (e) {
        lastOpenError = e;
      }
    }

    final searched = existingCandidates.isEmpty
        ? 'no embedded PWOfficialSfm framework candidate exists'
        : existingCandidates.join(', ');
    throw OfficialFfiResolutionError(
      'Failed to open PWOfficialSfm.framework/PWOfficialSfm with the '
      'pwofficial ABI. searched=$searched; lastOpenError=$lastOpenError',
    );
  }

  static DynamicLibrary resolveLibraryForBindings() => _resolveLibrary();
}
