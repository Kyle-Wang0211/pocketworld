// xrslam_status.dart — XRSLAM C ABI 的返回码。
//
// 为什么是手写的:ffigen 的宏求值器在这个头上整批失败(`Unable to parse Macros`),
// 九个宏一个都不生成。硬编码本身是有风险的 —— 两处定义会漂 —— 所以配了一个
// **解析 C 头文件的测试**(test/vio/ffi/xrslam_status_contract_test.dart)钉住:
// 头里改了值而这里没跟,测试当场红。C 头始终是唯一真源。
//
// ⚠️ XRSLAMCreate 是上游遗留约定,**1=成功 / 0=失败**,与下面这套
//    0=OK / 负数=错误 **正好相反**。所以不要对它用 [xrslamOk];
//    用 [xrslamCreateSucceeded]。这是最容易写反的一处。

/// 成功。
const int xrslamOk = 0;

/// 缓冲区容量不足,已写满,数据被截断。**不是错误** —— 调用方应扩容重取。
const int xrslamIncomplete = 1;

/// 非阻塞拉取:出参已填,但不比上次新。
const int xrslamNoNewData = 2;

const int xrslamErrBadArg = -1;
const int xrslamErrBadChannel = -2;
const int xrslamErrNotCreated = -3;
const int xrslamErrInternal = -4;

/// 该数据通道在本次构建中被编译掉了(例如 inspection 关闭时的 landmark)。
/// 🔑 这个码存在的意义:把「地图 API 恒返回 0 点且零告警」这种**静默失效**
/// 变成一个明确的信号。见 [xrslamIsUnavailable]。
const int xrslamErrUnavailable = -5;

/// landmark flag 位:该点已三角化。未三角化的点可能是 ±Inf 或相机背后的镜像点。
const int xrslamLandmarkFlagTriangulated = 0x01;

/// 常规 API 是否成功。**不要用于 XRSLAMCreate**。
bool xrslamSucceeded(int rc) => rc >= 0;

/// 是否是「数据没写全但已写了一部分」这类非错误状态。
bool xrslamIsPartial(int rc) => rc == xrslamIncomplete || rc == xrslamNoNewData;

/// 通道被编译掉 —— 与「有通道但没数据」是两回事,必须分开处理,
/// 否则又变成一个静默失效。
bool xrslamIsUnavailable(int rc) => rc == xrslamErrUnavailable;

/// XRSLAMCreate 专用:上游约定 1=成功 / 0=失败,与其余 API 相反。
bool xrslamCreateSucceeded(int rc) => rc == 1;

/// 人可读的码名,用于日志与遥测。未知码原样带出数值,不吞掉。
String xrslamStatusName(int rc) {
  switch (rc) {
    case xrslamOk:
      return 'OK';
    case xrslamIncomplete:
      return 'INCOMPLETE';
    case xrslamNoNewData:
      return 'NO_NEW_DATA';
    case xrslamErrBadArg:
      return 'ERR_BAD_ARG';
    case xrslamErrBadChannel:
      return 'ERR_BAD_CHANNEL';
    case xrslamErrNotCreated:
      return 'ERR_NOT_CREATED';
    case xrslamErrInternal:
      return 'ERR_INTERNAL';
    case xrslamErrUnavailable:
      return 'ERR_UNAVAILABLE';
    default:
      return 'UNKNOWN($rc)';
  }
}

/// C 头里的宏名 → 本文件的值。契约测试用它做逐条对拍。
const Map<String, int> kXrslamStatusContract = <String, int>{
  'XRSLAM_OK': xrslamOk,
  'XRSLAM_INCOMPLETE': xrslamIncomplete,
  'XRSLAM_NO_NEW_DATA': xrslamNoNewData,
  'XRSLAM_ERR_BAD_ARG': xrslamErrBadArg,
  'XRSLAM_ERR_BAD_CHANNEL': xrslamErrBadChannel,
  'XRSLAM_ERR_NOT_CREATED': xrslamErrNotCreated,
  'XRSLAM_ERR_INTERNAL': xrslamErrInternal,
  'XRSLAM_ERR_UNAVAILABLE': xrslamErrUnavailable,
  'XRSLAM_LANDMARK_FLAG_TRIANGULATED': xrslamLandmarkFlagTriangulated,
};
