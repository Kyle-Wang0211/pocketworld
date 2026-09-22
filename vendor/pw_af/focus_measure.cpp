// pw_af —— 焦点度量的实现。出处、算子选择依据与偏离见 focus_measure.h。

#include "focus_measure.h"

#include <algorithm>

namespace pw_af {
namespace {

// 算子需要的边界余量(像素):Tenengrad 要完整的 3×3 邻域;
// squared gradient 只要 (x+1, y+1) 两个前向邻居。
int BorderFor(PwFocusOperator op) {
  return op == PwFocusOperator::Tenengrad ? 1 : 0;
}

}  // namespace

// af.cpp:313-321 的默认窗口:中 1/2 宽 × 中 1/3 高。
// 上游是在 rows×cols 的统计网格上按整数除法取 [rows/3, rows-rows/3) ×
// [cols/4, cols-cols/4),这里换成像素坐标的同一比例。
PwAfRect PwAfDefaultRoi(int width, int height) {
  PwAfRect roi;
  if (width <= 0 || height <= 0) {
    return roi;
  }
  roi.x = width / 4;
  roi.width = width - 2 * (width / 4);
  roi.y = height / 3;
  roi.height = height - 2 * (height / 3);
  return roi;
}

bool PwAfClampRoi(const PwAfRect& roi, int width, int height,
                  PwFocusOperator op, PwAfRect* out) {
  if (out == nullptr || width <= 0 || height <= 0) {
    return false;
  }
  const int border = BorderFor(op);

  // 先与图像求交。
  int x0 = std::max(roi.x, 0);
  int y0 = std::max(roi.y, 0);
  int x1 = std::min(roi.x + roi.width, width);
  int y1 = std::min(roi.y + roi.height, height);

  // 再留出算子余量:Tenengrad 要完整 3×3 邻域 ⇒ [1, w-1);
  // 前向差分要 (x+1, y+1) ⇒ [0, w-1)。两者右/下边界相同,只差左/上。
  x0 = std::max(x0, border);
  y0 = std::max(y0, border);
  x1 = std::min(x1, width - 1);
  y1 = std::min(y1, height - 1);

  if (x0 >= x1 || y0 >= y1) {
    *out = PwAfRect{};
    return false;
  }
  out->x = x0;
  out->y = y0;
  out->width = x1 - x0;
  out->height = y1 - y0;
  return true;
}

double PwAfFocusMeasure(const uint8_t* gray, int width, int height, int stride,
                        const PwAfRect& roi, PwFocusOperator op,
                        double* meanLumaOut) {
  if (meanLumaOut != nullptr) {
    *meanLumaOut = 0.0;
  }
  if (gray == nullptr || width <= 0 || height <= 0 || stride < width) {
    return 0.0;
  }

  PwAfRect r;
  if (!PwAfClampRoi(roi, width, height, op, &r)) {
    return 0.0;
  }

  const int xEnd = r.x + r.width;
  const int yEnd = r.y + r.height;
  // int64 累加:最坏情形 Tenengrad 每像素 (4*255)^2 * 2 ≈ 2.08e6,
  // 1920×1440 全图 ≈ 5.8e12,远在 int64 内,不会溢出也不丢精度。
  int64_t sumMeasure = 0;
  int64_t sumLuma = 0;
  const int64_t count = static_cast<int64_t>(r.width) * r.height;

  if (op == PwFocusOperator::Tenengrad) {
    // 3×3 Sobel(与 Pertuz fmeasure.m TENG 同式;符号约定无所谓,要取平方)。
    //   gx = [-1 0 1; -2 0 2; -1 0 1]     gy = [-1 -2 -1; 0 0 0; 1 2 1]
    for (int y = r.y; y < yEnd; ++y) {
      const uint8_t* rowUp = gray + static_cast<ptrdiff_t>(y - 1) * stride;
      const uint8_t* rowMid = gray + static_cast<ptrdiff_t>(y) * stride;
      const uint8_t* rowDn = gray + static_cast<ptrdiff_t>(y + 1) * stride;
      for (int x = r.x; x < xEnd; ++x) {
        const int ul = rowUp[x - 1], um = rowUp[x], ur = rowUp[x + 1];
        const int ml = rowMid[x - 1], mr = rowMid[x + 1];
        const int dl = rowDn[x - 1], dm = rowDn[x], dr = rowDn[x + 1];
        const int gx = (ur + 2 * mr + dr) - (ul + 2 * ml + dl);
        const int gy = (dl + 2 * dm + dr) - (ul + 2 * um + ur);
        sumMeasure += static_cast<int64_t>(gx) * gx +
                      static_cast<int64_t>(gy) * gy;
        sumLuma += rowMid[x];
      }
    }
  } else {
    // Squared gradient:双向一阶前向差分的平方和。
    // Mir 2014 明确一阶导「方向要选全」(只算竖向会从 99 掉到 90)。
    for (int y = r.y; y < yEnd; ++y) {
      const uint8_t* row = gray + static_cast<ptrdiff_t>(y) * stride;
      const uint8_t* rowNext = gray + static_cast<ptrdiff_t>(y + 1) * stride;
      for (int x = r.x; x < xEnd; ++x) {
        const int dx = static_cast<int>(row[x + 1]) - static_cast<int>(row[x]);
        const int dy =
            static_cast<int>(rowNext[x]) - static_cast<int>(row[x]);
        sumMeasure += static_cast<int64_t>(dx) * dx +
                      static_cast<int64_t>(dy) * dy;
        sumLuma += row[x];
      }
    }
  }

  if (meanLumaOut != nullptr) {
    *meanLumaOut = static_cast<double>(sumLuma) / static_cast<double>(count);
  }
  // F2:返回 ROI 内均值(上游 getContrast():382 也是加权平均),
  // 这样 ROI 尺寸变化不改变度量的量纲,跨帧比较才成立。
  return static_cast<double>(sumMeasure) / static_cast<double>(count);
}

}  // namespace pw_af
