// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppL10nZh extends AppL10n {
  AppL10nZh([String locale = 'zh']) : super(locale);

  @override
  String get appBrand => '方寸间';

  @override
  String get splashSubtitle => '三维捕捉 · 极简工作台';

  @override
  String get splashStartingEngine => '正在启动 3D 引擎…';

  @override
  String get splashRestoringSession => '正在恢复会话…';

  @override
  String get splashPreparingSignIn => '准备登录界面…';

  @override
  String get splashWaking3DEngine => '正在唤醒 3D 引擎…';

  @override
  String get splashRendererUnavailable => '渲染器不可用，即将进入重试';

  @override
  String get communityEmptyTitle => '社区还没有作品';

  @override
  String get communitySearchHint => '搜索作品';

  @override
  String get communityTabHot => '热门';

  @override
  String get communityTabNearby => '附近';

  @override
  String get communityTabDiscover => '发现';

  @override
  String get communityNearbyComingSoon => '附近功能即将上线，敬请期待。';

  @override
  String get meMyWorksEmpty => '还没有作品 —— 点右下角的相机开始第一次扫描。';

  @override
  String get scanLifecycleCompleted => '已完成';

  @override
  String get createOptionCapture => '拍摄';

  @override
  String get createOptionUpload => '上传';

  @override
  String get createImportingGlb => '正在导入 GLB 模型…';

  @override
  String createImportPickerFailed(String error) {
    return '打开文件选择器失败：$error';
  }

  @override
  String get createImportFileUnreadable => '无法读取所选文件';

  @override
  String get meTapHintInProgress => '正在生成 3D 模型，完成后会自动打开';

  @override
  String get meActionRename => '改名';

  @override
  String get meActionDelete => '删除';

  @override
  String get meActionCancel => '取消';

  @override
  String get meActionSave => '保存';

  @override
  String get meRenameDialogTitle => '改名';

  @override
  String get meDeleteDialogTitle => '删除这次扫描?';

  @override
  String meDeleteDialogContent(String name) {
    return '\"$name\" 将从你的作品里移除。已发布到社区的内容不受影响。';
  }

  @override
  String get defaultUntitledScan => '未命名';

  @override
  String get captureWarmupHint => '正在初始化 AR…';

  @override
  String get captureReadyHint => '点击下方按钮进入瞄准';

  @override
  String get captureAimHint => '将准星对准主体，再点 ✓ 锁定并开始';

  @override
  String get captureMaterialTooSparseHint => '请继续拍摄一会儿再停止';

  @override
  String get captureLockFailedHint => '未检测到平面或跟踪未就绪 — 请对准物体所在表面后再试';

  @override
  String captureInitFailed(String error) {
    return '初始化失败：$error';
  }

  @override
  String captureRecordingStartFailed(String error) {
    return '开始录制失败：$error';
  }

  @override
  String get relativeJustNow => '刚刚';

  @override
  String relativeMinutesAgo(int n) {
    return '$n 分钟前';
  }

  @override
  String relativeHoursAgo(int n) {
    return '$n 小时前';
  }

  @override
  String relativeDaysAgo(int n) {
    return '$n 天前';
  }

  @override
  String relativeWeeksAgo(int n) {
    return '$n 周前';
  }

  @override
  String relativeMonthsAgo(int n) {
    return '$n 个月前';
  }

  @override
  String get meSettingsTitle => '设置';

  @override
  String get meNotifications => '通知';

  @override
  String get meNotificationsOn => '开启';

  @override
  String get mePrivacy => '隐私';

  @override
  String get meNotificationsOff => '已关闭';

  @override
  String get mePrivacyPublic => '公开';

  @override
  String get mePrivacyPrivate => '仅自己可见';

  @override
  String get meSettingNotConfigured => '未配置';

  @override
  String get meLanguage => '语言';

  @override
  String get meLanguageZh => '简体中文';

  @override
  String get meLanguageEn => 'English';

  @override
  String get meAbout => '关于';

  @override
  String get meSignOut => '退出登录';

  @override
  String get meDetailRunningProcessing => '处理中';

  @override
  String get meDetailRecordNotFound => '找不到这条作品';

  @override
  String get authWelcomeBack => '欢迎回来';

  @override
  String get authCreateAccount => '创建你的账号';

  @override
  String get authSignIn => '登录';

  @override
  String get authSignUp => '注册';

  @override
  String get authEmailHint => '邮箱';

  @override
  String get authPasswordHint => '密码';

  @override
  String get authPasswordHintMin => '设置密码（至少 8 位）';

  @override
  String get authForgotPassword => '忘记密码？';

  @override
  String get authTermsAcceptance => '注册即表示你同意方寸间的服务条款与隐私政策。';

  @override
  String get authErrorDialogTitle => '出错了';

  @override
  String get otpVerifyTitle => '验证邮箱';

  @override
  String otpVerifySubtitle(String email) {
    return '我们已向 $email 发送 6 位验证码，请在下方输入完成注册。';
  }

  @override
  String get otpResend => '重新发送';

  @override
  String otpResendCooldown(int seconds) {
    return '$seconds 秒后可重发';
  }

  @override
  String get otpResendSent => '已重新发送';

  @override
  String get otpUseAnotherEmail => '换一个邮箱';

  @override
  String get resetTitle => '重置密码';

  @override
  String resetSubtitleEnterCode(String email) {
    return '我们已向 $email 发送 6 位验证码，请连同新密码一起输入';
  }

  @override
  String get resetSendCode => '发送验证码';

  @override
  String get resetNewPasswordHint => '新密码（至少 8 位）';

  @override
  String get resetConfirm => '重置密码';

  @override
  String get captureModeLocal => '本地方案';

  @override
  String get captureModeRemoteLegacy => '远程方案';

  @override
  String get captureModeNewRemote => '新远程方案';

  @override
  String get languageDialogTitle => '语言';

  @override
  String get languageDialogChinese => '简体中文';

  @override
  String get languageDialogEnglish => 'English';

  @override
  String get commonCancel => '取消';

  @override
  String get commonOk => '确定';

  @override
  String get meTabProjects => '项目';

  @override
  String get meTabDrafts => '草稿';

  @override
  String get defaultImportedScan => '导入的模型';

  @override
  String get meDisplayName => '用户名';

  @override
  String get meDisplayNameDialogTitle => '修改用户名';

  @override
  String get meDisplayNameDialogHint => '新用户名(1-40 字)';

  @override
  String get meDisplayNameUpdated => '用户名已更新';

  @override
  String meDisplayNameUpdateFailed(String error) {
    return '更新失败:$error';
  }
}
