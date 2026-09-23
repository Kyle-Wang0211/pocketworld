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

  /// No description provided for @communityOnlyAuthor.
  ///
  /// In en, this message translates to:
  /// **'Only @{name}'**
  String communityOnlyAuthor(String name);

  /// No description provided for @communityClearAuthorFilter.
  ///
  /// In en, this message translates to:
  /// **'Show all'**
  String get communityClearAuthorFilter;

  /// No description provided for @communityTopicTitle.
  ///
  /// In en, this message translates to:
  /// **'Editors\' Picks'**
  String get communityTopicTitle;

  /// No description provided for @communityTopicBody.
  ///
  /// In en, this message translates to:
  /// **'Spaces we picked by hand. Want to be here? Publish what you scanned.'**
  String get communityTopicBody;

  /// No description provided for @communityTopicCaptureTitle.
  ///
  /// In en, this message translates to:
  /// **'Scan it better'**
  String get communityTopicCaptureTitle;

  /// No description provided for @communityTopicCaptureBody.
  ///
  /// In en, this message translates to:
  /// **'Walk around it, go slow, don\'t shoot from one spot. Full coverage is what keeps the model from breaking up.'**
  String get communityTopicCaptureBody;

  /// No description provided for @communityTopicViewerTitle.
  ///
  /// In en, this message translates to:
  /// **'Tap to turn it'**
  String get communityTopicViewerTitle;

  /// No description provided for @communityTopicViewerBody.
  ///
  /// In en, this message translates to:
  /// **'Everything here is real 3D. Drag it and look again from another angle.'**
  String get communityTopicViewerBody;

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

  /// No description provided for @meBadgeGenerating.
  ///
  /// In en, this message translates to:
  /// **'Generating'**
  String get meBadgeGenerating;

  /// No description provided for @meBadgeUnfinished.
  ///
  /// In en, this message translates to:
  /// **'Unfinished'**
  String get meBadgeUnfinished;

  /// No description provided for @meBadgeDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get meBadgeDone;

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
  /// **'New display name (up to 20 chars)'**
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

  /// No description provided for @meAnalyticsTitle.
  ///
  /// In en, this message translates to:
  /// **'Help improve the app'**
  String get meAnalyticsTitle;

  /// No description provided for @meToggleOn.
  ///
  /// In en, this message translates to:
  /// **'On'**
  String get meToggleOn;

  /// No description provided for @meToggleOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get meToggleOff;

  /// No description provided for @legalUserAgreement.
  ///
  /// In en, this message translates to:
  /// **'User Agreement'**
  String get legalUserAgreement;

  /// No description provided for @legalPrivacyPolicy.
  ///
  /// In en, this message translates to:
  /// **'Privacy Policy'**
  String get legalPrivacyPolicy;

  /// No description provided for @authTermsAcceptancePrefix.
  ///
  /// In en, this message translates to:
  /// **'By signing up you agree to:'**
  String get authTermsAcceptancePrefix;

  /// No description provided for @mePlatformRules.
  ///
  /// In en, this message translates to:
  /// **'Platform Rules'**
  String get mePlatformRules;

  /// No description provided for @meIpRegion.
  ///
  /// In en, this message translates to:
  /// **'IP location'**
  String get meIpRegion;

  /// No description provided for @meIpRegionUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get meIpRegionUnknown;

  /// No description provided for @ipRegionLabel.
  ///
  /// In en, this message translates to:
  /// **'IP location: {region}'**
  String ipRegionLabel(String region);

  /// No description provided for @authPhoneEntry.
  ///
  /// In en, this message translates to:
  /// **'Sign in with phone'**
  String get authPhoneEntry;

  /// No description provided for @authPhoneNumberHint.
  ///
  /// In en, this message translates to:
  /// **'Phone number (no country code)'**
  String get authPhoneNumberHint;

  /// No description provided for @authPhoneDisplayNameHint.
  ///
  /// In en, this message translates to:
  /// **'Display name (optional)'**
  String get authPhoneDisplayNameHint;

  /// No description provided for @authPhoneSendCode.
  ///
  /// In en, this message translates to:
  /// **'Send code'**
  String get authPhoneSendCode;

  /// No description provided for @authPhoneWillSend.
  ///
  /// In en, this message translates to:
  /// **'We\'ll send a one-time code to {target}. Standard SMS rates may apply.'**
  String authPhoneWillSend(String target);

  /// No description provided for @authPhoneCodeSentTo.
  ///
  /// In en, this message translates to:
  /// **'Code sent to {phone}'**
  String authPhoneCodeSentTo(String phone);

  /// No description provided for @authPhoneCodeHint.
  ///
  /// In en, this message translates to:
  /// **'6-digit code'**
  String get authPhoneCodeHint;

  /// No description provided for @authPhoneSubmitSignIn.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get authPhoneSubmitSignIn;

  /// No description provided for @authPhoneSubmitSignUp.
  ///
  /// In en, this message translates to:
  /// **'Complete sign up'**
  String get authPhoneSubmitSignUp;

  /// No description provided for @authPhoneChangeNumber.
  ///
  /// In en, this message translates to:
  /// **'Use another number'**
  String get authPhoneChangeNumber;

  /// No description provided for @authPhoneYourNumber.
  ///
  /// In en, this message translates to:
  /// **'your phone'**
  String get authPhoneYourNumber;

  /// No description provided for @meHandle.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get meHandle;

  /// No description provided for @meHandleNotSet.
  ///
  /// In en, this message translates to:
  /// **'Not set'**
  String get meHandleNotSet;

  /// No description provided for @meHandleDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Set username'**
  String get meHandleDialogTitle;

  /// No description provided for @meHandleDialogHint.
  ///
  /// In en, this message translates to:
  /// **'Lowercase letters, numbers, . and _ (2-32)'**
  String get meHandleDialogHint;

  /// No description provided for @meHandleDialogNote.
  ///
  /// In en, this message translates to:
  /// **'Your username is unique and lets people find you. It can only be changed once every 3 days.'**
  String get meHandleDialogNote;

  /// No description provided for @meHandleUpdated.
  ///
  /// In en, this message translates to:
  /// **'Username updated'**
  String get meHandleUpdated;

  /// No description provided for @meHandleUpdateFailed.
  ///
  /// In en, this message translates to:
  /// **'Username update failed: {error}'**
  String meHandleUpdateFailed(String error);

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

  /// No description provided for @sfmEditSelection.
  ///
  /// In en, this message translates to:
  /// **'Edit selection'**
  String get sfmEditSelection;

  /// No description provided for @sfmSelectionSaveTitle.
  ///
  /// In en, this message translates to:
  /// **'Save selection changes?'**
  String get sfmSelectionSaveTitle;

  /// No description provided for @sfmSelectionSaveBody.
  ///
  /// In en, this message translates to:
  /// **'You adjusted the selection box. Saving keeps only the points inside it in the preview and the delivered cloud.'**
  String get sfmSelectionSaveBody;

  /// No description provided for @sfmSelectionSaveKeep.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get sfmSelectionSaveKeep;

  /// No description provided for @sfmSelectionSaveDiscard.
  ///
  /// In en, this message translates to:
  /// **'Discard'**
  String get sfmSelectionSaveDiscard;

  /// No description provided for @sfmSelectionSaveCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get sfmSelectionSaveCancel;

  /// No description provided for @sfmGeneratingFinalCloud.
  ///
  /// In en, this message translates to:
  /// **'Generating final point cloud…'**
  String get sfmGeneratingFinalCloud;

  /// No description provided for @captureFinishing.
  ///
  /// In en, this message translates to:
  /// **'Wrapping up capture…'**
  String get captureFinishing;

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
  /// **'Completed {fed}/{queued} frames'**
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
  /// **'Rotate'**
  String get selectionRotatePointCloud;

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

  /// No description provided for @denseStageUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Processing is not available on this device yet'**
  String get denseStageUnavailable;

  /// No description provided for @selectionCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get selectionCancel;

  /// No description provided for @selectionDiscardTitle.
  ///
  /// In en, this message translates to:
  /// **'Discard changes?'**
  String get selectionDiscardTitle;

  /// No description provided for @selectionDiscardConfirm.
  ///
  /// In en, this message translates to:
  /// **'Discard Changes'**
  String get selectionDiscardConfirm;

  /// No description provided for @selectionResetRotation.
  ///
  /// In en, this message translates to:
  /// **'Reset Rotation'**
  String get selectionResetRotation;

  /// No description provided for @selectionResetZoom.
  ///
  /// In en, this message translates to:
  /// **'Reset Zoom'**
  String get selectionResetZoom;

  /// No description provided for @selectionResetBoxSize.
  ///
  /// In en, this message translates to:
  /// **'Reset Box Size'**
  String get selectionResetBoxSize;

  /// No description provided for @publishAction.
  ///
  /// In en, this message translates to:
  /// **'Publish to Community'**
  String get publishAction;

  /// No description provided for @publishNotReady.
  ///
  /// In en, this message translates to:
  /// **'Available after reconstruction'**
  String get publishNotReady;

  /// No description provided for @publishAlreadyDone.
  ///
  /// In en, this message translates to:
  /// **'Published'**
  String get publishAlreadyDone;

  /// No description provided for @publishSheetSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Once published, anyone can see this work in the community.'**
  String get publishSheetSubtitle;

  /// No description provided for @publishFieldTitle.
  ///
  /// In en, this message translates to:
  /// **'Title'**
  String get publishFieldTitle;

  /// No description provided for @publishFieldDescription.
  ///
  /// In en, this message translates to:
  /// **'Description (optional)'**
  String get publishFieldDescription;

  /// No description provided for @publishConfirm.
  ///
  /// In en, this message translates to:
  /// **'Publish'**
  String get publishConfirm;

  /// No description provided for @publishInProgress.
  ///
  /// In en, this message translates to:
  /// **'Publishing'**
  String get publishInProgress;

  /// No description provided for @publishSuccess.
  ///
  /// In en, this message translates to:
  /// **'Published to community'**
  String get publishSuccess;

  /// No description provided for @publishErrSignedOut.
  ///
  /// In en, this message translates to:
  /// **'Sign in before publishing'**
  String get publishErrSignedOut;

  /// No description provided for @publishErrAlreadyPublished.
  ///
  /// In en, this message translates to:
  /// **'This work is already published'**
  String get publishErrAlreadyPublished;

  /// No description provided for @publishErrReading.
  ///
  /// In en, this message translates to:
  /// **'Could not read the point cloud'**
  String get publishErrReading;

  /// No description provided for @publishErrUploading.
  ///
  /// In en, this message translates to:
  /// **'Upload failed — check your connection and retry'**
  String get publishErrUploading;

  /// No description provided for @publishErrTooLarge.
  ///
  /// In en, this message translates to:
  /// **'This scan exceeds the upload size limit — retrying will not help. Please capture a smaller area and regenerate.'**
  String get publishErrTooLarge;

  /// No description provided for @publishErrRejected.
  ///
  /// In en, this message translates to:
  /// **'This file failed server-side validation and may be corrupted. Please regenerate the scan.'**
  String get publishErrRejected;

  /// No description provided for @publishErrInserting.
  ///
  /// In en, this message translates to:
  /// **'Could not save the publication, please retry'**
  String get publishErrInserting;

  /// No description provided for @publishErrGeneric.
  ///
  /// In en, this message translates to:
  /// **'Publish failed'**
  String get publishErrGeneric;

  /// No description provided for @communityCloudLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not load the point cloud'**
  String get communityCloudLoadFailed;

  /// No description provided for @communityRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get communityRetry;

  /// No description provided for @communityFormatUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This format cannot be previewed in this version'**
  String get communityFormatUnsupported;

  /// No description provided for @communityPointsSuffix.
  ///
  /// In en, this message translates to:
  /// **'points'**
  String get communityPointsSuffix;

  /// No description provided for @meDeleteAccount.
  ///
  /// In en, this message translates to:
  /// **'Delete account'**
  String get meDeleteAccount;

  /// No description provided for @meDeleteAccountDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Permanently delete your account?'**
  String get meDeleteAccountDialogTitle;

  /// No description provided for @meDeleteAccountDialogBody.
  ///
  /// In en, this message translates to:
  /// **'Your account, published works and all cloud data will be permanently deleted. This cannot be undone. Captures stored on this device are not affected.'**
  String get meDeleteAccountDialogBody;

  /// No description provided for @meDeleteAccountConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete permanently'**
  String get meDeleteAccountConfirm;

  /// No description provided for @meDeleteAccountFailed.
  ///
  /// In en, this message translates to:
  /// **'Deletion failed. Please try again later.'**
  String get meDeleteAccountFailed;

  /// No description provided for @publishModerationUnderReview.
  ///
  /// In en, this message translates to:
  /// **'Under review'**
  String get publishModerationUnderReview;

  /// No description provided for @publishModerationRemoved.
  ///
  /// In en, this message translates to:
  /// **'Removed'**
  String get publishModerationRemoved;

  /// No description provided for @publishModerationRemovedHint.
  ///
  /// In en, this message translates to:
  /// **'This work was removed for violating the community guidelines and is not visible to others. To appeal, use the contact details on the Settings page.'**
  String get publishModerationRemovedHint;

  /// No description provided for @workMoreActions.
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get workMoreActions;

  /// No description provided for @reportAction.
  ///
  /// In en, this message translates to:
  /// **'Report'**
  String get reportAction;

  /// No description provided for @reportSheetTitle.
  ///
  /// In en, this message translates to:
  /// **'Report this work'**
  String get reportSheetTitle;

  /// No description provided for @reportSheetSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Pick a reason and we\'ll review it promptly.'**
  String get reportSheetSubtitle;

  /// No description provided for @reportReasonSpam.
  ///
  /// In en, this message translates to:
  /// **'Spam or advertising'**
  String get reportReasonSpam;

  /// No description provided for @reportReasonHarassment.
  ///
  /// In en, this message translates to:
  /// **'Harassment or bullying'**
  String get reportReasonHarassment;

  /// No description provided for @reportReasonHateSpeech.
  ///
  /// In en, this message translates to:
  /// **'Hate speech'**
  String get reportReasonHateSpeech;

  /// No description provided for @reportReasonSexualContent.
  ///
  /// In en, this message translates to:
  /// **'Sexual content'**
  String get reportReasonSexualContent;

  /// No description provided for @reportReasonViolence.
  ///
  /// In en, this message translates to:
  /// **'Violence or gore'**
  String get reportReasonViolence;

  /// No description provided for @reportReasonCopyright.
  ///
  /// In en, this message translates to:
  /// **'Copyright infringement'**
  String get reportReasonCopyright;

  /// No description provided for @reportReasonMisinformation.
  ///
  /// In en, this message translates to:
  /// **'Misinformation'**
  String get reportReasonMisinformation;

  /// No description provided for @reportReasonOther.
  ///
  /// In en, this message translates to:
  /// **'Other'**
  String get reportReasonOther;

  /// No description provided for @reportDetailHint.
  ///
  /// In en, this message translates to:
  /// **'Additional details (optional)'**
  String get reportDetailHint;

  /// No description provided for @reportSubmit.
  ///
  /// In en, this message translates to:
  /// **'Submit report'**
  String get reportSubmit;

  /// No description provided for @reportSubmitted.
  ///
  /// In en, this message translates to:
  /// **'Report submitted. We\'ll review it promptly.'**
  String get reportSubmitted;

  /// No description provided for @reportFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t submit the report. Please try again later.'**
  String get reportFailed;

  /// No description provided for @blockAction.
  ///
  /// In en, this message translates to:
  /// **'Block this user'**
  String get blockAction;

  /// No description provided for @blockDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Block this user?'**
  String get blockDialogTitle;

  /// No description provided for @blockDialogBody.
  ///
  /// In en, this message translates to:
  /// **'You won\'t see their works anymore, and any follow relationship between you will be removed.'**
  String get blockDialogBody;

  /// No description provided for @blockConfirm.
  ///
  /// In en, this message translates to:
  /// **'Block'**
  String get blockConfirm;

  /// No description provided for @blockDone.
  ///
  /// In en, this message translates to:
  /// **'Blocked. Their works will no longer appear.'**
  String get blockDone;

  /// No description provided for @blockFailed.
  ///
  /// In en, this message translates to:
  /// **'Action failed. Please try again later.'**
  String get blockFailed;

  /// No description provided for @workDeleteAction.
  ///
  /// In en, this message translates to:
  /// **'Remove from community'**
  String get workDeleteAction;

  /// No description provided for @workDeleteDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Remove this work from the community?'**
  String get workDeleteDialogTitle;

  /// No description provided for @workDeleteDialogBody.
  ///
  /// In en, this message translates to:
  /// **'The work will be removed from the community and its cloud files deleted. This cannot be undone. Your original capture on this device is unaffected and can be published again later.'**
  String get workDeleteDialogBody;

  /// No description provided for @workDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get workDeleteConfirm;

  /// No description provided for @workDeleteDone.
  ///
  /// In en, this message translates to:
  /// **'Removed from the community'**
  String get workDeleteDone;

  /// No description provided for @workDeleteFailed.
  ///
  /// In en, this message translates to:
  /// **'Removal failed. Please try again later.'**
  String get workDeleteFailed;

  /// No description provided for @socialActionFailed.
  ///
  /// In en, this message translates to:
  /// **'Action failed. Please try again later.'**
  String get socialActionFailed;

  /// No description provided for @socialFollowingTitle.
  ///
  /// In en, this message translates to:
  /// **'Following'**
  String get socialFollowingTitle;

  /// No description provided for @socialFollowingLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load your following list'**
  String get socialFollowingLoadFailed;

  /// No description provided for @socialFollowingEmpty.
  ///
  /// In en, this message translates to:
  /// **'You aren\'t following anyone yet'**
  String get socialFollowingEmpty;

  /// No description provided for @socialFollow.
  ///
  /// In en, this message translates to:
  /// **'Follow'**
  String get socialFollow;

  /// No description provided for @socialFollowing.
  ///
  /// In en, this message translates to:
  /// **'Following'**
  String get socialFollowing;

  /// No description provided for @socialWorks.
  ///
  /// In en, this message translates to:
  /// **'Works'**
  String get socialWorks;

  /// No description provided for @socialFollowers.
  ///
  /// In en, this message translates to:
  /// **'Followers'**
  String get socialFollowers;

  /// No description provided for @profileLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load this profile'**
  String get profileLoadFailed;

  /// No description provided for @profileBack.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get profileBack;

  /// No description provided for @profileMore.
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get profileMore;

  /// No description provided for @profileReportUser.
  ///
  /// In en, this message translates to:
  /// **'Report this user'**
  String get profileReportUser;

  /// No description provided for @profileBlockUser.
  ///
  /// In en, this message translates to:
  /// **'Block this user'**
  String get profileBlockUser;

  /// No description provided for @profileBlockTitle.
  ///
  /// In en, this message translates to:
  /// **'Block this user?'**
  String get profileBlockTitle;

  /// No description provided for @profileBlockBody.
  ///
  /// In en, this message translates to:
  /// **'While signed in to PocketWorld with this account, you won\'t see this person in Community, search, following lists, or profiles. Any follow relationship between you will be removed and neither account can follow the other. They won\'t be notified. Public links, signed-out visitors, or other accounts may still see their public content.'**
  String get profileBlockBody;

  /// No description provided for @profileBlockConfirm.
  ///
  /// In en, this message translates to:
  /// **'Block'**
  String get profileBlockConfirm;

  /// No description provided for @profileBlockFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t block this user. Please try again later.'**
  String get profileBlockFailed;

  /// No description provided for @reportUserTitle.
  ///
  /// In en, this message translates to:
  /// **'Report this user'**
  String get reportUserTitle;

  /// No description provided for @reportTierTitle.
  ///
  /// In en, this message translates to:
  /// **'Choose report type'**
  String get reportTierTitle;

  /// No description provided for @reportReasonTitle.
  ///
  /// In en, this message translates to:
  /// **'Choose a reason'**
  String get reportReasonTitle;

  /// No description provided for @reportStandardTitle.
  ///
  /// In en, this message translates to:
  /// **'Standard report'**
  String get reportStandardTitle;

  /// No description provided for @reportStandardSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Harassment, fraud, harmful content, or another community issue'**
  String get reportStandardSubtitle;

  /// No description provided for @reportRightsTitle.
  ///
  /// In en, this message translates to:
  /// **'Rights complaint'**
  String get reportRightsTitle;

  /// No description provided for @reportRightsEntry.
  ///
  /// In en, this message translates to:
  /// **'Infringes rights'**
  String get reportRightsEntry;

  /// No description provided for @reportRightsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Impersonation, privacy, portrait, or intellectual-property concerns'**
  String get reportRightsSubtitle;

  /// No description provided for @reportStandardDetailHint.
  ///
  /// In en, this message translates to:
  /// **'Describe whether the issue appears on the front, back, top, or another view'**
  String get reportStandardDetailHint;

  /// No description provided for @reportRightsDetailHint.
  ///
  /// In en, this message translates to:
  /// **'Describe ownership, where the infringement appears, and the requested action'**
  String get reportRightsDetailHint;

  /// No description provided for @reportEvidenceType.
  ///
  /// In en, this message translates to:
  /// **'Evidence type'**
  String get reportEvidenceType;

  /// No description provided for @reportEvidenceContext.
  ///
  /// In en, this message translates to:
  /// **'Issue screenshot'**
  String get reportEvidenceContext;

  /// No description provided for @reportEvidenceIdentity.
  ///
  /// In en, this message translates to:
  /// **'Identity evidence'**
  String get reportEvidenceIdentity;

  /// No description provided for @reportEvidenceOwnership.
  ///
  /// In en, this message translates to:
  /// **'Ownership evidence'**
  String get reportEvidenceOwnership;

  /// No description provided for @reportEvidenceAuthorization.
  ///
  /// In en, this message translates to:
  /// **'Authorization evidence'**
  String get reportEvidenceAuthorization;

  /// No description provided for @reportEvidenceOther.
  ///
  /// In en, this message translates to:
  /// **'Other evidence'**
  String get reportEvidenceOther;

  /// No description provided for @reportEvidenceOptional.
  ///
  /// In en, this message translates to:
  /// **'Supporting screenshots (optional)'**
  String get reportEvidenceOptional;

  /// No description provided for @reportEvidenceLimitHint.
  ///
  /// In en, this message translates to:
  /// **'Up to 3 JPG or PNG images. Location and other metadata are removed before upload.'**
  String get reportEvidenceLimitHint;

  /// No description provided for @reportHistoryTitle.
  ///
  /// In en, this message translates to:
  /// **'My reports'**
  String get reportHistoryTitle;

  /// No description provided for @reportHistoryEmpty.
  ///
  /// In en, this message translates to:
  /// **'You haven\'t submitted any reports'**
  String get reportHistoryEmpty;

  /// No description provided for @reportHistoryLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load report history'**
  String get reportHistoryLoadFailed;

  /// No description provided for @reportHistorySource.
  ///
  /// In en, this message translates to:
  /// **'Related work: {title}'**
  String reportHistorySource(String title);

  /// No description provided for @reportStatusPending.
  ///
  /// In en, this message translates to:
  /// **'Pending'**
  String get reportStatusPending;

  /// No description provided for @reportStatusInReview.
  ///
  /// In en, this message translates to:
  /// **'In review'**
  String get reportStatusInReview;

  /// No description provided for @reportStatusNeedsInfo.
  ///
  /// In en, this message translates to:
  /// **'More information needed'**
  String get reportStatusNeedsInfo;

  /// No description provided for @reportStatusActioned.
  ///
  /// In en, this message translates to:
  /// **'Action taken'**
  String get reportStatusActioned;

  /// No description provided for @reportStatusDismissed.
  ///
  /// In en, this message translates to:
  /// **'No violation found'**
  String get reportStatusDismissed;

  /// No description provided for @reportAdditionalInfoTitle.
  ///
  /// In en, this message translates to:
  /// **'Additional information'**
  String get reportAdditionalInfoTitle;

  /// No description provided for @reportImageProcessFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t process that image. Choose a JPG or PNG.'**
  String get reportImageProcessFailed;

  /// No description provided for @reportUserSubmitted.
  ///
  /// In en, this message translates to:
  /// **'Report submitted'**
  String get reportUserSubmitted;

  /// No description provided for @reportSubmittedPartial.
  ///
  /// In en, this message translates to:
  /// **'Report submitted, but some images weren\'t uploaded'**
  String get reportSubmittedPartial;

  /// No description provided for @reportDetailUserHint.
  ///
  /// In en, this message translates to:
  /// **'Describe what happened (optional)'**
  String get reportDetailUserHint;

  /// No description provided for @reportSourceWork.
  ///
  /// In en, this message translates to:
  /// **'Related work: {workId}'**
  String reportSourceWork(String workId);

  /// No description provided for @reportAddEvidence.
  ///
  /// In en, this message translates to:
  /// **'Add screenshots or photos (up to 3)'**
  String get reportAddEvidence;

  /// No description provided for @reportSensitiveEvidenceWarning.
  ///
  /// In en, this message translates to:
  /// **'Don\'t re-upload or redistribute sensitive material. The platform will preserve linked in-app content for review.'**
  String get reportSensitiveEvidenceWarning;

  /// No description provided for @reportSubmitting.
  ///
  /// In en, this message translates to:
  /// **'Submitting…'**
  String get reportSubmitting;

  /// No description provided for @reportSubmitUser.
  ///
  /// In en, this message translates to:
  /// **'Submit report'**
  String get reportSubmitUser;

  /// No description provided for @reportReasonImpersonation.
  ///
  /// In en, this message translates to:
  /// **'Impersonation or false account information'**
  String get reportReasonImpersonation;

  /// No description provided for @reportReasonHarassmentThreat.
  ///
  /// In en, this message translates to:
  /// **'Harassment, bullying, or threats'**
  String get reportReasonHarassmentThreat;

  /// No description provided for @reportReasonSpamFraud.
  ///
  /// In en, this message translates to:
  /// **'Fraud, spam, or suspicious account activity'**
  String get reportReasonSpamFraud;

  /// No description provided for @reportReasonMinorSafety.
  ///
  /// In en, this message translates to:
  /// **'Minor safety'**
  String get reportReasonMinorSafety;

  /// No description provided for @reportReasonSexualLowQuality.
  ///
  /// In en, this message translates to:
  /// **'Sexual or explicit content'**
  String get reportReasonSexualLowQuality;

  /// No description provided for @reportReasonViolenceIllegal.
  ///
  /// In en, this message translates to:
  /// **'Violence, self-harm, hate, extremism, or other illegal harmful content'**
  String get reportReasonViolenceIllegal;

  /// No description provided for @reportReasonMisleading.
  ///
  /// In en, this message translates to:
  /// **'False or misleading information'**
  String get reportReasonMisleading;

  /// No description provided for @reportReasonPrivacyIp.
  ///
  /// In en, this message translates to:
  /// **'Privacy, doxxing, portrait, or intellectual property'**
  String get reportReasonPrivacyIp;

  /// No description provided for @reportReasonOtherUncertain.
  ///
  /// In en, this message translates to:
  /// **'Other / not sure'**
  String get reportReasonOtherUncertain;

  /// No description provided for @blockedUsersTitle.
  ///
  /// In en, this message translates to:
  /// **'Blocked users'**
  String get blockedUsersTitle;

  /// No description provided for @blockedUsersLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load blocked users'**
  String get blockedUsersLoadFailed;

  /// No description provided for @blockedUsersEmpty.
  ///
  /// In en, this message translates to:
  /// **'You haven\'t blocked anyone'**
  String get blockedUsersEmpty;

  /// No description provided for @unblockTitle.
  ///
  /// In en, this message translates to:
  /// **'Unblock this user?'**
  String get unblockTitle;

  /// No description provided for @unblockBody.
  ///
  /// In en, this message translates to:
  /// **'You\'ll be able to see their public content again. Previous follow relationships won\'t be restored automatically.'**
  String get unblockBody;

  /// No description provided for @unblockAction.
  ///
  /// In en, this message translates to:
  /// **'Unblock'**
  String get unblockAction;

  /// No description provided for @unblockFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t unblock this user. Please try again later.'**
  String get unblockFailed;

  /// No description provided for @meBlockedUsers.
  ///
  /// In en, this message translates to:
  /// **'Blocked users'**
  String get meBlockedUsers;

  /// No description provided for @meSocialLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load social profile'**
  String get meSocialLoadFailed;
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
