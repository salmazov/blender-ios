/* SPDX-FileCopyrightText: 2024-2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup wm
 *
 * C-linkage bridge for iOS lifecycle callbacks.
 * GHOST (which links as a separate static library) calls these functions
 * to access windowmanager/blenkernel APIs without dlsym or mangled C++ names.
 */

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/** Autosave the current session. Safe to call from any thread context. */
void WM_ios_autosave(void *ghost_context);

/** Restart the autosave timer after returning from background. */
void WM_ios_autosave_timer_begin(void *ghost_context);

/** Stop the autosave timer when entering background. */
void WM_ios_autosave_timer_end(void *ghost_context);

/** Trim undo history and free GPU caches to reduce memory pressure. */
void WM_ios_reduce_memory(void *ghost_context);

#ifdef __cplusplus
}
#endif
