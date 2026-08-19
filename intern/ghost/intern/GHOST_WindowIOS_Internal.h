/* SPDX-FileCopyrightText: 2025 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup GHOST
 * Private header for GHOSTUIWindow — shared between GHOST_WindowIOS.mm
 * and category files (GHOST_KeyboardIOS.mm, etc.).
 */

#pragma once

#include "GHOST_WindowIOS.hh"
#include "GHOST_SystemIOS.hh"

#import <GameController/GameController.h>
#import <UIKit/UIKit.h>
#import <UIKit/UIPencilInteraction.h>

/* Forward-declare gesture recognizer subclasses (defined in GHOST_WindowIOS.mm). */
@class GHOSTUITapGestureRecognizer;
@class GHOSTUIPanGestureRecognizer;
@class GHOSTUIPinchGestureRecognizer;
@class GHOSTUIHoverGestureRecognizer;

struct UserInputEvent;

/**
 * GHOSTUIWindow — the main UIWindow subclass used by Blender on iOS.
 * Instance variables are declared here so that Objective-C category files
 * can access them.
 */
@interface GHOSTUIWindow
    : UIWindow <UIGestureRecognizerDelegate, UIPencilInteractionDelegate, UIPointerInteractionDelegate>
{
  @public
  GHOST_SystemIOS *system;
  GHOST_WindowIOS *window;

  GHOSTUITapGestureRecognizer *tap_gesture_recognizer;
  GHOSTUITapGestureRecognizer *tap2f_gesture_recognizer;
  GHOSTUITapGestureRecognizer *tap3f_gesture_recognizer;
  GHOSTUITapGestureRecognizer *tap4f_gesture_recognizer;
  GHOSTUIPanGestureRecognizer *pan_gesture_recognizer;
  GHOSTUIPanGestureRecognizer *pan2f_gesture_recognizer;
  GHOSTUIPanGestureRecognizer *pan3f_gesture_recognizer;
  GHOSTUIPinchGestureRecognizer *zoom_gesture_recognizer;
  GHOSTUIHoverGestureRecognizer *hover_gesture_recognizer;
  UIPencilInteraction *pencil_interaction;
  UIScreenEdgePanGestureRecognizer *edge_swipe_left;
  UIScreenEdgePanGestureRecognizer *edge_swipe_right;
  UILongPressGestureRecognizer *long_press_gesture_recognizer;

  /* Indirect pointer (Bluetooth mouse / trackpad) support. */
  UIPointerInteraction *pointer_interaction;
  UIHoverGestureRecognizer *mouse_hover_recognizer;
  /** Tracks which mouse buttons are currently held (bitmask of UIEventButtonMask values). */
  UIEventButtonMask mouse_buttons_held;
  /** Last known mouse cursor position (scaled to window pixels). */
  int32_t mouse_cursor_x;
  int32_t mouse_cursor_y;
  /** True once we have a valid cursor position from hover or touch. */
  bool mouse_cursor_valid;

  /* Data from the Apple pencil */
  UITouch *current_pencil_touch;
  GHOST_TabletData tablet_data;
  bool last_tap_with_pencil;

  /* Keyboard handling. */
  UITextField *text_field;
  NSString *original_text;
  bool onscreen_keyboard_active;
  char *text_field_string; /* Owned copy (via strdup), freed on reassign. */
  GHOST_KeyboardProperties current_keyboard_properties;
  bool external_keyboard_connected;

  /* Toolbar */
  bool toolbar_enabled;
  UIToolbar *toolbar;
  UIBarButtonItem *toolbar_tip_item;
  UIBarButtonItem *toolbar_live_text_item;
  UIBarButtonItem *toolbar_done_editing_item;
  UIBarButtonItem *toolbar_cancel_editing_item;
}

- (void)setSystemAndWindowIOS:(GHOST_SystemIOS *)sysCocoa windowIOS:(GHOST_WindowIOS *)winCocoa;

/* Scale a point from UIKit coordinates to native pixel coordinates. */
- (CGPoint)logicalLocationOfTouch:(UITouch *)touch;
- (CGPoint)logicalLocationOfGesture:(UIGestureRecognizer *)gesture;
- (void)updateMouseCursorFromTouch:(UITouch *)touch;

/* Blender event generation. */
- (void)generateUserInputEvents:(const UserInputEvent &)event_info;
- (void)pushIndirectPointerCursorEvent;
- (void)pushIndirectPointerButtonEvent:(GHOST_TEventType)event_type
                           buttonMask:(GHOST_TButton)button_mask;
- (void)releaseIndirectPointerButtons;

/* Gesture recognizers. */
- (void)registerGestureRecognizers;
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:
        (UIGestureRecognizer *)otherGestureRecognizer;
- (void)handleTap:(GHOSTUITapGestureRecognizer *)sender;
- (void)handlePan:(GHOSTUIPanGestureRecognizer *)sender;
- (void)handlePan2f:(GHOSTUIPanGestureRecognizer *)sender;
- (void)handlePan3f:(GHOSTUIPanGestureRecognizer *)sender;
- (void)handleZoom:(GHOSTUIPinchGestureRecognizer *)sender;

/* On screen keyboard handling. */
- (UITextField *)getUITextField;
- (const GHOST_TabletData)getTabletData;
- (GHOST_TSuccess)popupOnscreenKeyboard:(const GHOST_KeyboardProperties &)keyboard_properties;
- (GHOST_TSuccess)hideOnscreenKeyboard;
- (const char *)getLastKeyboardString;

/* Frame management. */
- (void)beginFrame;
- (void)endFrame;

@end
