// COLMAP 4.1.1 uses curandState (XORWOW) with curand_init(seed, 0, 0).
// This is the sequence==offset==0 device behavior expressed with uint32 GLSL.

#ifndef POCKETWORLD_OFFICIAL_DENSE_COLMAP_XORWOW_GLSL_
#define POCKETWORLD_OFFICIAL_DENSE_COLMAP_XORWOW_GLSL_

struct ColmapXorwowState {
  uint v0;
  uint v1;
  uint v2;
  uint v3;
  uint v4;
  uint d;
};

ColmapXorwowState ColmapXorwowInitialize(uint seed_low, uint seed_high) {
  uint mixed_low = 1099087573u * (seed_low ^ 0xaad26b49u);
  uint mixed_high = 2591861531u * (seed_high ^ 0xf7dcefddu);
  ColmapXorwowState state;
  state.v0 = 123456789u + mixed_low;
  state.v1 = 362436069u ^ mixed_low;
  state.v2 = 521288629u + mixed_high;
  state.v3 = 88675123u ^ mixed_high;
  state.v4 = 5783321u + mixed_low;
  state.d = 6615241u + mixed_low + mixed_high;
  return state;
}

uint ColmapXorwowNext(inout ColmapXorwowState state) {
  uint t = state.v0 ^ (state.v0 >> 2u);
  state.v0 = state.v1;
  state.v1 = state.v2;
  state.v2 = state.v3;
  state.v3 = state.v4;
  state.v4 = (state.v4 ^ (state.v4 << 4u)) ^ (t ^ (t << 1u));
  state.d += 362437u;
  return state.v4 + state.d;
}

float ColmapXorwowUniform(inout ColmapXorwowState state) {
  const float two_to_minus_32 = 2.3283064365386963e-10;
  uint output_value = ColmapXorwowNext(state);
  return float(output_value) * two_to_minus_32 + two_to_minus_32;
}

uint ColmapXorwowStateIndex(uint component,
                            uint row,
                            uint col,
                            uint width,
                            uint height) {
  // [BATCH-REF 2026-08-30] 每个 reference 有独立的 4 分量 RNG 状态平面。
  // 🔴 漏掉这里 ⇒ 多个 reference 共用 xorwow 状态,抽样序列互相污染,
  //    且是难查的非确定性。本文件被多个 shader 共享(init_depth/init_normal
  //    /rng_init 都是一维 dispatch),故用宏由包含方注入。
#ifdef PW_XORWOW_REF_BATCHED
  // 🔴 步长是 **6**,不是 4:xorwow 状态是 v0..v4 加 d 共 6 个 uint32/像素
  //    (binding 6 = bytes_24p,array_layers = 6)。写成 4 会让 reference 1
  //    的状态压在 reference 0 的第 4、5 分量上 —— 正是那种「跑得通、
  //    数值悄悄不对」的 bug。
  return RefIndex() * 6u * height * width +
      (component * height + row) * width + col;
#else
  return (component * height + row) * width + col;
#endif
}

ColmapXorwowState LoadColmapXorwowState(uint row,
                                        uint col,
                                        uint width,
                                        uint height) {
  ColmapXorwowState state;
  state.v0 = xorwow_state_words.values[
      ColmapXorwowStateIndex(0u, row, col, width, height)];
  state.v1 = xorwow_state_words.values[
      ColmapXorwowStateIndex(1u, row, col, width, height)];
  state.v2 = xorwow_state_words.values[
      ColmapXorwowStateIndex(2u, row, col, width, height)];
  state.v3 = xorwow_state_words.values[
      ColmapXorwowStateIndex(3u, row, col, width, height)];
  state.v4 = xorwow_state_words.values[
      ColmapXorwowStateIndex(4u, row, col, width, height)];
  state.d = xorwow_state_words.values[
      ColmapXorwowStateIndex(5u, row, col, width, height)];
  return state;
}

void StoreColmapXorwowState(uint row,
                            uint col,
                            uint width,
                            uint height,
                            ColmapXorwowState state) {
  xorwow_state_words.values[
      ColmapXorwowStateIndex(0u, row, col, width, height)] = state.v0;
  xorwow_state_words.values[
      ColmapXorwowStateIndex(1u, row, col, width, height)] = state.v1;
  xorwow_state_words.values[
      ColmapXorwowStateIndex(2u, row, col, width, height)] = state.v2;
  xorwow_state_words.values[
      ColmapXorwowStateIndex(3u, row, col, width, height)] = state.v3;
  xorwow_state_words.values[
      ColmapXorwowStateIndex(4u, row, col, width, height)] = state.v4;
  xorwow_state_words.values[
      ColmapXorwowStateIndex(5u, row, col, width, height)] = state.d;
}

#endif
