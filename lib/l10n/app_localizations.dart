import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppL10n
/// returned by `AppL10n.of(context)`.
///
/// Applications need to include `AppL10n.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppL10n.localizationsDelegates,
///   supportedLocales: AppL10n.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppL10n.supportedLocales
/// property.
abstract class AppL10n {
  AppL10n(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppL10n of(BuildContext context) {
    return Localizations.of<AppL10n>(context, AppL10n)!;
  }

  static const LocalizationsDelegate<AppL10n> delegate = _AppL10nDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// Brand wordmark — English
  ///
  /// In en, this message translates to:
  /// **'PocketWorld'**
  String get appBrand;

  /// No description provided for @splashSubtitle.
  ///
  /// In en, this message translates to:
  /// **'3D capture · minimalist workbench'**
  String get splashSubtitle;

  /// No description provided for @splashStartingEngine.
  ///
  /// In en, this message translates to:
  /// **'Starting 3D engine…'**
  String get splashStartingEngine;

  /// No description provided for @splashRestoringSession.
  ///
  /// In en, this message translates to:
  /// **'Restoring session…'**
  String get splashRestoringSession;

  /// No description provided for @splashPreparingSignIn.
  ///
  /// In en, this message translates to:
  /// **'Preparing sign-in…'**
  String get splashPreparingSignIn;

  /// No description provided for @splashWaking3DEngine.
  ///
  /// In en, this message translates to:
  /// **'Waking 3D engine…'**
  String get splashWaking3DEngine;

  /// No description provided for @splashRendererUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Renderer unavailable, retrying…'**
  String get splashRendererUnavailable;

  /// No description provided for @communityEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No works yet'**
  String get communityEmptyTitle;

  /// No description provided for @communitySearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search works'**
  String get communitySearchHint;

  /// No description provided for @communityTabHot.
  ///
  /// In en, this message translates to:
  /// **'Hot'**
  String get communityTabHot;

  /// No description provided for @communityTabNearby.
  ///
  /// In en, this message translates to:
  /// **'Nearby'**
  String get communityTabNearby;

  /// No description provided for @communityTabDiscover.
  ///
  /// In en, this message translates to:
  /// **'Discover'**
  String get communityTabDiscover;

  /// No description provided for @communityNearbyComingSoon.
  ///
  /// In en, this message translates to:
  /// **'Nearby is coming soon — stay tuned.'**
  String get communityNearbyComingSoon;

  /// No description provided for @meMyWorksEmpty.
  ///
  /// In en, this message translates to:
  /// **'No works yet — tap the camera to start your first capture.'**
  String get meMyWorksEmpty;

  /// No description provided for @scanLifecycleCompleted.
  ///
  /// In en, this message translates to:
  /// **'Completed'**
  String get scanLifecycleCompleted;

  /// No description provided for @createOptionCapture.
  ///
  /// In en, this message translates to:
  /// **'Capture'**
  String get createOptionCapture;

  /// No description provided for @createOptionUpload.
  ///
  /// In en, this message translates to:
  /// **'Upload'**
  String get createOptionUpload;

  /// No description provided for @createImportingGlb.
  ///
  /// In en, this message translates to:
  /// **'Importing GLB model…'**
  String get createImportingGlb;

  /// No description provided for @createImportPickerFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t open file picker: {error}'**
  String createImportPickerFailed(String error);

  /// No description provided for @createImportFileUnreadable.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t read the selected file'**
  String get createImportFileUnreadable;

  /// No description provided for @meTapHintInProgress.
  ///
  /// In en, this message translates to:
  /// **'Generating 3D model — opens when ready'**
  String get meTapHintInProgress;

  /// No description provided for @meActionRename.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get meActionRename;

  /// No description provided for @meActionDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get meActionDelete;

  /// No description provided for @meActionCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get meActionCancel;

  /// No description provided for @meActionSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get meActionSave;

  /// No description provided for @meRenameDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get meRenameDialogTitle;

  /// No description provided for @meDeleteDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete this scan?'**
  String get meDeleteDialogTitle;

  /// No description provided for @meDeleteDialogContent.
  ///
  /// In en, this message translates to:
  /// **'This will permanently delete \"{name}\" and all local original photos, point cloud, reconstruction databases, and caches. This action cannot be undone.'**
  String meDeleteDialogContent(String name);

  /// No description provided for @defaultUntitledScan.
  ///
  /// In en, this message translates to:
  /// **'Untitled'**
  String get defaultUntitledScan;

  /// No description provided for @captureWarmupHint.
  ///
  /// In en, this message translates to:
  /// **'Initializing AR…'**
  String get captureWarmupHint;

  /// No description provided for @captureReadyHint.
  ///
  /// In en, this message translates to:
  /// **'Tap the center button to aim'**
  String get captureReadyHint;

  /// No description provided for @captureAimHint.
  ///
  /// In en, this message translates to:
  /// **'Align the guide, then tap ✓ to lock and start'**
  String get captureAimHint;

  /// No description provided for @captureMaterialTooSparseHint.
  ///
  /// In en, this message translates to:
  /// **'Keep scanning a moment longer before stopping'**
  String get captureMaterialTooSparseHint;

  /// No description provided for @captureLockFailedHint.
  ///
  /// In en, this message translates to:
  /// **'Surface not detected or tracking not ready — point at the object\'s surface and try again'**
  String get captureLockFailedHint;

  /// No description provided for @captureInitFailed.
  ///
  /// In en, this message translates to:
  /// **'Initialization failed: {error}'**
  String captureInitFailed(String error);

  /// No description provided for @captureRecordingStartFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t start recording: {error}'**
  String captureRecordingStartFailed(String error);

  /// No description provided for @relativeJustNow.
  ///
  /// In en, this message translates to:
  /// **'just now'**
  String get relativeJustNow;

  /// No description provided for @relativeMinutesAgo.
  ///
  /// In en, this message translates to:
  /// **'{n} min ago'**
  String relativeMinutesAgo(int n);

  /// No description provided for @relativeHoursAgo.
  ///
  /// In en, this message translates to:
  /// **'{n} h ago'**
  String relativeHoursAgo(int n);

  /// No description provided for @relativeDaysAgo.
  ///
  /// In en, this message translates to:
  /// **'{n} d ago'**
  String relativeDaysAgo(int n);

  /// No description provided for @relativeWeeksAgo.
  ///
  /// In en, this message translates to:
  /// **'{n} w ago'**
  String relativeWeeksAgo(int n);

  /// No description provided for @relativeMonthsAgo.
  ///
  /// In en, this message translates to:
  /// **'{n} mo ago'**
  String relativeMonthsAgo(int n);

  /// No description provided for @meSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get meSettingsTitle;

  /// No description provided for @meNotifications.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get meNotifications;

  /// No description provided for @meNotificationsOn.
  ///
  /// In en, this message translates to:
  /// **'On'**
  String get meNotificationsOn;

  /// No description provided for @mePrivacy.
  ///
  /// In en, this message translates to:
  /// **'Privacy'**
  String get mePrivacy;

  /// No description provided for @meNotificationsOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get meNotificationsOff;

  /// No description provided for @mePrivacyPublic.
  ///
  /// In en, this message translates to:
  /// **'Public'**
  String get mePrivacyPublic;

  /// No description provided for @mePrivacyPrivate.
  ///
  /// In en, this message translates to:
  /// **'Private'**
  String get mePrivacyPrivate;

  /// No description provided for @meSettingNotConfigured.
  ///
  /// In en, this message translates to:
  /// **'Not configured'**
  String get meSettingNotConfigured;

  /// No description provided for @meLanguage.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get meLanguage;

  /// No description provided for @meLanguageZh.
  ///
  /// In en, this message translates to:
  /// **'简体中文'**
  String get meLanguageZh;

  /// No description provided for @meLanguageEn.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get meLanguageEn;

  /// No description provided for @meAbout.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get meAbout;

  /// No description provided for @meSignOut.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get meSignOut;

  /// No description provided for @meDetailRunningProcessing.
  ///
  /// In en, this message translates to:
  /// **'Processing'**
  String get meDetailRunningProcessing;

  /// No description provided for @meDetailRecordNotFound.
  ///
  /// In en, this message translates to:
  /// **'Record not found'**
  String get meDetailRecordNotFound;

  /// No description provided for @authWelcomeBack.
  ///
  /// In en, this message translates to:
  /// **'Welcome back'**
  String get authWelcomeBack;

  /// No description provided for @authCreateAccount.
  ///
  /// In en, this message translates to:
  /// **'Create your account'**
  String get authCreateAccount;

  /// No description provided for @authSignIn.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get authSignIn;

  /// No description provided for @authSignUp.
  ///
  /// In en, this message translates to:
  /// **'Sign up'**
  String get authSignUp;

  /// No description provided for @authEmailHint.
  ///
  /// In en, this message translates to:
  /// **'Email'**
  String get authEmailHint;

  /// No description provided for @authPasswordHint.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get authPasswordHint;

  /// No description provided for @authPasswordHintMin.
  ///
  /// In en, this message translates to:
  /// **'Set password (min 8 chars)'**
  String get authPasswordHintMin;

  /// No description provided for @authForgotPassword.
  ///
  /// In en, this message translates to:
  /// **'Forgot password?'**
  String get authForgotPassword;

  /// No description provided for @authTermsAcceptance.
  ///
  /// In en, this message translates to:
  /// **'By signing up you agree to PocketWorld\'s Terms of Service and Privacy Policy.'**
  String get authTermsAcceptance;

  /// No description provided for @authErrorDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong'**
  String get authErrorDialogTitle;

  /// No description provided for @otpVerifyTitle.
  ///
  /// In en, this message translates to:
  /// **'Verify your email'**
  String get otpVerifyTitle;

  /// No description provided for @otpVerifySubtitle.
  ///
  /// In en, this message translates to:
  /// **'We sent a 6-digit code to {email}. Enter it below to finish signing up.'**
  String otpVerifySubtitle(String email);

  /// No description provided for @otpResend.
  ///
  /// In en, this message translates to:
  /// **'Resend code'**
  String get otpResend;

  /// No description provided for @otpResendCooldown.
  ///
  /// In en, this message translates to:
  /// **'Resend in {seconds}s'**
  String otpResendCooldown(int seconds);

  /// No description provided for @otpResendSent.
  ///
  /// In en, this message translates to:
  /// **'Code re-sent'**
  String get otpResendSent;

  /// No description provided for @otpUseAnotherEmail.
  ///
  /// In en, this message translates to:
  /// **'Use a different email'**
  String get otpUseAnotherEmail;

  /// No description provided for @resetTitle.
  ///
  /// In en, this message translates to:
  /// **'Reset password'**
  String get resetTitle;

  /// No description provided for @resetSubtitleEnterCode.
  ///
  /// In en, this message translates to:
  /// **'We sent a 6-digit code to {email}. Enter it together with your new password.'**
  String resetSubtitleEnterCode(String email);

  /// No description provided for @resetSendCode.
  ///
  /// In en, this message translates to:
  /// **'Send code'**
  String get resetSendCode;

  /// No description provided for @resetNewPasswordHint.
  ///
  /// In en, this message translates to:
  /// **'New password (min 8 chars)'**
  String get resetNewPasswordHint;

  /// No description provided for @resetConfirm.
  ///
  /// In en, this message translates to:
  /// **'Reset password'**
  String get resetConfirm;

  /// No description provided for @captureModeLocal.
  ///
  /// In en, this message translates to:
  /// **'Local'**
  String get captureModeLocal;

  /// No description provided for @captureModeRemoteLegacy.
  ///
  /// In en, this message translates to:
  /// **'Remote'**
  String get captureModeRemoteLegacy;

  /// No description provided for @captureModeNewRemote.
  ///
  /// In en, this message translates to:
  /// **'New Remote'**
  String get captureModeNewRemote;

  /// No description provided for @languageDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get languageDialogTitle;

  /// No description provided for @languageDialogChinese.
  ///
  /// In en, this message translates to:
  /// **'简体中文 (Chinese)'**
  String get languageDialogChinese;

  /// No description provided for @languageDialogEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageDialogEnglish;

  /// No description provided for @commonCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get commonCancel;

  /// No description provided for @commonOk.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get commonOk;

  /// No description provided for @meTabProjects.
  ///
  /// In en, this message translates to:
  /// **'Projects'**
  String get meTabProjects;

  /// No description provided for @meTabDrafts.
  ///
  /// In en, this message translates to:
  /// **'Drafts'**
  String get meTabDrafts;

  /// No description provided for @defaultImportedScan.
  ///
  /// In en, this message translates to:
  /// **'Imported model'**
  String get defaultImportedScan;

  /// No description provided for @meDisplayName.
  ///
  /// In en, this message translates to:
  /// **'Display name'**
  String get meDisplayName;

  /// No description provided for @meDisplayNameDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit display name'**
  String get meDisplayNameDialogTitle;

  /// No description provided for @meDisplayNameDialogHint.
  ///
  /// In en, this message translates to:
  /// **'New display name (1-40 chars)'**
  String get meDisplayNameDialogHint;

  /// No description provided for @meDisplayNameUpdated.
  ///
  /// In en, this message translates to:
  /// **'Display name updated'**
  String get meDisplayNameUpdated;

  /// No description provided for @meDisplayNameUpdateFailed.
  ///
  /// In en, this message translates to:
  /// **'Update failed: {error}'**
  String meDisplayNameUpdateFailed(String error);

  /// No description provided for @sfmSaveDraft.
  ///
  /// In en, this message translates to:
  /// **'Save Draft'**
  String get sfmSaveDraft;

  /// No description provided for @sfmNext.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get sfmNext;

  /// No description provided for @sfmDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get sfmDone;

  /// No description provided for @sfmBackToDrafts.
  ///
  /// In en, this message translates to:
  /// **'Back to drafts'**
  String get sfmBackToDrafts;

  /// No description provided for @sfmGeneratingFinalCloud.
  ///
  /// In en, this message translates to:
  /// **'Generating final point cloud…'**
  String get sfmGeneratingFinalCloud;

  /// No description provided for @sfmReconFailedKeptFrames.
  ///
  /// In en, this message translates to:
  /// **'Reconstruction failed — captures kept'**
  String get sfmReconFailedKeptFrames;

  /// No description provided for @sfmChipFinalRecon.
  ///
  /// In en, this message translates to:
  /// **'Final reconstruction'**
  String get sfmChipFinalRecon;

  /// No description provided for @sfmChipReconstructing.
  ///
  /// In en, this message translates to:
  /// **'Reconstructing · {count} pts…'**
  String sfmChipReconstructing(int count);

  /// No description provided for @sfmChipReconDone.
  ///
  /// In en, this message translates to:
  /// **'Reconstruction complete · {count} pts'**
  String sfmChipReconDone(int count);

  /// No description provided for @sfmChipReconEnded.
  ///
  /// In en, this message translates to:
  /// **'Reconstruction ended'**
  String get sfmChipReconEnded;

  /// No description provided for @sfmQueueDrainedFinal.
  ///
  /// In en, this message translates to:
  /// **'Frame queue drained · generating final point cloud'**
  String get sfmQueueDrainedFinal;

  /// No description provided for @sfmProgressFedQueued.
  ///
  /// In en, this message translates to:
  /// **'Processed {fed} frames · {queued} remaining'**
  String sfmProgressFedQueued(int fed, int queued);

  /// No description provided for @sfmElapsedSec.
  ///
  /// In en, this message translates to:
  /// **'{secs}s'**
  String sfmElapsedSec(int secs);

  /// No description provided for @sfmElapsedMinSec.
  ///
  /// In en, this message translates to:
  /// **'{min}m {sec}s'**
  String sfmElapsedMinSec(int min, int sec);

  /// No description provided for @sfmStage1.
  ///
  /// In en, this message translates to:
  /// **'Organizing frames… (stage 1/4 · {elapsed})'**
  String sfmStage1(String elapsed);

  /// No description provided for @sfmStage2a.
  ///
  /// In en, this message translates to:
  /// **'Completing matches… (stage 2/4 · {elapsed})'**
  String sfmStage2a(String elapsed);

  /// No description provided for @sfmStage2b.
  ///
  /// In en, this message translates to:
  /// **'Global optimization… (stage 2/4 · {elapsed})'**
  String sfmStage2b(String elapsed);

  /// No description provided for @sfmStage3.
  ///
  /// In en, this message translates to:
  /// **'Extracting colors… (stage 3/4 · {elapsed})'**
  String sfmStage3(String elapsed);

  /// No description provided for @sfmStage4.
  ///
  /// In en, this message translates to:
  /// **'Saving point cloud… (stage 4/4 · {elapsed})'**
  String sfmStage4(String elapsed);

  /// No description provided for @viewerSparseCloudTitle.
  ///
  /// In en, this message translates to:
  /// **'Sparse Point Cloud'**
  String get viewerSparseCloudTitle;

  /// No description provided for @viewerTitleWithCount.
  ///
  /// In en, this message translates to:
  /// **'{title} · {count} pts'**
  String viewerTitleWithCount(String title, int count);

  /// No description provided for @viewerLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to load point cloud'**
  String get viewerLoadFailed;

  /// No description provided for @selectionRotatePointCloud.
  ///
  /// In en, this message translates to:
  /// **'Rotate Point Cloud'**
  String get selectionRotatePointCloud;

  /// No description provided for @selectionReadyToProcess.
  ///
  /// In en, this message translates to:
  /// **'Ready to Process'**
  String get selectionReadyToProcess;

  /// No description provided for @selectionDensifyComingSoon.
  ///
  /// In en, this message translates to:
  /// **'Dense processing coming soon'**
  String get selectionDensifyComingSoon;

  /// No description provided for @selectionNoCloud.
  ///
  /// In en, this message translates to:
  /// **'No point cloud data'**
  String get selectionNoCloud;

  /// No description provided for @cubeFaceTop.
  ///
  /// In en, this message translates to:
  /// **'Top'**
  String get cubeFaceTop;

  /// No description provided for @cubeFaceFront.
  ///
  /// In en, this message translates to:
  /// **'Front'**
  String get cubeFaceFront;

  /// No description provided for @cubeFaceRight.
  ///
  /// In en, this message translates to:
  /// **'Right'**
  String get cubeFaceRight;

  /// No description provided for @cubeFaceBack.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get cubeFaceBack;

  /// No description provided for @cubeFaceLeft.
  ///
  /// In en, this message translates to:
  /// **'Left'**
  String get cubeFaceLeft;

  /// No description provided for @cubeFaceBottom.
  ///
  /// In en, this message translates to:
  /// **'Bottom'**
  String get cubeFaceBottom;
}

class _AppL10nDelegate extends LocalizationsDelegate<AppL10n> {
  const _AppL10nDelegate();

  @override
  Future<AppL10n> load(Locale locale) {
    return SynchronousFuture<AppL10n>(lookupAppL10n(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppL10nDelegate old) => false;
}

AppL10n lookupAppL10n(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppL10nEn();
    case 'zh':
      return AppL10nZh();
  }

  throw FlutterError(
    'AppL10n.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
