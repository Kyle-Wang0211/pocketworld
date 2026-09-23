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
  String communityOnlyAuthor(String name) {
    return '只看 @$name 的作品';
  }

  @override
  String get communityClearAuthorFilter => '看全部';

  @override
  String get communityTopicTitle => '本周精选';

  @override
  String get communityTopicBody => '编辑挑出的空间。想上这里，就把你扫的地方发出来。';

  @override
  String get communityTopicCaptureTitle => '怎么扫得更好';

  @override
  String get communityTopicCaptureBody => '绕着走,慢一点,别只站在一个位置。覆盖够了,模型才不会破。';

  @override
  String get communityTopicViewerTitle => '点开就能转';

  @override
  String get communityTopicViewerBody => '这里每一件都是真的三维。拖一下,换个角度再看一遍。';

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
    return '\"$name\" 的本机原始照片、点云、重建数据库和缓存将被永久删除，无法恢复。';
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
  String get meBadgeGenerating => '生成中';

  @override
  String get meBadgeUnfinished => '未完成';

  @override
  String get meBadgeDone => '完成';

  @override
  String get meTabDrafts => '草稿';

  @override
  String get defaultImportedScan => '导入的模型';

  @override
  String get meDisplayName => '昵称';

  @override
  String get meDisplayNameDialogTitle => '修改昵称';

  @override
  String get meDisplayNameDialogHint => '新昵称(最多 20 字)';

  @override
  String get meDisplayNameUpdated => '昵称已更新';

  @override
  String meDisplayNameUpdateFailed(String error) {
    return '更新失败:$error';
  }

  @override
  String get meAnalyticsTitle => '帮助改进产品';

  @override
  String get meToggleOn => '已开启';

  @override
  String get meToggleOff => '已关闭';

  @override
  String get legalUserAgreement => '用户协议';

  @override
  String get legalPrivacyPolicy => '隐私政策';

  @override
  String get authTermsAcceptancePrefix => '注册即表示你同意:';

  @override
  String get mePlatformRules => '平台公约';

  @override
  String get meIpRegion => 'IP 属地';

  @override
  String get meIpRegionUnknown => '未知';

  @override
  String ipRegionLabel(String region) {
    return 'IP属地:$region';
  }

  @override
  String get authPhoneEntry => '用手机号登录';

  @override
  String get authPhoneNumberHint => '手机号(不含国际区号)';

  @override
  String get authPhoneDisplayNameHint => '昵称(可选)';

  @override
  String get authPhoneSendCode => '发送验证码';

  @override
  String authPhoneWillSend(String target) {
    return '我们会发送一次性验证码到 $target。标准短信费可能适用。';
  }

  @override
  String authPhoneCodeSentTo(String phone) {
    return '验证码已发送到 $phone';
  }

  @override
  String get authPhoneCodeHint => '6 位验证码';

  @override
  String get authPhoneSubmitSignIn => '登录';

  @override
  String get authPhoneSubmitSignUp => '完成注册';

  @override
  String get authPhoneChangeNumber => '换个手机号';

  @override
  String get authPhoneYourNumber => '你的手机号';

  @override
  String get meHandle => 'ID';

  @override
  String get meHandleNotSet => '未设置';

  @override
  String get meHandleDialogTitle => '设置 ID';

  @override
  String get meHandleDialogHint => '小写字母、数字、点、下划线,2-32 位';

  @override
  String get meHandleDialogNote => 'ID 全站唯一,用来让别人找到你。设置后 3 天内不能再改。';

  @override
  String get meHandleUpdated => 'ID 已更新';

  @override
  String meHandleUpdateFailed(String error) {
    return 'ID 更新失败:$error';
  }

  @override
  String get sfmSaveDraft => '保存草稿';

  @override
  String get sfmNext => '下一步';

  @override
  String get sfmDone => '完成';

  @override
  String get sfmBackToDrafts => '返回草稿';

  @override
  String get sfmEditSelection => '选区编辑';

  @override
  String get sfmSelectionSaveTitle => '编辑记录是否保存';

  @override
  String get sfmSelectionSaveBody => '你调整过选区范围。保存后预览与交付都只包含框内的点。';

  @override
  String get sfmSelectionSaveKeep => '保存';

  @override
  String get sfmSelectionSaveDiscard => '不保存';

  @override
  String get sfmSelectionSaveCancel => '取消';

  @override
  String get sfmGeneratingFinalCloud => '正在生成最终点云…';

  @override
  String get captureFinishing => '正在收尾拍摄…';

  @override
  String get sfmReconFailedKeptFrames => '本次未能重建,已保留素材';

  @override
  String get sfmChipFinalRecon => '最终重建';

  @override
  String sfmChipReconstructing(int count) {
    return '重建中 · $count 点…';
  }

  @override
  String sfmChipReconDone(int count) {
    return '重建完成 · $count 点';
  }

  @override
  String get sfmChipReconEnded => '重建结束';

  @override
  String get sfmQueueDrainedFinal => '帧队列已清空 · 正在生成最终点云';

  @override
  String sfmProgressFedQueued(int fed, int queued) {
    return '已完成 $fed/$queued 帧';
  }

  @override
  String sfmElapsedSec(int secs) {
    return '$secs 秒';
  }

  @override
  String sfmElapsedMinSec(int min, int sec) {
    return '$min 分 $sec 秒';
  }

  @override
  String sfmStage1(String elapsed) {
    return '整理帧数据…(阶段 1/4 · 已 $elapsed)';
  }

  @override
  String sfmStage2a(String elapsed) {
    return '补全匹配中…(阶段 2/4 · 已 $elapsed)';
  }

  @override
  String sfmStage2b(String elapsed) {
    return '全局优化中…(阶段 2/4 · 已 $elapsed)';
  }

  @override
  String sfmStage3(String elapsed) {
    return '提取色彩…(阶段 3/4 · 已 $elapsed)';
  }

  @override
  String sfmStage4(String elapsed) {
    return '保存点云…(阶段 4/4 · 已 $elapsed)';
  }

  @override
  String get viewerSparseCloudTitle => '稀疏点云';

  @override
  String viewerTitleWithCount(String title, int count) {
    return '$title · $count 点';
  }

  @override
  String get viewerLoadFailed => '点云文件读取失败';

  @override
  String get selectionRotatePointCloud => '旋转';

  @override
  String get selectionNoCloud => '暂无点云数据';

  @override
  String get cubeFaceTop => '顶';

  @override
  String get cubeFaceFront => '前';

  @override
  String get cubeFaceRight => '右';

  @override
  String get cubeFaceBack => '后';

  @override
  String get cubeFaceLeft => '左';

  @override
  String get cubeFaceBottom => '底';

  @override
  String get denseStageUnavailable => '后续处理还没接入本机';

  @override
  String get selectionCancel => '取消';

  @override
  String get selectionDiscardTitle => '确定要放弃更改吗?';

  @override
  String get selectionDiscardConfirm => '放弃更改';

  @override
  String get selectionResetRotation => '回到初始旋转角度';

  @override
  String get selectionResetZoom => '回到初始点云大小';

  @override
  String get selectionResetBoxSize => '恢复原始框大小';

  @override
  String get publishAction => '发布到社区';

  @override
  String get publishNotReady => '重建完成后可发布';

  @override
  String get publishAlreadyDone => '已发布到社区';

  @override
  String get publishSheetSubtitle => '发布后,任何人都能在社区看到这个作品。';

  @override
  String get publishFieldTitle => '标题';

  @override
  String get publishFieldDescription => '描述(选填)';

  @override
  String get publishConfirm => '确认发布';

  @override
  String get publishInProgress => '正在发布';

  @override
  String get publishSuccess => '已发布到社区';

  @override
  String get publishErrSignedOut => '请先登录再发布';

  @override
  String get publishErrAlreadyPublished => '这个作品已经发布过了';

  @override
  String get publishErrReading => '读取点云失败';

  @override
  String get publishErrUploading => '上传失败,请检查网络后重试';

  @override
  String get publishErrTooLarge => '这个扫描太大,超出了上传上限,重试不会成功。请缩小扫描范围后重新生成。';

  @override
  String get publishErrRejected => '文件未通过服务端校验,可能已损坏。请重新生成这个扫描。';

  @override
  String get publishErrInserting => '发布信息写入失败,请稍后重试';

  @override
  String get publishErrGeneric => '发布失败';

  @override
  String get communityCloudLoadFailed => '点云加载失败';

  @override
  String get communityRetry => '重试';

  @override
  String get communityFormatUnsupported => '当前版本无法预览这种格式';

  @override
  String get communityPointsSuffix => '点';

  @override
  String get meDeleteAccount => '删除账号';

  @override
  String get meDeleteAccountDialogTitle => '永久删除账号？';

  @override
  String get meDeleteAccountDialogBody =>
      '你的账号、已发布的作品和全部云端数据将被永久删除，此操作无法撤销。本机已拍摄的项目不受影响。';

  @override
  String get meDeleteAccountConfirm => '永久删除';

  @override
  String get meDeleteAccountFailed => '删除失败，请稍后重试';

  @override
  String get publishModerationUnderReview => '审核中';

  @override
  String get publishModerationRemoved => '已下架';

  @override
  String get publishModerationRemovedHint =>
      '该作品因违反社区规范已被下架，其他人无法看到。如有疑问请通过设置页的联系方式申诉。';

  @override
  String get workMoreActions => '更多';

  @override
  String get reportAction => '举报';

  @override
  String get reportSheetTitle => '举报这个作品';

  @override
  String get reportSheetSubtitle => '请选择原因，我们会尽快处理。';

  @override
  String get reportReasonSpam => '垃圾信息或广告';

  @override
  String get reportReasonHarassment => '骚扰或霸凌';

  @override
  String get reportReasonHateSpeech => '仇恨言论';

  @override
  String get reportReasonSexualContent => '色情内容';

  @override
  String get reportReasonViolence => '暴力或血腥';

  @override
  String get reportReasonCopyright => '侵犯版权';

  @override
  String get reportReasonMisinformation => '虚假信息';

  @override
  String get reportReasonOther => '其他';

  @override
  String get reportDetailHint => '补充说明（可选）';

  @override
  String get reportSubmit => '提交举报';

  @override
  String get reportSubmitted => '举报已提交，我们会尽快处理';

  @override
  String get reportFailed => '举报提交失败，请稍后重试';

  @override
  String get blockAction => '屏蔽此用户';

  @override
  String get blockDialogTitle => '屏蔽这个用户？';

  @override
  String get blockDialogBody => '屏蔽后你将不再看到该用户的作品，你们之间的关注关系也会取消。';

  @override
  String get blockConfirm => '屏蔽';

  @override
  String get blockDone => '已屏蔽，该用户的作品不再显示';

  @override
  String get blockFailed => '操作失败，请稍后重试';

  @override
  String get workDeleteAction => '从社区删除';

  @override
  String get workDeleteDialogTitle => '从社区删除这个作品？';

  @override
  String get workDeleteDialogBody =>
      '该作品将从社区移除，云端文件一并删除，无法恢复。本机的原始拍摄项目不受影响，之后仍可重新发布。';

  @override
  String get workDeleteConfirm => '删除';

  @override
  String get workDeleteDone => '已从社区删除';

  @override
  String get workDeleteFailed => '删除失败，请稍后重试';

  @override
  String get socialActionFailed => '操作失败，请稍后重试';

  @override
  String get socialFollowingTitle => '我的关注';

  @override
  String get socialFollowingLoadFailed => '暂时无法加载关注列表';

  @override
  String get socialFollowingEmpty => '还没有关注任何人';

  @override
  String get socialFollow => '关注';

  @override
  String get socialFollowing => '已关注';

  @override
  String get socialWorks => '作品';

  @override
  String get socialFollowers => '粉丝';

  @override
  String get profileLoadFailed => '暂时无法加载个人主页';

  @override
  String get profileBack => '返回';

  @override
  String get profileMore => '更多';

  @override
  String get profileReportUser => '举报该用户';

  @override
  String get profileBlockUser => '拉黑该用户';

  @override
  String get profileBlockTitle => '拉黑该用户？';

  @override
  String get profileBlockBody =>
      '使用当前账号登录 PocketWorld 时，你将不再在社区、搜索、关注列表和个人主页看到对方；双方关注关系会立即解除，也不能再次关注。对方不会收到通知。公开链接、未登录访问或其他账号仍可能看到其公开内容。';

  @override
  String get profileBlockConfirm => '确认拉黑';

  @override
  String get profileBlockFailed => '拉黑失败，请稍后重试';

  @override
  String get reportUserTitle => '举报该用户';

  @override
  String get reportTierTitle => '选择举报类型';

  @override
  String get reportReasonTitle => '选择原因';

  @override
  String get reportStandardTitle => '普通举报';

  @override
  String get reportStandardSubtitle => '骚扰、诈骗、违法有害或其他社区问题';

  @override
  String get reportRightsTitle => '权益投诉';

  @override
  String get reportRightsEntry => '侵犯权益';

  @override
  String get reportRightsSubtitle => '冒充、隐私、肖像或知识产权问题';

  @override
  String get reportStandardDetailHint => '请说明问题位于作品正面、背面、顶部或哪个画面';

  @override
  String get reportRightsDetailHint => '请说明权利归属、侵权位置和处理请求';

  @override
  String get reportEvidenceType => '证明材料类型';

  @override
  String get reportEvidenceContext => '问题截图';

  @override
  String get reportEvidenceIdentity => '身份证明';

  @override
  String get reportEvidenceOwnership => '权属证明';

  @override
  String get reportEvidenceAuthorization => '授权证明';

  @override
  String get reportEvidenceOther => '其他证明';

  @override
  String get reportEvidenceOptional => '补充截图（选填）';

  @override
  String get reportEvidenceLimitHint => '最多 3 张，仅支持 JPG 或 PNG；图片会在上传前移除定位等元数据。';

  @override
  String get reportHistoryTitle => '我的举报';

  @override
  String get reportHistoryEmpty => '还没有提交过举报';

  @override
  String get reportHistoryLoadFailed => '暂时无法加载举报记录';

  @override
  String reportHistorySource(String title) {
    return '关联作品：$title';
  }

  @override
  String get reportStatusPending => '待处理';

  @override
  String get reportStatusInReview => '审核中';

  @override
  String get reportStatusNeedsInfo => '需要补充材料';

  @override
  String get reportStatusActioned => '已处理';

  @override
  String get reportStatusDismissed => '未发现违规';

  @override
  String get reportAdditionalInfoTitle => '补充信息';

  @override
  String get reportImageProcessFailed => '无法处理这张图片，请选择 JPG 或 PNG';

  @override
  String get reportUserSubmitted => '举报已提交';

  @override
  String get reportSubmittedPartial => '举报已提交，部分图片未上传';

  @override
  String get reportDetailUserHint => '可补充说明具体情况';

  @override
  String reportSourceWork(String workId) {
    return '关联作品：$workId';
  }

  @override
  String get reportAddEvidence => '添加截图或照片（最多 3 张）';

  @override
  String get reportSensitiveEvidenceWarning =>
      '请不要重新上传或传播敏感材料。平台会保全关联的站内内容并交由审核处理。';

  @override
  String get reportSubmitting => '提交中…';

  @override
  String get reportSubmitUser => '提交举报';

  @override
  String get reportReasonImpersonation => '冒充他人或账号资料虚假';

  @override
  String get reportReasonHarassmentThreat => '骚扰、网络暴力或人身威胁';

  @override
  String get reportReasonSpamFraud => '诈骗、广告骚扰或异常账号行为';

  @override
  String get reportReasonMinorSafety => '涉及未成年人安全';

  @override
  String get reportReasonSexualLowQuality => '色情低俗';

  @override
  String get reportReasonViolenceIllegal => '暴力、自伤、仇恨、极端或其他违法有害信息';

  @override
  String get reportReasonMisleading => '虚假不实或误导性信息';

  @override
  String get reportReasonPrivacyIp => '隐私、人肉搜索、肖像或知识产权';

  @override
  String get reportReasonOtherUncertain => '其他 / 不确定';

  @override
  String get blockedUsersTitle => '已拉黑用户';

  @override
  String get blockedUsersLoadFailed => '暂时无法加载拉黑名单';

  @override
  String get blockedUsersEmpty => '没有已拉黑的用户';

  @override
  String get unblockTitle => '解除拉黑？';

  @override
  String get unblockBody => '解除后可以重新看到对方的公开内容，但不会自动恢复双方原来的关注关系。';

  @override
  String get unblockAction => '解除拉黑';

  @override
  String get unblockFailed => '解除拉黑失败，请稍后重试';

  @override
  String get meBlockedUsers => '已拉黑用户';

  @override
  String get meSocialLoadFailed => '暂时无法加载社交资料';
}
