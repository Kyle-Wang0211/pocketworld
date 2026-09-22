// Copyright (c) 2026, PocketWorld contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include "moltenvk_loader.h"

int main() {
  const auto loader =
      pocketworld::official_dense::vulkan::MoltenVkExternalLoader();
  return loader.get_instance_proc_addr == nullptr ? 1 : 0;
}
