/* SPDX-FileCopyrightText: 2024 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

#pragma once

/** \file
 * \ingroup bli
 *
 * Compatibility wrapper for the fmt library.
 *
 * Blender targets fmt 12+ (standalone) on desktop and fmt 9.1 (bundled inside
 * OIIO) on iOS.  The two versions differ in several ways:
 *
 * - `fmt::join` lives in `<fmt/ranges.h>` on 12+, in `<fmt/format.h>` on 9.1.
 * - `fmt::is_range` (used to suppress ambiguous formatters) only exists in
 *   `<fmt/ranges.h>`.
 * - `format_as()` only works for enum types in 9.1; class types need an
 *   explicit `fmt::formatter` specialization.
 *
 * Include **this** header instead of `<fmt/format.h>` or `<fmt/ranges.h>`
 * whenever `fmt::join` or range-related features are needed.
 */

#include <fmt/format.h>

#if __has_include(<fmt/ranges.h>)
#  include <fmt/ranges.h>
#endif

/**
 * Helper: suppress `is_range` for a type when `<fmt/ranges.h>` is available.
 * No-op on fmt 9.1 where `is_range` doesn't exist.
 */
#if __has_include(<fmt/ranges.h>)
#  define BLI_FMT_DISABLE_RANGE(Type) \
    namespace fmt { \
    template<> struct is_range<Type, char> : std::false_type {}; \
    }
#else
#  define BLI_FMT_DISABLE_RANGE(Type)
#endif

/**
 * Declare an explicit `fmt::formatter` that delegates to `std::string_view`.
 *
 * On fmt 12+ the ADL-based `format_as()` works for classes, but fmt 9.1 only
 * supports it for enum types.  This macro produces a specialization that works
 * on every version.  Place it at **namespace scope** after the type is complete.
 *
 * Usage:
 *   BLI_FMT_FORMATTER_STRING_VIEW(blender::UString, s.string())
 */
#define BLI_FMT_FORMATTER_STRING_VIEW(Type, ToStringView) \
  template<> struct fmt::formatter<Type> : fmt::formatter<std::string_view> { \
    auto format(const Type &s, fmt::format_context &ctx) const \
    { \
      return fmt::formatter<std::string_view>::format(ToStringView, ctx); \
    } \
  }
