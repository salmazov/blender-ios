/* SPDX-FileCopyrightText: 2024-2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup wm
 *
 * C-linkage bridge for iOS lifecycle callbacks.
 * See wm_ios_bridge.h for API documentation.
 */

#include "wm_ios_bridge.h"

#include "BKE_context.hh"
#include "BKE_image.hh"
#include "BKE_undo_system.hh"
#include "BKE_wm_runtime.hh"

#include "DNA_userdef_types.h"
#include "DNA_windowmanager_types.h"

#include "GPU_pass.hh"

#include "WM_api.hh"
#include "wm.hh"

extern "C" {

void WM_ios_autosave(void *ghost_context)
{
  blender::bContext *C = static_cast<blender::bContext *>(ghost_context);
  if (!C) {
    return;
  }
  blender::wmWindowManager *wm = blender::CTX_wm_manager(C);
  blender::Main *bmain = blender::CTX_data_main(C);
  if (wm && bmain) {
    blender::WM_autosave_write(wm, bmain);
  }
}

void WM_ios_autosave_timer_begin(void *ghost_context)
{
  blender::bContext *C = static_cast<blender::bContext *>(ghost_context);
  if (!C) {
    return;
  }
  blender::wmWindowManager *wm = blender::CTX_wm_manager(C);
  if (wm) {
    blender::wm_autosave_timer_begin(wm);
  }
}

void WM_ios_autosave_timer_end(void *ghost_context)
{
  blender::bContext *C = static_cast<blender::bContext *>(ghost_context);
  if (!C) {
    return;
  }
  blender::wmWindowManager *wm = blender::CTX_wm_manager(C);
  if (wm) {
    blender::wm_autosave_timer_end(wm);
  }
}

void WM_ios_reduce_memory(void *ghost_context)
{
  blender::bContext *C = static_cast<blender::bContext *>(ghost_context);
  if (!C) {
    return;
  }
  blender::wmWindowManager *wm = blender::CTX_wm_manager(C);
  if (!wm) {
    return;
  }

  /* Trim undo stack to a single step to free memory. */
  if (wm->runtime->undo_stack) {
    blender::BKE_undosys_stack_limit_steps_and_memory(wm->runtime->undo_stack, 1, 0);
  }

  /* Free unused GPU textures cached by images. */
  blender::BKE_image_free_unused_gpu_textures();

  /* Free stale compiled shader passes. */
  blender::GPU_pass_cache_free();
}

}  /* extern "C" */
