/* SPDX-FileCopyrightText: 2025 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

#include "GHOST_WindowIOS.hh"

#include "GHOST_ContextIOS.hh"
#include "GHOST_SystemIOS.hh"

#include "GHOST_C-api.h"
#include "GHOST_Debug.hh"
#include "GHOST_EventButton.hh"
#include "GHOST_EventCursor.hh"
#include "GHOST_EventDragnDrop.hh"

#include <memory>
#include <cmath>
#include "GHOST_EventTouch.hh"
#include "GHOST_EventTrackpad.hh"
#include "GHOST_EventWheel.hh"

#import <GameController/GameController.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <UIKit/UIPencilInteraction.h>

#include <unordered_map>

// #define IOS_INPUT_LOGGING
#if defined(IOS_INPUT_LOGGING)
#  define IOS_INPUT_LOG(...) NSLog(__VA_ARGS__)
#else
#  define IOS_INPUT_LOG(...)
#endif

// #define IOS_WINDOW_LOGGING
#if defined(IOS_WINDOW_LOGGING)
#  define IOS_WINDOW_LOG(...) NSLog(__VA_ARGS__)
#else
#  define IOS_WINDOW_LOG(...)
#endif

struct TouchData {
  CGPoint pos;
  bool part_of_multitouch = false;
};

typedef struct UserInputEvent {
  enum EventTypes {
    CURSOR_MOVE,
    PAN_GESTURE,
    PAN_GESTURE_TWO_FINGERS,
    PAN_GESTURE_THREE_FINGERS,
    PINCH_GESTURE,
    LEFT_BUTTON_DOWN,
    LEFT_BUTTON_UP,
    RIGHT_BUTTON_DOWN,
    RIGHT_BUTTON_UP,
    MIDDLE_BUTTON_DOWN,
    MIDDLE_BUTTON_UP,
    PENCIL_TAP,
  };
  EventTypes event_list[10];
  int num_events;
  CGPoint location;
  CGPoint translation;
  CGFloat distance;
  bool pencil_used;

  UserInputEvent(CGPoint *loc, CGPoint *tran, CGFloat *dist, bool pencil)
  {
    num_events = 0;
    location = loc ? *loc : CGPointMake(-1.0f, -1.0f);
    translation = tran ? *tran : CGPointMake(0.0f, 0.0f);
    distance = dist ? *dist : 0.0f;
    pencil_used = pencil;
  }

  void add_event(EventTypes event_type)
  {
    GHOST_ASSERT(num_events < sizeof(event_list) / sizeof(*event_list),
                 "add_event: Failed to add event");
    event_list[num_events] = event_type;
    num_events++;
  }

  NSString *getEventTypeDesc(EventTypes event_type) const
  {
    switch (event_type) {
      case CURSOR_MOVE:
        return @"CM";
      case PAN_GESTURE:
        return @"PAN";
      case PAN_GESTURE_TWO_FINGERS:
        return @"PAN2F";
      case PAN_GESTURE_THREE_FINGERS:
        return @"PAN3F";
      case PINCH_GESTURE:
        return @"PINCH";
      case LEFT_BUTTON_DOWN:
        return @"LB-DOWN";
      case LEFT_BUTTON_UP:
        return @"LB-UP";
      case RIGHT_BUTTON_DOWN:
        return @"RB-DOWN";
      case RIGHT_BUTTON_UP:
        return @"RB-UP";
      case MIDDLE_BUTTON_DOWN:
        return @"MB-DOWN";
      case MIDDLE_BUTTON_UP:
        return @"MB-UP";
      case PENCIL_TAP:
        return @"PENCIL-TAP";
    }
    BLI_assert_unreachable();
    return @"Event undefined";
  }

} UserInputEvent;

/* GHOSTUITapGesture interface for capturing taps. */
@interface GHOSTUITapGestureRecognizer : UITapGestureRecognizer

- (CGPoint)getScaledTouchPoint:(GHOST_WindowIOS *)window;

@end

@implementation GHOSTUITapGestureRecognizer

- (CGPoint)getScaledTouchPoint:(GHOST_WindowIOS *)window
{
  CGPoint touch_point = [self locationInView:window->getView()];
  return window->scalePointToWindow(touch_point);
}

@end

/* GHOSTUITapGesture interface for capturing taps. */
@interface GHOSTUIPanGestureRecognizer : UIPanGestureRecognizer
{
  CGPoint cached_translation;
}
- (CGPoint)getScaledTouchPoint:(GHOST_WindowIOS *)window;
- (CGPoint)getScaledTranslation:(GHOST_WindowIOS *)window;

- (void)setCachedTranslation:(CGPoint)translation;
- (CGPoint)getCachedTranslation;
@end

@implementation GHOSTUIPanGestureRecognizer

- (CGPoint)getScaledTouchPoint:(GHOST_WindowIOS *)window
{
  CGPoint touch_point = [self locationInView:window->getView()];
  return window->scalePointToWindow(touch_point);
}

- (CGPoint)getScaledTranslation:(GHOST_WindowIOS *)window
{
  CGPoint translation = [self translationInView:window->getView()];
  return window->scalePointToWindow(translation);
}

- (CGPoint)getRelativeTranslation:(CGPoint)translation
{
  CGPoint relative_translation;
  relative_translation.x = translation.x - cached_translation.x;
  relative_translation.y = translation.y - cached_translation.y;
  return relative_translation;
}

- (void)setCachedTranslation:(CGPoint)translation
{
  cached_translation = translation;
}

- (CGPoint)getCachedTranslation
{
  return cached_translation;
}
@end

@interface GHOSTUIHoverGestureRecognizer : UIHoverGestureRecognizer
- (CGPoint)getScaledTouchPoint:(GHOST_WindowIOS *)window;
@end

@implementation GHOSTUIHoverGestureRecognizer

- (CGPoint)getScaledTouchPoint:(GHOST_WindowIOS *)window
{
  CGPoint touch_point = [self locationInView:window->getView()];
  return window->scalePointToWindow(touch_point);
}
@end

@interface GHOSTUIPinchGestureRecognizer : UIPinchGestureRecognizer
{
  CGFloat cached_distance;
}
- (CGPoint)getScaledTouchPoint:(GHOST_WindowIOS *)window touch_id:(int)touch_id;
- (CGFloat)getScaledDistance:(GHOST_WindowIOS *)window;
- (CGPoint)getPinchMidpoint:(GHOST_WindowIOS *)window;
- (void)setCachedDistance:(CGFloat)distance;
- (CGFloat)getCachedDistance;
@end

@implementation GHOSTUIPinchGestureRecognizer
- (CGPoint)getScaledTouchPoint:(GHOST_WindowIOS *)window touch_id:(int)touch_id
{
  CGPoint touch_point = [self locationOfTouch:touch_id inView:window->getView()];
  return window->scalePointToWindow(touch_point);
}

- (CGFloat)getScaledDistance:(GHOST_WindowIOS *)window
{
  CGPoint touch_point0 = [self locationOfTouch:0 inView:window->getView()];
  CGPoint touch_point1 = [self locationOfTouch:1 inView:window->getView()];
  touch_point0 = window->scalePointToWindow(touch_point0);
  touch_point1 = window->scalePointToWindow(touch_point1);
  float dx = touch_point1.x - touch_point0.x;
  float dy = touch_point1.y - touch_point0.y;
  CGFloat point_distance = sqrt(dx * dx + dy * dy);
  return point_distance;
}

- (CGPoint)getPinchMidpoint:(GHOST_WindowIOS *)window
{
  CGPoint touch_point0 = [self locationOfTouch:0 inView:window->getView()];
  CGPoint touch_point1 = [self locationOfTouch:1 inView:window->getView()];
  touch_point0 = window->scalePointToWindow(touch_point0);
  touch_point1 = window->scalePointToWindow(touch_point1);
  CGPoint midPoint = CGPointMake((touch_point0.x + touch_point1.x) / 2.0f,
                                 (touch_point0.y + touch_point1.y) / 2.0f);
  return midPoint;
}

- (void)setCachedDistance:(CGFloat)distance
{
  cached_distance = distance;
}

- (CGFloat)getCachedDistance
{
  return cached_distance;
}
@end

/* GHOSTUIWindow interface is in the shared private header. */
#include "GHOST_WindowIOS_Internal.h"

@implementation GHOSTUIWindow
- (void)setSystemAndWindowIOS:(GHOST_SystemIOS *)sys windowIOS:(GHOST_WindowIOS *)win
{
  system = sys;
  window = win;
  text_field = nil;
  original_text = nil;
  onscreen_keyboard_active = false;
  text_field_string = nullptr;
  current_pencil_touch = nil;
  tablet_data = GHOST_TABLET_DATA_NONE;
  toolbar_enabled = true;
  toolbar = nil;
  last_tap_with_pencil = false;
  mouse_buttons_held = 0;
  mouse_cursor_x = 0;
  mouse_cursor_y = 0;
  mouse_cursor_valid = false;
  external_keyboard_connected = [GCKeyboard coalescedKeyboard] != nil;

  /* Check whether we've linked the GameController framework. */
  if (&GCKeyboardDidConnectNotification != NULL) {
    /* Register for notifcations an external keyboard has been added/removed. */
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(externalKeyboardChange:)
                                                 name:GCKeyboardDidConnectNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(externalKeyboardChange:)
                                                 name:GCKeyboardDidDisconnectNotification
                                               object:nil];
  }
}

- (CGPoint)logicalLocationOfTouch:(UITouch *)touch
{
  return [touch locationInView:window->getView()];
}

- (CGPoint)logicalLocationOfGesture:(UIGestureRecognizer *)gesture
{
  return [gesture locationInView:window->getView()];
}

- (void)updateMouseCursorFromTouch:(UITouch *)touch
{
  CGPoint loc = [self logicalLocationOfTouch:touch];
  mouse_cursor_x = (int32_t)loc.x;
  mouse_cursor_y = (int32_t)loc.y;
}

- (void)registerGestureRecognizers
{
  /** Create Gesture recognisers. */
  /* Tap gesture recognizer. */
  tap_gesture_recognizer = [[GHOSTUITapGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleTap:)];
  tap_gesture_recognizer.delegate = self;
  tap_gesture_recognizer.cancelsTouchesInView = false;
  tap_gesture_recognizer.allowedTouchTypes = @[ @(UITouchTypePencil), @(UITouchTypeDirect) ];
  [window->getView() addGestureRecognizer:tap_gesture_recognizer];

  /* Two-finger tap gesture recognizer. */
  tap2f_gesture_recognizer = [[GHOSTUITapGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleTap2F:)];
  tap2f_gesture_recognizer.delegate = self;
  tap2f_gesture_recognizer.cancelsTouchesInView = false;
  tap2f_gesture_recognizer.delaysTouchesBegan = YES;
  tap2f_gesture_recognizer.numberOfTouchesRequired = 2;
  [window->getView() addGestureRecognizer:tap2f_gesture_recognizer];

  /* Three-finger tap gesture recognizer. */
  tap3f_gesture_recognizer = [[GHOSTUITapGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleTap3F:)];
  tap3f_gesture_recognizer.delegate = self;
  tap3f_gesture_recognizer.cancelsTouchesInView = false;
  tap3f_gesture_recognizer.delaysTouchesBegan = YES;
  tap3f_gesture_recognizer.numberOfTouchesRequired = 3;
  [window->getView() addGestureRecognizer:tap3f_gesture_recognizer];

  /* Four-finger tap gesture recognizer. */
  tap4f_gesture_recognizer = [[GHOSTUITapGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleTap4F:)];
  tap4f_gesture_recognizer.delegate = self;
  tap4f_gesture_recognizer.cancelsTouchesInView = false;
  tap4f_gesture_recognizer.delaysTouchesBegan = YES;
  tap4f_gesture_recognizer.numberOfTouchesRequired = 4;
  [window->getView() addGestureRecognizer:tap4f_gesture_recognizer];

  /* Pan gesture recognizer - static UI. */
  pan_gesture_recognizer = [[GHOSTUIPanGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handlePan:)];
  pan_gesture_recognizer.delegate = self;
  pan_gesture_recognizer.cancelsTouchesInView = false;
  /* Allow scrolling only with a single finger. */
  pan_gesture_recognizer.minimumNumberOfTouches = 1;
  pan_gesture_recognizer.maximumNumberOfTouches = 1;
  /* Allow finger and pencil. */
  pan_gesture_recognizer.allowedTouchTypes = @[ @(UITouchTypePencil), @(UITouchTypeDirect) ];
  [window->getView() addGestureRecognizer:pan_gesture_recognizer];

  /* Pan gesture recognizer - two fingers 3D UI. */
  pan2f_gesture_recognizer = [[GHOSTUIPanGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handlePan2f:)];
  pan2f_gesture_recognizer.delegate = self;
  pan2f_gesture_recognizer.cancelsTouchesInView = false;
  /* Two finger gestures only.  */
  pan2f_gesture_recognizer.minimumNumberOfTouches = 2;
  pan2f_gesture_recognizer.maximumNumberOfTouches = 2;
  [window->getView() addGestureRecognizer:pan2f_gesture_recognizer];

  /* Pan gesture recognizer - three fingers for viewport panning. */
  pan3f_gesture_recognizer = [[GHOSTUIPanGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handlePan3f:)];
  pan3f_gesture_recognizer.delegate = self;
  pan3f_gesture_recognizer.cancelsTouchesInView = false;
  pan3f_gesture_recognizer.minimumNumberOfTouches = 3;
  pan3f_gesture_recognizer.maximumNumberOfTouches = 3;
  [window->getView() addGestureRecognizer:pan3f_gesture_recognizer];

  /* Pinch/Zoom gesture recognizer. */
  zoom_gesture_recognizer = [[GHOSTUIPinchGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleZoom:)];
  zoom_gesture_recognizer.delegate = self;
  zoom_gesture_recognizer.cancelsTouchesInView = false;
  [window->getView() addGestureRecognizer:zoom_gesture_recognizer];

  /* Edge swipe. */
  edge_swipe_left = [[UIScreenEdgePanGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleEdgeSwipe:)];
  edge_swipe_left.edges = UIRectEdgeLeft;
  edge_swipe_left.delegate = self;
  [window->getView() addGestureRecognizer:edge_swipe_left];

  edge_swipe_right = [[UIScreenEdgePanGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleEdgeSwipe:)];
  edge_swipe_right.edges = UIRectEdgeRight;
  edge_swipe_right.delegate = self;
  [window->getView() addGestureRecognizer:edge_swipe_right];

  /* Apple Pencil hover recognizer. */
  hover_gesture_recognizer = [[GHOSTUIHoverGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleHover:)];
  hover_gesture_recognizer.delegate = self;
  [window->getView() addGestureRecognizer:hover_gesture_recognizer];
  current_pencil_touch = nil;

  /**  Apple Pencil double-tap. */
  pencil_interaction = [[UIPencilInteraction alloc] init];
  pencil_interaction.delegate = self;
  [window->getView() addInteraction:pencil_interaction];

  /* Long-press for finger right-click (context menus). */
  long_press_gesture_recognizer = [[UILongPressGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleLongPress:)];
  long_press_gesture_recognizer.minimumPressDuration = 0.4;
  long_press_gesture_recognizer.numberOfTouchesRequired = 1;
  long_press_gesture_recognizer.allowedTouchTypes = @[ @(UITouchTypeDirect) ];
  long_press_gesture_recognizer.delegate = self;
  [window->getView() addGestureRecognizer:long_press_gesture_recognizer];

  /* Bluetooth mouse / trackpad: pointer interaction for cursor style. */
  if (@available(iOS 13.4, *)) {
    pointer_interaction = [[UIPointerInteraction alloc] initWithDelegate:self];
    [window->getView() addInteraction:pointer_interaction];

    /* Hover gesture recognizer for indirect pointer (mouse cursor movement). */
    mouse_hover_recognizer = [[UIHoverGestureRecognizer alloc]
        initWithTarget:self
                action:@selector(handleMouseHover:)];
    mouse_hover_recognizer.allowedTouchTypes = @[ @(UITouchTypeIndirectPointer) ];
    [window->getView() addGestureRecognizer:mouse_hover_recognizer];
  }

  /* GCMouse for scroll-wheel events from Bluetooth mice. */
  if (@available(iOS 14.0, *)) {
    if (&GCMouseDidConnectNotification != NULL) {
      [[NSNotificationCenter defaultCenter] addObserver:self
                                               selector:@selector(mouseDidConnect:)
                                                   name:GCMouseDidConnectNotification
                                                 object:nil];
      [[NSNotificationCenter defaultCenter] addObserver:self
                                               selector:@selector(mouseDidDisconnect:)
                                                   name:GCMouseDidDisconnectNotification
                                                 object:nil];
      /* Attach to any already-connected mouse. */
      GCMouse *mouse = [GCMouse current];
      if (mouse) {
        [self setupGCMouse:mouse];
      }
    }
  }
}

/* Turn the user inputs into Blender events.
 * We batch up the events rather than send them directly in the gesture
 * recognisers to ensure we don't interleave events if we detect simultaneous
 * inputs. */
- (void)generateUserInputEvents:(const UserInputEvent &)event_info
{
  /* Lock access to ensure all input-events are received sequentially. */
  @synchronized(self) {
    for (int i = 0; i < event_info.num_events; i++) {
      UserInputEvent::EventTypes event_type = event_info.event_list[i];
      IOS_INPUT_LOG(@"%d-%@ %f,%f",
                    i,
                    event_info.getEventTypeDesc(event_type),

                  - (void)pushIndirectPointerCursorEvent
                  {
                    system->pushEvent(std::make_unique<GHOST_EventCursor>(system->getMilliSeconds(),
                                                            GHOST_kEventCursorMove,
                                                            window,
                                                            mouse_cursor_x,
                                                            mouse_cursor_y,
                                                            GHOST_TABLET_DATA_NONE));
                  }

                  - (void)pushIndirectPointerButtonEvent:(GHOST_TEventType)event_type
                                             buttonMask:(GHOST_TButton)button_mask
                  {
                    system->pushEvent(std::make_unique<GHOST_EventButton>(system->getMilliSeconds(),
                                                            event_type,
                                                            window,
                                                            button_mask,
                                                            GHOST_TABLET_DATA_NONE));
                  }

                  - (void)releaseIndirectPointerButtons
                  {
                    if (mouse_buttons_held & UIEventButtonMaskPrimary) {
                      [self pushIndirectPointerButtonEvent:GHOST_kEventButtonUp buttonMask:GHOST_kButtonMaskLeft];
                    }
                    if (mouse_buttons_held & UIEventButtonMaskSecondary) {
                      [self pushIndirectPointerButtonEvent:GHOST_kEventButtonUp buttonMask:GHOST_kButtonMaskRight];
                    }
                    mouse_buttons_held = 0;
                  }
                    event_info.location.x,
                    event_info.location.y);

      switch (event_type) {
        case UserInputEvent::EventTypes::CURSOR_MOVE:
          system->pushEvent(
              std::make_unique<GHOST_EventCursor>(system->getMilliSeconds(),
                                    GHOST_kEventCursorMove,
                                    window,
                                    event_info.location.x,
                                    event_info.location.y,
                                    tablet_data));
          break;
        case UserInputEvent::EventTypes::PAN_GESTURE:
          system->pushEvent(
              std::make_unique<GHOST_EventTrackpad>(system->getMilliSeconds(),
                                      window,
                                      GHOST_kTrackpadEventScroll,
                                      event_info.location.x,
                                      event_info.location.y,
                                      event_info.translation.x,
                                      event_info.translation.y,
                                      false,
                                      1));
          break;
        case UserInputEvent::EventTypes::PAN_GESTURE_TWO_FINGERS:
          system->pushEvent(
              std::make_unique<GHOST_EventTrackpad>(system->getMilliSeconds(),
                                      window,
                                      GHOST_kTrackpadEventScroll,
                                      event_info.location.x,
                                      event_info.location.y,
                                      event_info.translation.x,
                                      event_info.translation.y,
                                      true,
                                      2));
          break;
        case UserInputEvent::EventTypes::PAN_GESTURE_THREE_FINGERS:
          system->pushEvent(
              std::make_unique<GHOST_EventTrackpad>(system->getMilliSeconds(),
                                      window,
                                      GHOST_kTrackpadEventScroll,
                                      event_info.location.x,
                                      event_info.location.y,
                                      event_info.translation.x,
                                      event_info.translation.y,
                                      true,
                                      3));
          break;
        case UserInputEvent::EventTypes::LEFT_BUTTON_DOWN:
          system->pushEvent(
              std::make_unique<GHOST_EventButton>(system->getMilliSeconds(),
                                    GHOST_kEventButtonDown,
                                    window,
                                    GHOST_kButtonMaskLeft,
                                    tablet_data));
          break;
        case UserInputEvent::EventTypes::LEFT_BUTTON_UP:
          system->pushEvent(
              std::make_unique<GHOST_EventButton>(system->getMilliSeconds(),
                                    GHOST_kEventButtonUp,
                                    window,
                                    GHOST_kButtonMaskLeft,
                                    tablet_data));
          break;
        case UserInputEvent::EventTypes::PINCH_GESTURE:
          system->pushEvent(
              std::make_unique<GHOST_EventTrackpad>(system->getMilliSeconds(),
                                      window,
                                      GHOST_kTrackpadEventMagnify,
                                      event_info.location.x,
                                      event_info.location.y,
                                      event_info.distance,
                                      0,
                                      false,
                                      2));
          break;
        case UserInputEvent::EventTypes::RIGHT_BUTTON_DOWN:
          system->pushEvent(
              std::make_unique<GHOST_EventButton>(system->getMilliSeconds(),
                                    GHOST_kEventButtonDown,
                                    window,
                                    GHOST_kButtonMaskRight,
                                    tablet_data));
          break;
        case UserInputEvent::EventTypes::RIGHT_BUTTON_UP:
          system->pushEvent(
              std::make_unique<GHOST_EventButton>(system->getMilliSeconds(),
                                    GHOST_kEventButtonUp,
                                    window,
                                    GHOST_kButtonMaskRight,
                                    tablet_data));
          break;
        case UserInputEvent::EventTypes::MIDDLE_BUTTON_DOWN:
          system->pushEvent(
              std::make_unique<GHOST_EventButton>(system->getMilliSeconds(),
                                    GHOST_kEventButtonDown,
                                    window,
                                    GHOST_kButtonMaskMiddle,
                                    tablet_data));
          break;
        case UserInputEvent::EventTypes::MIDDLE_BUTTON_UP:
          system->pushEvent(
              std::make_unique<GHOST_EventButton>(system->getMilliSeconds(),
                                    GHOST_kEventButtonUp,
                                    window,
                                    GHOST_kButtonMaskMiddle,
                                    tablet_data));
          break;
        case UserInputEvent::EventTypes::PENCIL_TAP:
          /* Simulate clicking with the right mouse button. */
          system->pushEvent(
              std::make_unique<GHOST_EventButton>(system->getMilliSeconds(),
                                    GHOST_kEventButtonDown,
                                    window,
                                    GHOST_kButtonMaskRight,
                                    tablet_data));
          break;
        default:
          GHOST_ASSERT(FALSE, "GHOST_SystemIOS::generateUserInputEvents unsupported event type");
      }
    }
  }
}

/* Allow simultaneous gestures for multi-finger pans and zooms. */
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:
        (UIGestureRecognizer *)otherGestureRecognizer
{
  if (gestureRecognizer == pan2f_gesture_recognizer &&
      otherGestureRecognizer == zoom_gesture_recognizer)
  {
    return YES;
  }
  if (gestureRecognizer == pan_gesture_recognizer &&
      otherGestureRecognizer == zoom_gesture_recognizer)
  {
    return YES;
  }
  if (gestureRecognizer == pan3f_gesture_recognizer &&
      otherGestureRecognizer == zoom_gesture_recognizer)
  {
    return YES;
  }
  if (gestureRecognizer == pan3f_gesture_recognizer &&
      otherGestureRecognizer == pan2f_gesture_recognizer)
  {
    return YES;
  }
  return NO;
}

/* Get updated tablet data. */
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
  [super touchesMoved:touches withEvent:event];

  for (UITouch *touch in touches) {
    /* Indirect pointer (mouse / trackpad) drag. */
    if (@available(iOS 13.4, *)) {
      if (touch.type == UITouchTypeIndirectPointer) {
        [self updateMouseCursorFromTouch:touch];

        system->pushEvent(std::make_unique<GHOST_EventCursor>(system->getMilliSeconds(),
                                                GHOST_kEventCursorMove,
                                                window,
                                                mouse_cursor_x,
                                                mouse_cursor_y,
                                                GHOST_TABLET_DATA_NONE));
        system->notifyExternalEventProcessed();
        return;
      }
    }

    /* Apple Pencil pressure and tilt tracking. */
    if (touch.type == UITouchTypePencil) {
      current_pencil_touch = touch;

      tablet_data.Active = GHOST_kTabletModeStylus;

      /* Map apple pressure range to Blender range: 0.0 (not touching) to 1.0 (full pressure). */
      tablet_data.Pressure = current_pencil_touch.force /
                             current_pencil_touch.maximumPossibleForce;

      CGFloat azimuthAngle = [current_pencil_touch azimuthAngleInView:window->getView()];
      CGFloat altitudeAngle = [current_pencil_touch altitudeAngle];

      /* Calculate the maximum possible tilt (1.0) when altitude is 0. */
      CGFloat maxTilt = cos(0);

      /* Convert to x and y tilt - range -1.0 (left) to +1.0 (right). */
      tablet_data.Xtilt = sin(azimuthAngle) * cos(altitudeAngle) / maxTilt;
      tablet_data.Ytilt = -cos(azimuthAngle) * cos(altitudeAngle) / maxTilt;
      IOS_INPUT_LOG(
          @"TABLET: X:%f,Y:%f,P:%f", tablet_data.Xtilt, tablet_data.Ytilt, tablet_data.Pressure);
      break;
    }
  }
}

/* Reset tablet data only when the pencil touch itself ends. */
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
  [super touchesEnded:touches withEvent:event];
  for (UITouch *touch in touches) {
    /* Indirect pointer (mouse / trackpad) button release. */
    if (@available(iOS 13.4, *)) {
      if (touch.type == UITouchTypeIndirectPointer) {
        [self updateMouseCursorFromTouch:touch];

        [self pushIndirectPointerCursorEvent];

        /* Release buttons that were held (left / right).
         * Middle button is handled via GCMouse. */
        [self releaseIndirectPointerButtons];
        system->notifyExternalEventProcessed();
        return;
      }
    }

    if (touch.type == UITouchTypePencil) {
      current_pencil_touch = nil;
      tablet_data = GHOST_TABLET_DATA_NONE;
      break;
    }
  }
}

/* Reset tablet data only when the pencil touch itself is cancelled. */
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
  [super touchesCancelled:touches withEvent:event];
  for (UITouch *touch in touches) {
    if (@available(iOS 13.4, *)) {
      if (touch.type == UITouchTypeIndirectPointer) {
        /* Treat cancellation as release. */
        [self releaseIndirectPointerButtons];
        system->notifyExternalEventProcessed();
        return;
      }
    }

    if (touch.type == UITouchTypePencil) {
      current_pencil_touch = nil;
      tablet_data = GHOST_TABLET_DATA_NONE;
      break;
    }
  }
}

- (void)handleTap:(GHOSTUITapGestureRecognizer *)sender
{
  CGPoint touch_point = [sender getScaledTouchPoint:window];
  last_tap_with_pencil = current_pencil_touch ? true : false;
  UserInputEvent event_info(&touch_point, nullptr, nullptr, last_tap_with_pencil);

  /* Send events to indicate a 'click' on event end. */
  if (sender.state == UIGestureRecognizerStateEnded) {
    event_info.add_event(UserInputEvent::EventTypes::CURSOR_MOVE);
    event_info.add_event(UserInputEvent::EventTypes::LEFT_BUTTON_DOWN);
    event_info.add_event(UserInputEvent::EventTypes::LEFT_BUTTON_UP);
  }

  [self generateUserInputEvents:event_info];
}

- (void)handleMultiFingerTap:(UIGestureRecognizer *)sender
                   eventType:(GHOST_TEventType)eventType
{
  if (sender.state != UIGestureRecognizerStateEnded) {
    return;
  }
  system->pushEvent(
      std::make_unique<GHOST_Event>(system->getMilliSeconds(), eventType, window));
}

- (void)handleTap2F:(GHOSTUITapGestureRecognizer *)sender
{
  [self handleMultiFingerTap:sender eventType:GHOST_kEventTwoFingerTap];
}

- (void)handleTap3F:(GHOSTUITapGestureRecognizer *)sender
{
  [self handleMultiFingerTap:sender eventType:GHOST_kEventThreeFingerTap];
}

- (void)handleTap4F:(GHOSTUITapGestureRecognizer *)sender
{
  [self handleMultiFingerTap:sender eventType:GHOST_kEventFourFingerTap];
}

- (void)handlePan:(GHOSTUIPanGestureRecognizer *)sender
{
  CGPoint touch_point = [sender getScaledTouchPoint:window];
  CGPoint translation = [sender getScaledTranslation:window];
  bool pencil_pan = current_pencil_touch ? true : false;

  UserInputEvent event_info(&touch_point, nullptr, nullptr, pencil_pan);

  if (sender.state == UIGestureRecognizerStateBegan ||
      sender.state == UIGestureRecognizerStateChanged)
  {
    /* Register initial click for click and drag support. */
    if (sender.state == UIGestureRecognizerStateBegan) {
      /* Set inital translation */
      [sender setCachedTranslation:translation];
      event_info.add_event(UserInputEvent::EventTypes::CURSOR_MOVE);
      event_info.add_event(UserInputEvent::EventTypes::LEFT_BUTTON_DOWN);
    }

    /* Calculate translation change since last begin/change event */
    CGPoint relative_translation = [sender getRelativeTranslation:translation];
    /* Update cached translation */
    [sender setCachedTranslation:translation];
    /* Send pan event if non zero */
    if (!CGPointEqualToPoint(relative_translation, CGPointMake(0.0f, 0.0f))) {
      event_info.translation = relative_translation;
      event_info.add_event(UserInputEvent::EventTypes::PAN_GESTURE);
    }

    /* Update cursor position on change */
    if (sender.state == UIGestureRecognizerStateChanged) {
      event_info.add_event(UserInputEvent::EventTypes::CURSOR_MOVE);
    }
  }

  /* Mouse release for pan. */
  if (sender.state == UIGestureRecognizerStateEnded ||
      sender.state == UIGestureRecognizerStateCancelled ||
      sender.state == UIGestureRecognizerStateFailed)
  {
    /* Send a final cursor-move so Blender knows the exact release position
     * before processing the button-up. */
    event_info.add_event(UserInputEvent::EventTypes::CURSOR_MOVE);
    event_info.add_event(UserInputEvent::EventTypes::LEFT_BUTTON_UP);
  }
  [self generateUserInputEvents:event_info];
}

- (void)handlePan2f:(GHOSTUIPanGestureRecognizer *)sender
{
  /* Translation can be non-zero on begin event */
  if (sender.state == UIGestureRecognizerStateBegan ||
      sender.state == UIGestureRecognizerStateChanged)
  {
    CGPoint translation = [sender getScaledTranslation:window];

    /* Calculate translation relative to previous cached value. */
    CGPoint relative_translation = [sender getRelativeTranslation:translation];

    /* Cache new translation. */
    [sender setCachedTranslation:translation];

    /* Generate pan event if translation is non zero. */
    if (!CGPointEqualToPoint(relative_translation, CGPointMake(0.0f, 0.0f))) {
      CGPoint touch_point = [sender getScaledTouchPoint:window];
      bool pencil_pan = current_pencil_touch ? true : false;
      UserInputEvent event_info(&touch_point, &relative_translation, nullptr, pencil_pan);
      event_info.add_event(UserInputEvent::EventTypes::PAN_GESTURE_TWO_FINGERS);
      [self generateUserInputEvents:event_info];
    }
  }
  else if (sender.state == UIGestureRecognizerStateEnded ||
           sender.state == UIGestureRecognizerStateCancelled ||
           sender.state == UIGestureRecognizerStateFailed)
  {
    /* Set translation back to zero. */
    [sender setCachedTranslation:CGPointMake(0.0f, 0.0f)];
  }
}

- (void)handlePan3f:(GHOSTUIPanGestureRecognizer *)sender
{
  if (sender.state == UIGestureRecognizerStateBegan ||
      sender.state == UIGestureRecognizerStateChanged)
  {
    CGPoint translation = [sender getScaledTranslation:window];
    CGPoint relative_translation = [sender getRelativeTranslation:translation];
    [sender setCachedTranslation:translation];

    if (!CGPointEqualToPoint(relative_translation, CGPointMake(0.0f, 0.0f))) {
      CGPoint touch_point = [sender getScaledTouchPoint:window];
      UserInputEvent event_info(&touch_point, &relative_translation, nullptr, false);
      event_info.add_event(UserInputEvent::EventTypes::PAN_GESTURE_THREE_FINGERS);
      [self generateUserInputEvents:event_info];
    }
  }
  else if (sender.state == UIGestureRecognizerStateEnded ||
           sender.state == UIGestureRecognizerStateCancelled ||
           sender.state == UIGestureRecognizerStateFailed)
  {
    [sender setCachedTranslation:CGPointMake(0.0f, 0.0f)];
  }
}

- (void)handleEdgeSwipe:(UIScreenEdgePanGestureRecognizer *)gesture
{
  if (gesture.state != UIGestureRecognizerStateEnded) {
    return;
  }

  UIView *view = window->getView();
  CGPoint location = [gesture locationInView:view];
  CGSize viewSize = view.bounds.size;

  GHOST_TTouchEventSubTypes ghostEventType;

  if (gesture.edges == UIRectEdgeLeft) {
    ghostEventType = GHOST_kTouchEventEdgeSwipeInLeft;
  }
  else if (gesture.edges == UIRectEdgeRight) {
    ghostEventType = GHOST_kTouchEventEdgeSwipeInRight;
  }
  else {
    /* For now only handle left/right. */
    return;
  }

  system->pushEvent(std::make_unique<GHOST_EventTouch>(
      system->getMilliSeconds(), window, ghostEventType, location.x, location.y));
}

- (void)handleHover:(GHOSTUIHoverGestureRecognizer *)sender
{
  if (sender.state == UIGestureRecognizerStateBegan ||
      sender.state == UIGestureRecognizerStateChanged)
  {
    /* Tablet needs to be set to stylus mode because we need
     * wmTabletData.is_motion_absolute set to true. */
    tablet_data.Active = GHOST_kTabletModeStylus;
    CGPoint hover_point = [sender getScaledTouchPoint:window];
    /* Add cursor move event. */
    UserInputEvent event_info(&hover_point, nullptr, nullptr, true);
    event_info.add_event(UserInputEvent::EventTypes::CURSOR_MOVE);
    [self generateUserInputEvents:event_info];
  }
  else if (sender.state == UIGestureRecognizerStateEnded ||
           sender.state == UIGestureRecognizerStateCancelled ||
           sender.state == UIGestureRecognizerStateFailed)
  {
    tablet_data = GHOST_TABLET_DATA_NONE;
  }
}

- (void)handleZoom:(GHOSTUIPinchGestureRecognizer *)sender
{
  /* Ignore any calls where don't have two touches to work with. */
  if ([sender numberOfTouches] < 2) {
    return;
  }

  /* Pinch/Zoom gestures */
  if (sender.state == UIGestureRecognizerStateBegan) {
    /* Set an initial distance value. */
    CGFloat point_distance = [sender getScaledDistance:window];
    [sender setCachedDistance:point_distance];
  }
  else if (sender.state == UIGestureRecognizerStateChanged) {

    /* Calculate change in distance since last event */
    CGFloat point_distance = [sender getScaledDistance:window];
    CGFloat relative_dist = point_distance - [sender getCachedDistance];

    /* Updated cached distance. */
    [sender setCachedDistance:point_distance];

    /* Send pinch/zoom event. */
    if (fabs(relative_dist) > 0.0) {
      /* Calculate midpoint between the two touch points. */
      CGPoint midPoint = [sender getPinchMidpoint:window];

      UserInputEvent event_info(&midPoint, nullptr, &relative_dist, false);
      event_info.add_event(UserInputEvent::EventTypes::PINCH_GESTURE);
      [self generateUserInputEvents:event_info];
    }
  }
  /* Nothing to do here. */
  else if (sender.state == UIGestureRecognizerStateEnded ||
           sender.state == UIGestureRecognizerStateCancelled ||
           sender.state == UIGestureRecognizerStateFailed)
  {
  }
}

- (void)pencilInteractionDidTap:(UIPencilInteraction *)interaction
{
  UserInputEvent event_info(nullptr, nullptr, nullptr, true);
  event_info.add_event(UserInputEvent::EventTypes::PENCIL_TAP);
  [self generateUserInputEvents:event_info];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)sender
{
  CGPoint touch_point = [self logicalLocationOfGesture:sender];

  if (sender.state == UIGestureRecognizerStateBegan) {
    /* Move cursor to long-press location, then send right-click down. */
    system->pushEvent(
        std::make_unique<GHOST_EventCursor>(system->getMilliSeconds(),
                              GHOST_kEventCursorMove,
                              window,
                              touch_point.x,
                              touch_point.y,
                              GHOST_TABLET_DATA_NONE));
    system->pushEvent(
        std::make_unique<GHOST_EventButton>(system->getMilliSeconds(),
                              GHOST_kEventButtonDown,
                              window,
                              GHOST_kButtonMaskRight,
                              GHOST_TABLET_DATA_NONE));
  }
  else if (sender.state == UIGestureRecognizerStateEnded ||
           sender.state == UIGestureRecognizerStateCancelled)
  {
    /* Release right-click. */
    system->pushEvent(
        std::make_unique<GHOST_EventButton>(system->getMilliSeconds(),
                              GHOST_kEventButtonUp,
                              window,
                              GHOST_kButtonMaskRight,
                              GHOST_TABLET_DATA_NONE));
  }
}

#pragma mark - Bluetooth Mouse / Trackpad

/**
 * Hover recognizer for indirect pointer (mouse / trackpad) — cursor movement without buttons.
 */
- (void)handleMouseHover:(UIHoverGestureRecognizer *)sender
{
  if (sender.state == UIGestureRecognizerStateBegan ||
      sender.state == UIGestureRecognizerStateChanged)
  {
    CGPoint loc = [self logicalLocationOfGesture:sender];
    mouse_cursor_x = (int32_t)loc.x;
    mouse_cursor_y = (int32_t)loc.y;
    mouse_cursor_valid = true;

    [self pushIndirectPointerCursorEvent];
    system->notifyExternalEventProcessed();
  }
}

/**
 * UIPointerInteractionDelegate — return nil to keep the default system pointer
 * visible at all times. This ensures the cursor renders above all UI elements
 * (viewport, panels, menus) like a desktop mouse.
 */
- (UIPointerStyle *)pointerInteraction:(UIPointerInteraction *)interaction
                        styleForRegion:(UIPointerRegion *)region API_AVAILABLE(ios(13.4))
{
  return nil;
}

/**
 * Handle touches that come from an indirect pointer device (mouse / trackpad).
 * We intercept these in touchesBegan/Moved/Ended and check for UITouchTypeIndirectPointer
 * combined with the buttonMask on the UIEvent to determine left / right / middle.
 */
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
  [super touchesBegan:touches withEvent:event];

  for (UITouch *touch in touches) {
    if (touch.type == UITouchTypePencil) {
      current_pencil_touch = touch;
      tablet_data.Active = GHOST_kTabletModeStylus;
      tablet_data.Pressure = touch.force / touch.maximumPossibleForce;
      CGFloat azimuthAngle = [touch azimuthAngleInView:window->getView()];
      CGFloat altitudeAngle = [touch altitudeAngle];
      CGFloat maxTilt = cos(0);
      tablet_data.Xtilt = sin(azimuthAngle) * cos(altitudeAngle) / maxTilt;
      tablet_data.Ytilt = -cos(azimuthAngle) * cos(altitudeAngle) / maxTilt;
      break;
    }

    if (@available(iOS 13.4, *)) {
      if (touch.type == UITouchTypeIndirectPointer) {
        [self updateMouseCursorFromTouch:touch];
        mouse_cursor_valid = true;

        UIEventButtonMask mask = event.buttonMask;
        mouse_buttons_held = mask;

        /* Move cursor first, then send button down events. */
        [self pushIndirectPointerCursorEvent];
        if (mask & UIEventButtonMaskPrimary) {
          [self pushIndirectPointerButtonEvent:GHOST_kEventButtonDown
                                    buttonMask:GHOST_kButtonMaskLeft];
        }
        if (mask & UIEventButtonMaskSecondary) {
          [self pushIndirectPointerButtonEvent:GHOST_kEventButtonDown
                                    buttonMask:GHOST_kButtonMaskRight];
        }
        /* Middle button is handled via GCMouse — not reliably exposed in
         * UIEvent.buttonMask on all iPadOS devices. */
        system->notifyExternalEventProcessed();
        return;
      }
    }
  }
}

/**
 * Set up GCMouse handlers for middle button and scroll wheel.
 * Left/right buttons are handled via UITouch (UITouchTypeIndirectPointer)
 * but middle button is only reliably available through GameController.
 */
- (void)setupGCMouse:(GCMouse *)mouse API_AVAILABLE(ios(14.0))
{
  /* Use __unsafe_unretained since GHOST is compiled without ARC. */
  __unsafe_unretained typeof(self) weakSelf = self;

  /* --- Middle button for 3D viewport orbit --- */
  mouse.mouseInput.middleButton.pressedChangedHandler = ^(
      GCControllerButtonInput *_Nonnull button, float value, BOOL pressed) {
    typeof(self) strongSelf = weakSelf;
    if (!strongSelf) {
      return;
    }

    if (pressed) {
      /* Send cursor position + middle button down. */
      if (strongSelf->mouse_cursor_valid) {
        [strongSelf pushIndirectPointerCursorEvent];
      }
      [strongSelf pushIndirectPointerButtonEvent:GHOST_kEventButtonDown
                                      buttonMask:GHOST_kButtonMaskMiddle];
    }
    else {
      [strongSelf pushIndirectPointerButtonEvent:GHOST_kEventButtonUp
                                      buttonMask:GHOST_kButtonMaskMiddle];
    }
    strongSelf->system->notifyExternalEventProcessed();
  };

  /* --- Mouse movement (delta) for all pointer tracking --- */
  mouse.mouseInput.mouseMovedHandler = ^(
      GCMouseInput *_Nonnull mouseInput, float deltaX, float deltaY) {
    typeof(self) strongSelf = weakSelf;
    if (!strongSelf) {
      return;
    }

    /* Always update cursor position from deltas — this is the only movement source
     * when middle button is held (no UITouch, hover may stop on some iPadOS versions).
     * Deltas stay in logical points to match the rest of the input path. */
    strongSelf->mouse_cursor_x += (int32_t)deltaX;
    strongSelf->mouse_cursor_y -= (int32_t)deltaY; /* Y is inverted. */
    strongSelf->mouse_cursor_valid = true;

    [strongSelf pushIndirectPointerCursorEvent];
    strongSelf->system->notifyExternalEventProcessed();
  };

  /* --- Scroll wheel --- */
  mouse.mouseInput.scroll.valueChangedHandler = ^(
      GCControllerDirectionPad *_Nonnull dpad, float xValue, float yValue) {
    typeof(self) strongSelf = weakSelf;
    if (!strongSelf) {
      return;
    }

    /* Convert GCMouse scroll deltas to GHOST wheel events.
     * Use yValue for vertical zoom; fall back to xValue as vertical
     * when yValue is zero (some Bluetooth mice only report on xAxis). */
    float vertical = yValue;
    float horizontal = xValue;
    if (fabsf(yValue) < 0.001f && fabsf(xValue) > 0.001f) {
      /* Only horizontal reported — treat as vertical scroll (zoom). */
      vertical = xValue;
      horizontal = 0.0f;
    }

    if (fabsf(vertical) > 0.001f) {
      int32_t ticks = (vertical > 0) ? 1 : -1;
      strongSelf->system->pushEvent(std::make_unique<GHOST_EventWheel>(
          strongSelf->system->getMilliSeconds(),
          strongSelf->window,
          GHOST_kEventWheelAxisVertical,
          ticks));
    }
    if (fabsf(horizontal) > 0.001f) {
      int32_t ticks = (horizontal > 0) ? 1 : -1;
      strongSelf->system->pushEvent(std::make_unique<GHOST_EventWheel>(
          strongSelf->system->getMilliSeconds(),
          strongSelf->window,
          GHOST_kEventWheelAxisHorizontal,
          ticks));
    }
    strongSelf->system->notifyExternalEventProcessed();
  };
}

- (void)mouseDidConnect:(NSNotification *)notification API_AVAILABLE(ios(14.0))
{
  GCMouse *mouse = notification.object;
  if (mouse) {
    [self setupGCMouse:mouse];
  }
}

- (void)mouseDidDisconnect:(NSNotification *)notification API_AVAILABLE(ios(14.0))
{
  /* Nothing to clean up — the GCMouse is deallocated by the system. */
}

- (void)beginFrame
{
}

- (void)endFrame
{
}

- (const GHOST_TabletData)getTabletData
{
  return tablet_data;
}

@end

@interface GHOST_IOSViewController : UIViewController

- (nonnull instancetype)initWithMetalKitView:(nonnull MTKView *)mtkView;

@end

@implementation GHOST_IOSViewController
{
  MTKView *_view;
  GHOST_IOSMetalRenderer *_renderer;
}

- (nonnull instancetype)initWithMetalKitView:(nonnull MTKView *)mtkView
{
  _view = mtkView;
  _view.multipleTouchEnabled = YES;
  self = [super init];
  self.view = (UIView *)mtkView;

  return self;
}

- (void)viewDidLoad
{
  [super viewDidLoad];
  _view = (MTKView *)self.view;
  _view.enableSetNeedsDisplay = NO;
  _view.device = MTLCreateSystemDefaultDevice();
  _view.clearColor = MTLClearColorMake(0, 0, 0, 1.0);
  _view.paused = NO;
  _view.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
  _view.autoResizeDrawable = YES;
  _view.contentMode = UIViewContentModeScaleToFill;
  _view.contentScaleFactor = self.view.window.windowScene.screen.scale ?: UITraitCollection.currentTraitCollection.displayScale;
  /* Use UIUpdateLink for proper ProMotion frame pacing (iOS 18+). */
  UIUpdateLink *updateLink = [UIUpdateLink updateLinkForView:_view actionTarget:self selector:@selector(updateLinkDidFire:)];
  updateLink.requiresContinuousUpdates = YES;
  [updateLink setEnabled:YES];
  _renderer = [[GHOST_IOSMetalRenderer alloc] initWithMetalKitView:_view];
  if (!_renderer) {
    NSLog(@"Renderer initialization failed");
    return;
  }

  [_renderer mtkView:_view drawableSizeWillChange:_view.drawableSize];

  _view.delegate = _renderer;
}

- (void)handleGesture:(UIGestureRecognizer *)gestureRecognizer
{
}

- (BOOL)prefersHomeIndicatorAutoHidden
{
  /* Make the Home Indicator (the bottom-center white navigation bar) auto-hide when possible. */
  return YES;
}

- (void)updateLinkDidFire:(UIUpdateLink *)link
{
  /* UIUpdateLink callback — triggers MTKView redraw at optimal frame rate. */
  [_view setNeedsDisplay];
}

@end

static UIWindowScene *ghost_ios_active_window_scene()
{
  for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
    if ([scene isKindOfClass:[UIWindowScene class]]) {
      return (UIWindowScene *)scene;
    }
  }
  return nil;
}

static CGRect ghost_ios_window_scene_bounds(UIWindowScene *windowScene)
{
  if (windowScene) {
    if (@available(iOS 26.0, *)) {
      return windowScene.effectiveGeometry.coordinateSpace.bounds;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return windowScene.coordinateSpace.bounds;
#pragma clang diagnostic pop
  }
  return CGRectMake(0, 0, 1024, 768);
}

static int32_t ghost_ios_round_to_int(CGFloat value)
{
  return int32_t(std::lround(value));
}

static CGFloat ghost_ios_window_scale(UIWindow *window, UIView *view)
{
  if (view.contentScaleFactor > 0) {
    return view.contentScaleFactor;
  }
  if (window.screen.scale > 0) {
    return window.screen.scale;
  }
  return 1.0;
}

static GHOSTUIWindow *ghost_ios_window_create(UIWindowScene *windowScene)
{
  if (windowScene) {
    return [[GHOSTUIWindow alloc] initWithWindowScene:windowScene];
  }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  return [[GHOSTUIWindow alloc] init];
#pragma clang diagnostic pop
}

GHOST_WindowIOS::GHOST_WindowIOS(GHOST_SystemIOS *systemIos,
                                 const char *title,
                                 int32_t left,
                                 int32_t bottom,
                                 uint32_t width,
                                 uint32_t height,
                                 GHOST_TWindowState state,
                                 GHOST_TDrawingContextType type,
                                 const GHOST_ContextParams &context_params,
                                 bool /*is_debug*/,
                                 bool is_dialog,
                                 GHOST_WindowIOS *parentWindow)
    : GHOST_Window(width, height, state, context_params, false), m_metalView(nil)
{
  full_screen_ = (parentWindow == nullptr) && !is_dialog;
  m_systemIOS = systemIos;
  /* Parent window will be the window that focus is returned to upon close. */
  parent_window_ = parentWindow;
  m_window_title = nullptr;

  UIWindowScene *windowScene = ghost_ios_active_window_scene();
  const CGRect initial_frame = full_screen_ ? ghost_ios_window_scene_bounds(windowScene) :
                                             CGRectMake(left, bottom, width, height);

  /* Create MTKView. */
  m_metalView = [[MTKView alloc] initWithFrame:initial_frame];
  [m_metalView retain];
  GHOST_ASSERT(m_metalView, "metalview not valid");

  /* Create view controller. */
  GHOST_ASSERT([UIApplication sharedApplication], "App not valid");
  GHOST_ASSERT([[UIApplication sharedApplication] delegate], "App not valid");

  GHOSTUIWindow *ghost_rootWindow = nullptr;

  if (full_screen_) {
    /* Init the main window in the active scene's coordinate space. */
    ghost_rootWindow = ghost_ios_window_create(windowScene);
    [ghost_rootWindow retain];
    ghost_rootWindow.frame = initial_frame;
  }
  else {
    /* Init window at specified size. */
    ghost_rootWindow = ghost_ios_window_create(windowScene);
    [ghost_rootWindow retain];
    ghost_rootWindow.frame = initial_frame;
    [ghost_rootWindow setClipsToBounds:YES];
  }

  rootWindow = (UIWindow *)ghost_rootWindow;

  [ghost_rootWindow setSystemAndWindowIOS:m_systemIOS windowIOS:this];
  rootWindow.windowLevel = UIWindowLevelAlert;

  GHOST_ASSERT(rootWindow, "UIWindow not valid");
  m_uiview_controller = [[[GHOST_IOSViewController alloc] initWithMetalKitView:m_metalView]
      retain];
  [m_uiview_controller viewDidLoad];
  GHOST_ASSERT(m_uiview_controller, "UIViewController not valid");

  /* Set presentation style depending on whether main window, dialog or temporary window. */
  if (full_screen_) {
    /* Initial window has no parent and is always fullscreen. */
    m_uiview_controller.modalPresentationStyle = UIModalPresentationFullScreen;
  }
  else {
    /* Dialogs and temporary windows should not replace the main app surface. */
    m_uiview_controller.modalPresentationStyle = UIModalPresentationPageSheet;
  }
  rootWindow.rootViewController = m_uiview_controller;

  /* Create UIView */
  GHOST_ASSERT(width > 0 && height > 0, "invalid wh");
  m_uiview = m_uiview_controller.view;
  GHOST_ASSERT(m_uiview, "uiview not valid");

  setNativePixelSize();

  /* Initialize Metal device. */
  m_metalView.device = MTLCreateSystemDefaultDevice();

  /* Enable HDR/EDR Support. */
  CAMetalLayer *metalLayer = (CAMetalLayer *)m_metalView.layer;
  metalLayer.wantsExtendedDynamicRangeContent = YES;
  metalLayer.pixelFormat = MTLPixelFormatRGBA16Float;
  CGColorSpaceRef colorspace = CGColorSpaceCreateWithName(kCGColorSpaceExtendedSRGB);
  metalLayer.colorspace = colorspace;
  CGColorSpaceRelease(colorspace);

  setDrawingContextType(type);
  updateDrawingContext();
  activateDrawingContext();

  setTitle(title);

  /* Gesture recognizers. */
  [ghost_rootWindow registerGestureRecognizers];

  deferred_swap_buffers_count = 0;

  /* Deactive the parent (if it exists) and activate this one. */
  if (parent_window_) {
    parent_window_->requestToDeactivateWindow();
  }

  /* Make it the key window if there is no other window.
   * (Otherwise there will never be a call to drawInMTKView) */
  if (!m_systemIOS->current_active_window) {
    m_request_to_make_active = true;
    makeKeyWindow();
  }
  /* Activate this window at the end of the next draw loop. */
  else {
    requestToActivateWindow();
  }
}

GHOST_WindowIOS::~GHOST_WindowIOS()
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

  releaseNativeHandles();

  /* Restore application control and display to parent window. */
  if (parent_window_) {
    parent_window_->requestToActivateWindow();
    parent_window_ = nil;
  }
  /* We have no choice but to resign, however this seems like it might cause issues. */
  if (m_systemIOS->current_active_window == this) {
    IOS_WINDOW_LOG(@"~GHOST_WindowIOS(): Warning, deactivating the active window %p?", this);
    requestToDeactivateWindow();
    resignKeyWindow();
  }

  if (m_metalView) {
    m_metalView.delegate = nil;
    [m_metalView release];
    m_metalView = nil;
  }
  if (m_uiview) {
    [m_uiview release];
    m_uiview = nil;
  }

  /* Release window. */
  if (rootWindow) {
    [rootWindow release];
    rootWindow = nil;
  }
  if (m_uiview_controller) {
    [m_uiview_controller release];
    m_uiview_controller = nil;
  }

  if (m_window_title) {
    free(m_window_title);
    m_window_title = nullptr;
  }

  [pool drain];
}

#pragma mark accessors

bool GHOST_WindowIOS::getValid() const
{
  MTKView *view = m_metalView;
  return GHOST_Window::getValid() && m_uiview != NULL && view != NULL;
}

void *GHOST_WindowIOS::getOSWindow() const
{
  return (void *)m_uiview;
}

GHOST_TSuccess GHOST_WindowIOS::swapBufferAcquire()
{
  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_WindowIOS::swapBufferRelease()
{
  deferred_swap_buffers_count++;
  return GHOST_kSuccess;
}

void GHOST_WindowIOS::flushDeferredSwapBuffers()
{
  if (deferred_swap_buffers_count) {

    /* These two messages should be made asserts when we've fixed all the issues. */
    if (!getValid()) {
      IOS_WINDOW_LOG(@"Ignoring swap (invalid) con(%p) (win=%p)", getContext(), this);
      return;
    }

    if (!m_is_active_window) {
      IOS_WINDOW_LOG(@"Ignoring swap (not active window) con(%p) (win=%p)", getContext(), this);
      return;
    }

    IOS_WINDOW_LOG(@"Swapping (ui_View)%p (mtkView)%p con(%p) (win=%p) (sc=%d)",
                   m_uiview,
                   m_metalView,
                   getContext(),
                   this,
                   deferred_swap_buffers_count);

    GHOST_ContextIOS *context = reinterpret_cast<GHOST_ContextIOS *>(getContext());
    context->swapBufferRelease();
    deferred_swap_buffers_count = 0;
  }
}

void GHOST_WindowIOS::beginFrame()
{
  GHOSTUIWindow *ui_window = (GHOSTUIWindow *)rootWindow;
  [ui_window beginFrame];
}

void GHOST_WindowIOS::endFrame()
{
  GHOSTUIWindow *ui_window = (GHOSTUIWindow *)rootWindow;
  [ui_window endFrame];
}

void GHOST_WindowIOS::setTitle(const char *title)
{
  if (m_window_title) {
    free(m_window_title);
    m_window_title = nullptr;
  }
  m_window_title = (char *)malloc(strlen(title) + 1);
  if (!m_window_title) {
    GHOST_ASSERT(getValid(), "GHOST_WindowIOS::setTitle(): Failed to alloc mem for window title");
  }
  strcpy(m_window_title, title);
  NSString *window_title = [NSString stringWithCString:title encoding:NSUTF8StringEncoding];
  m_uiview_controller.title = window_title;
}

std::string GHOST_WindowIOS::getTitle() const
{
  return m_window_title;
}

void GHOST_WindowIOS::needsDisplayUpdate()
{
  [m_uiview setNeedsDisplay];
}

void GHOST_WindowIOS::getWindowBounds(GHOST_Rect &bounds) const
{
  GHOST_ASSERT(getValid(), "GHOST_WindowIOS::getWindowBounds(): window invalid");

  const CGRect windowFrame = rootWindow.frame;

  bounds.b_ = ghost_ios_round_to_int(windowFrame.origin.y + windowFrame.size.height);
  bounds.l_ = ghost_ios_round_to_int(windowFrame.origin.x);
  bounds.r_ = ghost_ios_round_to_int(windowFrame.origin.x + windowFrame.size.width);
  bounds.t_ = ghost_ios_round_to_int(windowFrame.origin.y);
}

void GHOST_WindowIOS::getClientBounds(GHOST_Rect &bounds) const
{
  GHOST_ASSERT(getValid(), "GHOST_WindowIOS::getWindowBounds(): window invalid");

  const CGRect viewBounds = m_metalView.bounds;

  bounds.b_ = ghost_ios_round_to_int(viewBounds.size.height);
  bounds.l_ = 0;
  bounds.r_ = ghost_ios_round_to_int(viewBounds.size.width);
  bounds.t_ = 0;
}

GHOST_TSuccess GHOST_WindowIOS::setClientWidth(uint32_t /*width*/)
{
  /* Ignore on iOS fow now. */
  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_WindowIOS::setClientHeight(uint32_t /*height*/)
{
  /* Ignore on iOS fow now. */
  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_WindowIOS::setClientSize(uint32_t /*width*/, uint32_t /*height*/)
{
  /* Ignore on iOS fow now. */
  return GHOST_kSuccess;
}

GHOST_TWindowState GHOST_WindowIOS::getState() const
{
  /* TODO: Implement. */
  return GHOST_kWindowStateNormal;
}

void GHOST_WindowIOS::screenToClient(int32_t inX, int32_t inY, int32_t &outX, int32_t &outY) const
{
  /* Pass through — iOS is always fullscreen. */
  outX = inX;
  outY = inY;
}

void GHOST_WindowIOS::clientToScreen(int32_t inX, int32_t inY, int32_t &outX, int32_t &outY) const
{
  /* Pass through — iOS is always fullscreen. */
  outX = inX;
  outY = inY;
}

void GHOST_WindowIOS::screenToClientIntern(int32_t inX,
                                           int32_t inY,
                                           int32_t &outX,
                                           int32_t &outY) const
{
  /* Pass through — iOS is always fullscreen. */
  outX = inX;
  outY = inY;
}

void GHOST_WindowIOS::clientToScreenIntern(int32_t inX,
                                           int32_t inY,
                                           int32_t &outX,
                                           int32_t &outY) const
{
  /* Pass through — iOS is always fullscreen. */
  outX = inX;
  outY = inY;
}

/* called for event, when window leaves monitor to another */
void GHOST_WindowIOS::setNativePixelSize(void)
{
  const CGRect viewBounds = m_metalView.bounds;
  const CGSize drawableSize = m_metalView.drawableSize;

  if (viewBounds.size.width > 0 && drawableSize.width > 0) {
    native_pixel_size_ = float(drawableSize.width / viewBounds.size.width);
    return;
  }

  native_pixel_size_ = float(ghost_ios_window_scale(rootWindow, m_metalView));
}

/**
 * \note Fullscreen switch is not actual fullscreen with display capture.
 * As this capture removes all OS X window manager features.
 *
 * Instead, the menu bar and the dock are hidden, and the window is made border-less and
 * enlarged. Thus, process switch, exposé, spaces, ... still work in fullscreen mode
 */
GHOST_TSuccess GHOST_WindowIOS::setState(GHOST_TWindowState /*state*/)
{
  // Ignore on iOS?
  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_WindowIOS::setModifiedState(bool isUnsavedChanges)
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

  [pool drain];
  return GHOST_Window::setModifiedState(isUnsavedChanges);
}

GHOST_TSuccess GHOST_WindowIOS::setOrder(GHOST_TWindowOrder /*order*/)
{
  /* TODO: Support or deprecate setOrder for iOS. */
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

  GHOST_ASSERT(getValid(), "GHOST_WindowIOS::setOrder(): window invalid");

  [pool drain];
  return GHOST_kSuccess;
}

#pragma mark Drawing context

GHOST_Context *GHOST_WindowIOS::newDrawingContext(GHOST_TDrawingContextType type)
{

  if (type == GHOST_kDrawingContextTypeMetal) {

    GHOST_Context *context = new GHOST_ContextIOS(want_context_params_, m_uiview, m_metalView);

    if (context->initializeDrawingContext())
      return context;
    else
      delete context;
  }

  return NULL;
}

#pragma mark invalidate

GHOST_TSuccess GHOST_WindowIOS::invalidate()
{
  GHOST_ASSERT(getValid(), "GHOST_WindowIOS::invalidate(): window invalid");
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  [pool drain];
  return GHOST_kSuccess;
}

#pragma mark Progress bar

GHOST_TSuccess GHOST_WindowIOS::setProgressBar(float /*progress*/)
{
  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_WindowIOS::endProgressBar()
{
  return GHOST_kSuccess;
}

#pragma mark Cursor handling

void GHOST_WindowIOS::loadCursor(bool /*visible*/, GHOST_TStandardCursor /*shape*/) const {}

bool GHOST_WindowIOS::isDialog() const
{
  return m_is_dialog;
}

GHOST_TSuccess GHOST_WindowIOS::setWindowCursorVisibility(bool /*visible*/)
{
  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_WindowIOS::setWindowCursorGrab(GHOST_TGrabCursorMode /*mode*/)
{
  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_WindowIOS::setWindowCursorShape(GHOST_TStandardCursor /*shape*/)
{
  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_WindowIOS::hasCursorShape(GHOST_TStandardCursor /*shape*/)
{
  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_WindowIOS::setWindowCustomCursorShape(const uint8_t * /*bitmap*/,
                                                           const uint8_t * /*mask*/,
                                                           const int /*size*/[2],
                                                           const int /*hot_spot*/[2],
                                                           bool /*canInvertColor*/)
{
  /* Passthrough for iOS. */
  return GHOST_kSuccess;
}

uint16_t GHOST_WindowIOS::getDPIHint()
{
  /* The native scale factor is reported separately via getNativePixelSize(). */
  return 96;
}

GHOST_TSuccess GHOST_WindowIOS::popupOnscreenKeyboard(
    const GHOST_KeyboardProperties &keyboard_properties)
{
  GHOSTUIWindow *ghost_rootWindow = (GHOSTUIWindow *)rootWindow;
  return [ghost_rootWindow popupOnscreenKeyboard:keyboard_properties];
}

GHOST_TSuccess GHOST_WindowIOS::hideOnscreenKeyboard()
{
  GHOSTUIWindow *ghost_rootWindow = (GHOSTUIWindow *)rootWindow;
  return [ghost_rootWindow hideOnscreenKeyboard];
}

const char *GHOST_WindowIOS::getLastKeyboardString()
{
  GHOSTUIWindow *ghost_rootWindow = (GHOSTUIWindow *)rootWindow;
  return [ghost_rootWindow getLastKeyboardString];
}

UITextField *GHOST_WindowIOS::getUITextField()
{
  GHOSTUIWindow *ghost_rootWindow = (GHOSTUIWindow *)rootWindow;
  return [ghost_rootWindow getUITextField];
}

const GHOST_TabletData GHOST_WindowIOS::getTabletData()
{
  GHOSTUIWindow *ghost_rootWindow = (GHOSTUIWindow *)rootWindow;
  return [ghost_rootWindow getTabletData];
}

/* This is the size of the window pre-scaled */
CGSize GHOST_WindowIOS::getLogicalWindowSize()
{
  return m_metalView.frame.size;
}

/* This is the size of the window post-scaled */
CGSize GHOST_WindowIOS::getNativeWindowSize()
{
  return m_metalView.drawableSize;
}

float GHOST_WindowIOS::getWindowScaleFactor()
{
  return rootWindow.screen.scale;
}

/* Indicate that we want this window to be the next active one. */
void GHOST_WindowIOS::requestToActivateWindow()
{
  /* Check we're not already active. */
  if (m_systemIOS->current_active_window != this) {
    /* Replace any outstanding requests. */
    if (m_systemIOS->next_active_window) {
      m_systemIOS->next_active_window->requestToDeactivateWindow();
    }
    m_request_to_make_active = true;
    m_systemIOS->next_active_window = this;
  }
}

void GHOST_WindowIOS::requestToDeactivateWindow()
{
  if (m_systemIOS->next_active_window == this) {
    IOS_WINDOW_LOG(@"requestToDeactivateWindow(): Has something gone wrong? %p", this);
    m_systemIOS->next_active_window = nullptr;
  }
  m_request_to_make_active = false;
}

bool GHOST_WindowIOS::makeKeyWindow()
{
  if (!getValid()) {
    IOS_WINDOW_LOG(@"Failed to activate (invalid) con(%p) (win=%p)", getContext(), this);
    return false;
  }

  GHOST_ContextIOS *context = reinterpret_cast<GHOST_ContextIOS *>(getContext());
  GHOST_ASSERT(rootWindow != nil, "GHOST_WindowIOS::makeKeyWindow() root window required");
  GHOST_ASSERT(context != nullptr, "GHOST_WindowIOS::makeKeyWindow() context required");
  GHOST_ASSERT(m_request_to_make_active,
               "GHOST_WindowIOS::makeKeyWindow() must request activation first");

  /* Make window primary visible window. */
  [rootWindow makeKeyAndVisible];
  /* Enable the drawInMTKView() calls for this window. */
  m_metalView.paused = NO;

  IOS_WINDOW_LOG(@"Key Window: (ui_View)%p (mtkView)%p con(%p) (win=%p)",
                 m_uiview,
                 m_metalView,
                 getContext(),
                 this);

  m_systemIOS->current_active_window = this;
  m_is_active_window = true;
  m_request_to_make_active = false;
  return true;
}

void GHOST_WindowIOS::resignKeyWindow()
{
  GHOST_ASSERT(m_systemIOS->current_active_window == this,
               "GHOST_WindowIOS::resignKeyWindow(): Can only resign current active window");
  GHOST_ASSERT(m_is_active_window,
               "GHOST_WindowIOS::resignKeyWindow(): Can't resign non active window");
  GHOST_ASSERT(!m_request_to_make_active,
               "GHOST_WindowIOS::resignKeyWindow(): activation request outstanding");

  /* Disable the drawInMTKView() calls for this window. */
  m_metalView.paused = YES;
  /* Wait until any outstanding presents in flight are done. */
  if (m_uiview_controller.beingPresented) {
    /* Use a run loop spin instead of a busy-wait to avoid blocking the main thread. */
    NSDate *timeout = [NSDate dateWithTimeIntervalSinceNow:1.0];
    while (m_uiview_controller.beingPresented &&
           [[NSDate date] compare:timeout] == NSOrderedAscending) {
      [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                              beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
  }
  IOS_WINDOW_LOG(@"Resigning Key Window: (ui_View)%p (mtkView)%p con(%p) (win=%p)",
                 m_uiview,
                 m_metalView,
                 getContext(),
                 this);
  m_is_active_window = false;
  m_systemIOS->current_active_window = nullptr;
}

/* Single conversion point from UIKit view coordinates to GHOST client coordinates.
 * Both are logical points (see getClientBounds), matching the Cocoa backend, so the
 * native pixel scale is reported separately via getNativePixelSize(). */
CGPoint GHOST_WindowIOS::scalePointToWindow(CGPoint &point)
{
  return point;
}

#ifdef WITH_INPUT_IME
void GHOST_WindowIOS::beginIME(
    int32_t /*x*/, int32_t /*y*/, int32_t /*w*/, int32_t /*h*/, bool /*completed*/)
{
  /* Passthrough for iOS. */
}

void GHOST_WindowIOS::endIME()
{
  /* Passthrough for iOS. */
}
#endif /* WITH_INPUT_IME */
