const String kVioShadowMode = String.fromEnvironment(
  'PW_VIO_SHADOW',
  defaultValue: 'on',
);

bool get kVioShadowEnabled => kVioShadowMode != 'off';
