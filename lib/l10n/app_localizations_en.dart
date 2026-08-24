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
  String communityOnlyAuthor(String name) {
    return 'Only @$name';
  }

  @override
  String get communityClearAuthorFilter => 'Show all';

  @override
  String get communityTopicTitle => 'Editors\' Picks';

  @override
  String get communityTopicBody =>
      'Spaces we picked by hand. Want to be here? Publish what you scanned.';

  @override
  String get communityTopicCaptureTitle => 'Scan it better';

  @override
  String get communityTopicCaptureBody =>
      'Walk around it, go slow, don\'t shoot from one spot. Full coverage is what keeps the model from breaking up.';

  @override
  String get communityTopicViewerTitle => 'Tap to turn it';

  @override
  String get communityTopicViewerBody =>
      'Everything here is real 3D. Drag it and look again from another angle.';

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
    return 'This will permanently delete \"$name\" and all local original photos, point cloud, reconstruction databases, and caches. This action cannot be undone.';
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
  String get meBadgeGenerating => 'Generating';

  @override
  String get meBadgeUnfinished => 'Unfinished';

  @override
  String get meBadgeDone => 'Done';

  @override
  String get meTabDrafts => 'Drafts';

  @override
  String get defaultImportedScan => 'Imported model';

  @override
  String get meDisplayName => 'Display name';

  @override
  String get meDisplayNameDialogTitle => 'Edit display name';

  @override
  String get meDisplayNameDialogHint => 'New display name (up to 20 chars)';

  @override
  String get meDisplayNameUpdated => 'Display name updated';

  @override
  String meDisplayNameUpdateFailed(String error) {
    return 'Update failed: $error';
  }

  @override
  String get meAnalyticsTitle => 'Help improve the app';

  @override
  String get meToggleOn => 'On';

  @override
  String get meToggleOff => 'Off';

  @override
  String get legalUserAgreement => 'User Agreement';

  @override
  String get legalPrivacyPolicy => 'Privacy Policy';

  @override
  String get authTermsAcceptancePrefix => 'By signing up you agree to:';

  @override
  String get mePlatformRules => 'Platform Rules';

  @override
  String get meIpRegion => 'IP location';

  @override
  String get meIpRegionUnknown => 'Unknown';

  @override
  String ipRegionLabel(String region) {
    return 'IP location: $region';
  }

  @override
  String get authPhoneEntry => 'Sign in with phone';

  @override
  String get authPhoneNumberHint => 'Phone number (no country code)';

  @override
  String get authPhoneDisplayNameHint => 'Display name (optional)';

  @override
  String get authPhoneSendCode => 'Send code';

  @override
  String authPhoneWillSend(String target) {
    return 'We\'ll send a one-time code to $target. Standard SMS rates may apply.';
  }

  @override
  String authPhoneCodeSentTo(String phone) {
    return 'Code sent to $phone';
  }

  @override
  String get authPhoneCodeHint => '6-digit code';

  @override
  String get authPhoneSubmitSignIn => 'Sign in';

  @override
  String get authPhoneSubmitSignUp => 'Complete sign up';

  @override
  String get authPhoneChangeNumber => 'Use another number';

  @override
  String get authPhoneYourNumber => 'your phone';

  @override
  String get meHandle => 'Username';

  @override
  String get meHandleNotSet => 'Not set';

  @override
  String get meHandleDialogTitle => 'Set username';

  @override
  String get meHandleDialogHint => 'Lowercase letters, numbers, . and _ (2-32)';

  @override
  String get meHandleDialogNote =>
      'Your username is unique and lets people find you. It can only be changed once every 3 days.';

  @override
  String get meHandleUpdated => 'Username updated';

  @override
  String meHandleUpdateFailed(String error) {
    return 'Username update failed: $error';
  }

  @override
  String get sfmSaveDraft => 'Save Draft';

  @override
  String get sfmNext => 'Next';

  @override
  String get sfmDone => 'Done';

  @override
  String get sfmBackToDrafts => 'Back to drafts';

  @override
  String get sfmEditSelection => 'Edit selection';

  @override
  String get sfmSelectionSaveTitle => 'Save selection changes?';

  @override
  String get sfmSelectionSaveBody =>
      'You adjusted the selection box. Saving keeps only the points inside it in the preview and the delivered cloud.';

  @override
  String get sfmSelectionSaveKeep => 'Save';

  @override
  String get sfmSelectionSaveDiscard => 'Discard';

  @override
  String get sfmSelectionSaveCancel => 'Cancel';

  @override
  String get sfmGeneratingFinalCloud => 'Generating final point cloud…';

  @override
  String get captureFinishing => 'Wrapping up capture…';

  @override
  String get sfmReconFailedKeptFrames =>
      'Reconstruction failed — captures kept';

  @override
  String get sfmChipFinalRecon => 'Final reconstruction';

  @override
  String sfmChipReconstructing(int count) {
    return 'Reconstructing · $count pts…';
  }

  @override
  String sfmChipReconDone(int count) {
    return 'Reconstruction complete · $count pts';
  }

  @override
  String get sfmChipReconEnded => 'Reconstruction ended';

  @override
  String get sfmQueueDrainedFinal =>
      'Frame queue drained · generating final point cloud';

  @override
  String sfmProgressFedQueued(int fed, int queued) {
    return 'Completed $fed/$queued frames';
  }

  @override
  String sfmElapsedSec(int secs) {
    return '${secs}s';
  }

  @override
  String sfmElapsedMinSec(int min, int sec) {
    return '${min}m ${sec}s';
  }

  @override
  String sfmStage1(String elapsed) {
    return 'Organizing frames… (stage 1/4 · $elapsed)';
  }

  @override
  String sfmStage2a(String elapsed) {
    return 'Completing matches… (stage 2/4 · $elapsed)';
  }

  @override
  String sfmStage2b(String elapsed) {
    return 'Global optimization… (stage 2/4 · $elapsed)';
  }

  @override
  String sfmStage3(String elapsed) {
    return 'Extracting colors… (stage 3/4 · $elapsed)';
  }

  @override
  String sfmStage4(String elapsed) {
    return 'Saving point cloud… (stage 4/4 · $elapsed)';
  }

  @override
  String get viewerSparseCloudTitle => 'Sparse Point Cloud';

  @override
  String viewerTitleWithCount(String title, int count) {
    return '$title · $count pts';
  }

  @override
  String get viewerLoadFailed => 'Failed to load point cloud';

  @override
  String get selectionRotatePointCloud => 'Rotate';

  @override
  String get selectionNoCloud => 'No point cloud data';

  @override
  String get cubeFaceTop => 'Top';

  @override
  String get cubeFaceFront => 'Front';

  @override
  String get cubeFaceRight => 'Right';

  @override
  String get cubeFaceBack => 'Back';

  @override
  String get cubeFaceLeft => 'Left';

  @override
  String get cubeFaceBottom => 'Bottom';

  @override
  String get denseStageUnavailable =>
      'Processing is not available on this device yet';

  @override
  String get selectionCancel => 'Cancel';

  @override
  String get selectionDiscardTitle => 'Discard changes?';

  @override
  String get selectionDiscardConfirm => 'Discard Changes';

  @override
  String get selectionResetRotation => 'Reset Rotation';

  @override
  String get selectionResetZoom => 'Reset Zoom';

  @override
  String get selectionResetBoxSize => 'Reset Box Size';

  @override
  String get publishAction => 'Publish to Community';

  @override
  String get publishNotReady => 'Available after reconstruction';

  @override
  String get publishAlreadyDone => 'Published';

  @override
  String get publishSheetSubtitle =>
      'Once published, anyone can see this work in the community.';

  @override
  String get publishFieldTitle => 'Title';

  @override
  String get publishFieldDescription => 'Description (optional)';

  @override
  String get publishConfirm => 'Publish';

  @override
  String get publishInProgress => 'Publishing';

  @override
  String get publishSuccess => 'Published to community';

  @override
  String get publishErrSignedOut => 'Sign in before publishing';

  @override
  String get publishErrAlreadyPublished => 'This work is already published';

  @override
  String get publishErrReading => 'Could not read the point cloud';

  @override
  String get publishErrUploading =>
      'Upload failed — check your connection and retry';

  @override
  String get publishErrTooLarge =>
      'This scan exceeds the upload size limit — retrying will not help. Please capture a smaller area and regenerate.';

  @override
  String get publishErrRejected =>
      'This file failed server-side validation and may be corrupted. Please regenerate the scan.';

  @override
  String get publishErrInserting =>
      'Could not save the publication, please retry';

  @override
  String get publishErrGeneric => 'Publish failed';

  @override
  String get communityCloudLoadFailed => 'Could not load the point cloud';

  @override
  String get communityRetry => 'Retry';

  @override
  String get communityFormatUnsupported =>
      'This format cannot be previewed in this version';

  @override
  String get communityPointsSuffix => 'points';

  @override
  String get meDeleteAccount => 'Delete account';

  @override
  String get meDeleteAccountDialogTitle => 'Permanently delete your account?';

  @override
  String get meDeleteAccountDialogBody =>
      'Your account, published works and all cloud data will be permanently deleted. This cannot be undone. Captures stored on this device are not affected.';

  @override
  String get meDeleteAccountConfirm => 'Delete permanently';

  @override
  String get meDeleteAccountFailed =>
      'Deletion failed. Please try again later.';

  @override
  String get publishModerationUnderReview => 'Under review';

  @override
  String get publishModerationRemoved => 'Removed';

  @override
  String get publishModerationRemovedHint =>
      'This work was removed for violating the community guidelines and is not visible to others. To appeal, use the contact details on the Settings page.';

  @override
  String get workMoreActions => 'More';

  @override
  String get reportAction => 'Report';

  @override
  String get reportSheetTitle => 'Report this work';

  @override
  String get reportSheetSubtitle =>
      'Pick a reason and we\'ll review it promptly.';

  @override
  String get reportReasonSpam => 'Spam or advertising';

  @override
  String get reportReasonHarassment => 'Harassment or bullying';

  @override
  String get reportReasonHateSpeech => 'Hate speech';

  @override
  String get reportReasonSexualContent => 'Sexual content';

  @override
  String get reportReasonViolence => 'Violence or gore';

  @override
  String get reportReasonCopyright => 'Copyright infringement';

  @override
  String get reportReasonMisinformation => 'Misinformation';

  @override
  String get reportReasonOther => 'Other';

  @override
  String get reportDetailHint => 'Additional details (optional)';

  @override
  String get reportSubmit => 'Submit report';

  @override
  String get reportSubmitted => 'Report submitted. We\'ll review it promptly.';

  @override
  String get reportFailed =>
      'Couldn\'t submit the report. Please try again later.';

  @override
  String get blockAction => 'Block this user';

  @override
  String get blockDialogTitle => 'Block this user?';

  @override
  String get blockDialogBody =>
      'You won\'t see their works anymore, and any follow relationship between you will be removed.';

  @override
  String get blockConfirm => 'Block';

  @override
  String get blockDone => 'Blocked. Their works will no longer appear.';

  @override
  String get blockFailed => 'Action failed. Please try again later.';

  @override
  String get workDeleteAction => 'Remove from community';

  @override
  String get workDeleteDialogTitle => 'Remove this work from the community?';

  @override
  String get workDeleteDialogBody =>
      'The work will be removed from the community and its cloud files deleted. This cannot be undone. Your original capture on this device is unaffected and can be published again later.';

  @override
  String get workDeleteConfirm => 'Remove';

  @override
  String get workDeleteDone => 'Removed from the community';

  @override
  String get workDeleteFailed => 'Removal failed. Please try again later.';
}
