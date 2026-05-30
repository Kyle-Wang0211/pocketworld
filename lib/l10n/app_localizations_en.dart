// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppL10nEn extends AppL10n {
  AppL10nEn([String locale = 'en']) : super(locale);

  @override
  String get appBrand => 'PocketWorld';

  @override
  String get splashSubtitle => '3D capture · minimalist workbench';

  @override
  String get splashStartingEngine => 'Starting 3D engine…';

  @override
  String get splashRestoringSession => 'Restoring session…';

  @override
  String get splashPreparingSignIn => 'Preparing sign-in…';

  @override
  String get splashWaking3DEngine => 'Waking 3D engine…';

  @override
  String get splashRendererUnavailable => 'Renderer unavailable, retrying…';

  @override
  String get communityEmptyTitle => 'No works yet';

  @override
  String get communitySearchHint => 'Search works';

  @override
  String get communityTabHot => 'Hot';

  @override
  String get communityTabNearby => 'Nearby';

  @override
  String get communityTabDiscover => 'Discover';

  @override
  String get communityNearbyComingSoon => 'Nearby is coming soon — stay tuned.';

  @override
  String get meMyWorksEmpty =>
      'No works yet — tap the camera to start your first capture.';

  @override
  String get scanLifecycleCompleted => 'Completed';

  @override
  String get createOptionCapture => 'Capture';

  @override
  String get createOptionUpload => 'Upload';

  @override
  String get createImportingGlb => 'Importing GLB model…';

  @override
  String createImportPickerFailed(String error) {
    return 'Couldn\'t open file picker: $error';
  }

  @override
  String get createImportFileUnreadable => 'Couldn\'t read the selected file';

  @override
  String get meTapHintInProgress => 'Generating 3D model — opens when ready';

  @override
  String get meActionRename => 'Rename';

  @override
  String get meActionDelete => 'Delete';

  @override
  String get meActionCancel => 'Cancel';

  @override
  String get meActionSave => 'Save';

  @override
  String get meRenameDialogTitle => 'Rename';

  @override
  String get meDeleteDialogTitle => 'Delete this scan?';

  @override
  String meDeleteDialogContent(String name) {
    return '\"$name\" will be removed from your works. Items already published to the community are unaffected.';
  }

  @override
  String get defaultUntitledScan => 'Untitled';

  @override
  String get captureWarmupHint => 'Initializing AR…';

  @override
  String get captureReadyHint => 'Tap the center button to aim';

  @override
  String get captureAimHint => 'Align the guide, then tap ✓ to lock and start';

  @override
  String get captureMaterialTooSparseHint =>
      'Keep scanning a moment longer before stopping';

  @override
  String get captureLockFailedHint =>
      'Surface not detected or tracking not ready — point at the object\'s surface and try again';

  @override
  String captureInitFailed(String error) {
    return 'Initialization failed: $error';
  }

  @override
  String captureRecordingStartFailed(String error) {
    return 'Couldn\'t start recording: $error';
  }

  @override
  String get relativeJustNow => 'just now';

  @override
  String relativeMinutesAgo(int n) {
    return '$n min ago';
  }

  @override
  String relativeHoursAgo(int n) {
    return '$n h ago';
  }

  @override
  String relativeDaysAgo(int n) {
    return '$n d ago';
  }

  @override
  String relativeWeeksAgo(int n) {
    return '$n w ago';
  }

  @override
  String relativeMonthsAgo(int n) {
    return '$n mo ago';
  }

  @override
  String get meSettingsTitle => 'Settings';

  @override
  String get meNotifications => 'Notifications';

  @override
  String get meNotificationsOn => 'On';

  @override
  String get mePrivacy => 'Privacy';

  @override
  String get meNotificationsOff => 'Off';

  @override
  String get mePrivacyPublic => 'Public';

  @override
  String get mePrivacyPrivate => 'Private';

  @override
  String get meSettingNotConfigured => 'Not configured';

  @override
  String get meLanguage => 'Language';

  @override
  String get meLanguageZh => '简体中文';

  @override
  String get meLanguageEn => 'English';

  @override
  String get meAbout => 'About';

  @override
  String get meSignOut => 'Sign out';

  @override
  String get meDetailRunningProcessing => 'Processing';

  @override
  String get meDetailRecordNotFound => 'Record not found';

  @override
  String get authWelcomeBack => 'Welcome back';

  @override
  String get authCreateAccount => 'Create your account';

  @override
  String get authSignIn => 'Sign in';

  @override
  String get authSignUp => 'Sign up';

  @override
  String get authEmailHint => 'Email';

  @override
  String get authPasswordHint => 'Password';

  @override
  String get authPasswordHintMin => 'Set password (min 8 chars)';

  @override
  String get authForgotPassword => 'Forgot password?';

  @override
  String get authTermsAcceptance =>
      'By signing up you agree to PocketWorld\'s Terms of Service and Privacy Policy.';

  @override
  String get authErrorDialogTitle => 'Something went wrong';

  @override
  String get otpVerifyTitle => 'Verify your email';

  @override
  String otpVerifySubtitle(String email) {
    return 'We sent a 6-digit code to $email. Enter it below to finish signing up.';
  }

  @override
  String get otpResend => 'Resend code';

  @override
  String otpResendCooldown(int seconds) {
    return 'Resend in ${seconds}s';
  }

  @override
  String get otpResendSent => 'Code re-sent';

  @override
  String get otpUseAnotherEmail => 'Use a different email';

  @override
  String get resetTitle => 'Reset password';

  @override
  String resetSubtitleEnterCode(String email) {
    return 'We sent a 6-digit code to $email. Enter it together with your new password.';
  }

  @override
  String get resetSendCode => 'Send code';

  @override
  String get resetNewPasswordHint => 'New password (min 8 chars)';

  @override
  String get resetConfirm => 'Reset password';

  @override
  String get captureModeLocal => 'Local';

  @override
  String get captureModeRemoteLegacy => 'Remote';

  @override
  String get captureModeNewRemote => 'New Remote';

  @override
  String get languageDialogTitle => 'Language';

  @override
  String get languageDialogChinese => '简体中文 (Chinese)';

  @override
  String get languageDialogEnglish => 'English';

  @override
  String get commonCancel => 'Cancel';

  @override
  String get commonOk => 'OK';

  @override
  String get meTabProjects => 'Projects';

  @override
  String get meTabDrafts => 'Drafts';

  @override
  String get defaultImportedScan => 'Imported model';

  @override
  String get meDisplayName => 'Display name';

  @override
  String get meDisplayNameDialogTitle => 'Edit display name';

  @override
  String get meDisplayNameDialogHint => 'New display name (1-40 chars)';

  @override
  String get meDisplayNameUpdated => 'Display name updated';

  @override
  String meDisplayNameUpdateFailed(String error) {
    return 'Update failed: $error';
  }
}
