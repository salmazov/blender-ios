/* SPDX-FileCopyrightText: 2001-2002 NaN Holding BV. All rights reserved.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup GHOST
 * Declaration of GHOST_EventTrackpad class.
 */

#pragma once

#include "GHOST_Event.hh"

/**
 * Trackpad (scroll, magnify, rotate, ...) event.
 */
class GHOST_EventTrackpad : public GHOST_Event {
 public:
  /**
   * Constructor.
   * \param msec: The time this event was generated.
   * \param window: The window of this event.
   * \param subtype: The subtype of the event.
   * \param x: The x-delta of the pan event.
   * \param y: The y-delta of the pan event.
   */
  GHOST_EventTrackpad(uint64_t msec,
                      GHOST_IWindow *window,
                      GHOST_TTrackpadEventSubTypes subtype,
                      int32_t x,
                      int32_t y,
                      int32_t deltaX,
                      int32_t deltaY,
                      bool isDirectionInverted,
                      uint numFingers = 1)
      : GHOST_Event(msec, GHOST_kEventTrackpad, window)
  {
    trackpad_event_data_.subtype = subtype;
    trackpad_event_data_.x = x;
    trackpad_event_data_.y = y;
    trackpad_event_data_.deltaX = deltaX;
    trackpad_event_data_.deltaY = deltaY;
    trackpad_event_data_.isDirectionInverted = isDirectionInverted;
    data_ = &trackpad_event_data_;
    m_trackpadEventData.subtype = subtype;
    m_trackpadEventData.x = x;
    m_trackpadEventData.y = y;
    m_trackpadEventData.deltaX = deltaX;
    m_trackpadEventData.deltaY = deltaY;
    m_trackpadEventData.isDirectionInverted = isDirectionInverted;
    m_trackpadEventData.numFingers = numFingers;
    m_data = &m_trackpadEventData;
  }

 protected:
  /** The mouse pan data */
  GHOST_TEventTrackpadData trackpad_event_data_;
};
