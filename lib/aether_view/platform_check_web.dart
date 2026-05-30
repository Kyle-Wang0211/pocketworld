// Web variant of `kAetherSceneBridgeAvailable`'s platform probe.
// Always false until G8's Web wiring lands (Dawn emscripten + a
// canvas-backed Flutter texture). See platform_check_io.dart for the
// conditional-import pattern that picks between this and the dart:io
// variant.

bool aetherSceneBridgeAvailableForPlatform() => false;
