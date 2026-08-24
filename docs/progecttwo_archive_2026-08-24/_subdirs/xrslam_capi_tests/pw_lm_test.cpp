/* [pw] 条目 05 的决定性测试:直接往进程级 inspection 槽位注入构造好的 landmark,
   绕开"合成噪声图跑不出初始化"这个障碍,精确验证过滤 + 计账。
   注入的三类点复刻实测机制:
     - inv_depth == 0  => get_landmark_point() = bearing / 0 => ±Inf   (发布循环只判 TT_VALID)
     - inv_depth == -1 => 有限但落在相机背后,且 triangulated == false (refine_window 的 else 分支)
     - 正常三角化点 */
#include "XRSLAM.h"
#include "xrslam/inspection.h"
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <vector>
#include <cstdlib>
#include <cstdio>


/* [pw] 移动端口径带 -DXRSLAM_CONFIG_FROM_STRING=ON,XRSLAMCreate 的两个参数是
   YAML **正文**而不是路径(yaml_config.cpp:153/165)。argv[4]=="text" 时把文件
   读进来传正文,这样同一个测试能覆盖两种口径。 */
static char *slurp(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    char *b = (char *)malloc((size_t)n + 1);
    if (!b) { fclose(f); return NULL; }
    size_t got = fread(b, 1, (size_t)n, f); b[got] = 0; fclose(f); return b;
}

static int g_fail = 0, g_pass = 0;
#define CHECK(cond, ...)                                                       \
    do {                                                                       \
        if (cond) { ++g_pass; }                                                \
        else { ++g_fail; std::printf("  FAIL %d: ", __LINE__);                 \
               std::printf(__VA_ARGS__); std::printf("\n"); }                  \
    } while (0)

static void inject(const std::vector<xrslam::Landmark> &v) {
    inspect(sliding_window_landmarks, lm) { lm = v; }
}

int main(int argc, char **argv) {
    if (argc < 3) { std::printf("usage: %s slam.yaml dev.yaml\n", argv[0]); return 2; }
    const char *A = argv[1], *B = argv[2];
    if (argc > 3 && std::strcmp(argv[3], "text") == 0) {
        A = slurp(argv[1]); B = slurp(argv[2]);
        if (!A || !B) { std::printf("slurp failed\n"); return 2; }
    }
    argv[1] = (char *)A; argv[2] = (char *)B;
    void *cfg = nullptr;
    if (XRSLAMCreate(argv[1], argv[2], "", "pwlmtest", &cfg) != 1) {
        std::printf("create failed\n"); return 2;
    }
    const double INF = std::numeric_limits<double>::infinity();
    const double NAN_ = std::numeric_limits<double>::quiet_NaN();

    std::vector<xrslam::Landmark> v;
    auto add = [&](double x, double y, double z, bool tri) {
        xrslam::Landmark l; l.p = xrslam::vector<3>(x, y, z); l.triangulated = tri; v.push_back(l);
    };
    /* 3 个好点 */
    add(1.0, 2.0, 3.0, true);
    add(-1.5, 0.25, 4.0, true);
    add(0.0, 0.0, 2.0, true);
    /* 2 个 ±Inf(inv_depth == 0 的除零产物) */
    add(INF, 1.0, 1.0, true);
    add(1.0, -INF, 1.0, false);
    /* 1 个 NaN */
    add(NAN_, NAN_, NAN_, true);
    /* 2 个有限但未三角化(inv_depth == -1,相机背后) */
    add(0.5, 0.5, -7.0, false);
    add(-0.5, 0.5, -9.0, false);
    inject(v);
    /* published = 8, non_finite = 3, untriangulated(有限的) = 2, usable = 3 */

    std::printf("[L1] XRSLAMGetLandmarks (strict: isfinite && triangulated)\n");
    {
        int32_t n = 0;
        int rc = XRSLAMGetLandmarks(nullptr, &n);
        CHECK(rc == XRSLAM_OK, "probe rc=%d", rc);
        CHECK(n == 3, "usable=%d want 3", n);

        double xyz[3 * 8]; std::memset(xyz, 0xAB, sizeof xyz);
        int32_t cap = 8;
        rc = XRSLAMGetLandmarks(xyz, &cap);
        CHECK(rc == XRSLAM_OK, "fetch rc=%d", rc);
        CHECK(cap == 3, "written=%d want 3", cap);
        bool all_finite = true;
        for (int i = 0; i < 3 * cap; ++i) if (!std::isfinite(xyz[i])) all_finite = false;
        CHECK(all_finite, "non-finite leaked into out_xyz");
        CHECK(xyz[0] == 1.0 && xyz[1] == 2.0 && xyz[2] == 3.0, "p0 wrong");
        CHECK(xyz[6] == 0.0 && xyz[8] == 2.0, "p2 wrong");
        /* 未三角化的相机背后点必须一个都没进来 */
        bool behind = false;
        for (int i = 0; i < cap; ++i) if (xyz[3 * i + 2] < 0.0) behind = true;
        CHECK(!behind, "untriangulated behind-camera point leaked");
    }

    std::printf("[L2] 截断路径 + 计账\n");
    {
        double xyz[3 * 2]; int32_t cap = 2;
        int rc = XRSLAMGetLandmarks(xyz, &cap);
        CHECK(rc == XRSLAM_INCOMPLETE, "truncate rc=%d want INCOMPLETE(1)", rc);
        CHECK(cap == 2, "written=%d", cap);
    }

    std::printf("[L3] XRSLAMGetLandmarksEx (宽口径 + flags + stats)\n");
    {
        double xyz[3 * 8]; unsigned char fl[8]; int32_t cap = 8;
        XRSLAMLandmarkStats st; std::memset(&st, 0xAB, sizeof st);
        int rc = XRSLAMGetLandmarksEx(xyz, fl, &cap, &st);
        CHECK(rc == XRSLAM_OK, "rc=%d", rc);
        CHECK(cap == 5, "written=%d want 5 (3 good + 2 untriangulated finite)", cap);
        CHECK(st.published == 8, "published=%d want 8", st.published);
        CHECK(st.rejected_non_finite == 3, "non_finite=%d want 3", st.rejected_non_finite);
        CHECK(st.rejected_untriangulated == 2, "untri=%d want 2", st.rejected_untriangulated);
        CHECK(st.returned == 5, "returned=%d", st.returned);
        int tri = 0; for (int i = 0; i < cap; ++i)
            if (fl[i] & XRSLAM_LANDMARK_FLAG_TRIANGULATED) ++tri;
        CHECK(tri == 3, "flagged triangulated=%d want 3", tri);
        bool all_finite = true;
        for (int i = 0; i < 3 * cap; ++i) if (!std::isfinite(xyz[i])) all_finite = false;
        CHECK(all_finite, "Ex path leaked non-finite (±Inf/NaN 对任何用途都是垃圾)");
    }

    std::printf("[L4] XRSLAMHealth 的 landmark 计账必须与 stats 一致\n");
    {
        XRSLAMHealth h; std::memset(&h, 0xAB, sizeof h);
        int rc = XRSLAMGetHealth(&h);
        CHECK(rc == XRSLAM_OK, "rc=%d", rc);
        CHECK(h.landmarks_published == 8, "published=%d", h.landmarks_published);
        CHECK(h.landmarks_usable == 3, "usable=%d", h.landmarks_usable);
        CHECK(h.landmarks_rejected_non_finite == 3, "nonfinite=%d",
              h.landmarks_rejected_non_finite);
        CHECK(h.landmarks_rejected_untriangulated == 2, "untri=%d",
              h.landmarks_rejected_untriangulated);
        /* usable=3 < 默认阈值 20,但状态是 INITIALIZING(不是 TRACKING_SUCCESS),
           按设计不判 LOW_TEXTURE */
        std::printf("      overall=%d slam_state=%d\n", h.overall, h.slam_state);
    }

    std::printf("[L5] 全垃圾输入 -> 必须交出 0 个点而不是崩/漏\n");
    {
        std::vector<xrslam::Landmark> bad;
        for (int i = 0; i < 5; ++i) {
            xrslam::Landmark l; l.p = xrslam::vector<3>(INF, NAN_, -INF);
            l.triangulated = true; bad.push_back(l);
        }
        inject(bad);
        int32_t n = 0;
        int rc = XRSLAMGetLandmarks(nullptr, &n);
        CHECK(rc == XRSLAM_OK && n == 0, "rc=%d n=%d", rc, n);
        XRSLAMLandmarkStats st; double xyz[15]; unsigned char fl[5]; int32_t cap = 5;
        rc = XRSLAMGetLandmarksEx(xyz, fl, &cap, &st);
        CHECK(rc == XRSLAM_OK && cap == 0, "Ex rc=%d cap=%d", rc, cap);
        CHECK(st.published == 5 && st.rejected_non_finite == 5, "stats %d/%d",
              st.published, st.rejected_non_finite);
    }

    std::printf("[L6] Destroy 必须清空进程级槽位(否则下一次会话渲染幽灵点)\n");
    {
        std::vector<xrslam::Landmark> good;
        xrslam::Landmark l; l.p = xrslam::vector<3>(1, 1, 1); l.triangulated = true;
        good.push_back(l); inject(good);
        int32_t n = 0;
        CHECK(XRSLAMGetLandmarks(nullptr, &n) == XRSLAM_OK && n == 1, "before destroy n=%d", n);
        XRSLAMDestroy();
        void *c2 = nullptr;
        CHECK(XRSLAMCreate(argv[1], argv[2], "", "pwlmtest", &c2) == 1, "recreate");
        n = 999;
        int rc = XRSLAMGetLandmarks(nullptr, &n);
        CHECK(rc == XRSLAM_OK && n == 0, "ghost points survived Destroy: rc=%d n=%d", rc, n);
        XRSLAMDestroy();
    }

    std::printf("\n==== lm pass=%d fail=%d ====\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
