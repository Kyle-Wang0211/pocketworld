// device_log.dart — release-visible on-device file log.
//
// Release builds swallow print/debugPrint (no VM service, debugPrint is a
// no-op), which made two field bugs undiagnosable. Standard from the device
// testing playbook: logs go to a CONTAINER FILE the app owns, the tester
// runs unplugged, and the file is pulled afterwards via
//   xcrun devicectl device copy from --domain-type appDataContainer \
//     --domain-identifier com.kyle.PocketWorld \
//     --source Documents/pw_device_log.txt ...
//
// Usage: `unawaited(DeviceLog.init())` once in main(); `DeviceLog.log(tag,
// message)` anywhere on the MAIN isolate afterwards. Worker isolates must
// NOT call this (platform channels / path cache live here) — they forward
// log lines over their reply port instead.

import 'dart:io';

import 'package:path_provider/path_provider.dart';

class DeviceLog {
  DeviceLog._();

  static File? _file;
  static bool _initFailed = false;
  static const int _maxBytes = 2 * 1024 * 1024; // rotate past 2 MB

  /// Resolves the log file under Documents. Safe to call more than once.
  /// Never throws — a failed init just disables file logging.
  static Future<void> init() async {
    if (_file != null || _initFailed) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/pw_device_log.txt');
      if (await f.exists() && (await f.length()) > _maxBytes) {
        // Single-slot rotation keeps the last generation for context.
        final old = File('${dir.path}/pw_device_log.1.txt');
        if (await old.exists()) await old.delete();
        await f.rename(old.path);
      }
      _file = f;
      log('DeviceLog', 'session start');
    } catch (_) {
      _initFailed = true;
    }
  }

  /// Appends one timestamped line. Fire-and-forget, never throws, and also
  /// mirrors to print() so attached debug runs still see everything.
  static void log(String tag, String message) {
    final line = '${DateTime.now().toIso8601String()} [$tag] $message';
    // ignore: avoid_print
    print(line);
    final f = _file;
    if (f == null) return;
    try {
      f.writeAsStringSync('$line\n', mode: FileMode.append, flush: false);
    } catch (_) {
      // Disk-full / sandbox hiccup — logging must never hurt the app.
    }
  }
}
