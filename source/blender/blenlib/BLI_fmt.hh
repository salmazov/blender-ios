/* SPDX-FileCopyrightText: 2024 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

#pragma once

/** \file
 * \ingroup bli
 *
 * Compatibility wrapper for fmt library headers.
 *
 * On iOS, the standalone fmt library is not available. Instead, the older version
 * bundled with OIIO (fmt 9.1) is used, which includes `fmt::join` in `format.h`.
 * In newer fmt versions (12+), `fmt::join` was moved to `ranges.h`.
 *
 * Include this header instead of `<fmt/ranges.h>` to get `fmt::join` portably.
 */

#include <fmt/format.h>

#if __has_include(<fmt/ranges.h>)
#  include <fmt/ranges.h>
#endif
