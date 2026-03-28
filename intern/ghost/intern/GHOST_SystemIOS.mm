/* SPDX-FileCopyrightText: 2025 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

#include "GHOST_SystemIOS.hh"

#include "GHOST_ContextIOS.hh"
#include "GHOST_WindowIOS.hh"

#include "GHOST_Debug.hh"
#include "GHOST_EventButton.hh"
#include "GHOST_EventCursor.hh"
#include "GHOST_EventDragnDrop.hh"
#include "GHOST_EventString.hh"
#include "GHOST_WindowManager.hh"

#include <memory>

#ifdef WITH_INPUT_NDOF
#  include "GHOST_NDOFManagerCocoa.hh"
#endif

#import <MetalKit/MTKView.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>

#include <sys/sysctl.h>
#include <sys/time.h>
#include <os/proc.h>

// #define IOS_SYSTEM_LOGGING
#if defined(IOS_SYSTEM_LOGGING)
#  define IOS_SYSTEM_LOG(...) NSLog(__VA_ARGS__)
#else
#  define IOS_SYSTEM_LOG(...)
#endif

#pragma mark - Security-Scoped URL Storage

/**
 * Dictionary mapping file paths to their original security-scoped NSURLs.
 * Used to maintain access to files/directories returned by UIDocumentPickerViewController.
 * Keys: NSString (absolute path), Values: NSURL (the security-scoped URL from the picker).
 */
static NSMutableDictionary<NSString *, NSURL *> *s_securityScopedURLs = nil;

/** Lock object for thread-safe access to s_securityScopedURLs. */
static NSObject *s_securityScopedURLsLock = [[NSObject alloc] init];

static void storeSecurityScopedURL(NSURL *url)
{
  @synchronized(s_securityScopedURLsLock) {
    if (!s_securityScopedURLs) {
      s_securityScopedURLs = [[NSMutableDictionary alloc] init];
    }
    NSString *path = url.path;
    if (path) {
      s_securityScopedURLs[path] = url;
      /* Also store the parent directory URL for temp file creation during saves. */
      NSURL *dirURL = [url URLByDeletingLastPathComponent];
      if (dirURL && dirURL.path) {
        s_securityScopedURLs[dirURL.path] = dirURL;
      }
    }
  }
}

static NSURL *lookupSecurityScopedURL(const char *filepath)
{
  @synchronized(s_securityScopedURLsLock) {
    if (!s_securityScopedURLs || !filepath) {
      return nil;
    }
    NSString *path = [NSString stringWithUTF8String:filepath];
    return s_securityScopedURLs[path];
  }
}

#pragma mark - Native File Dialog Delegate

/**
 * Objective-C delegate for UIDocumentPickerViewController.
 * On completion, pushes a GHOST_kEventNativeFileDialogResult event with the selected path
 * (or nullptr on cancel) back to the GHOST event queue.
 */
@interface GHOST_IOSFilePickerDelegate
    : NSObject <UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate>
@property(nonatomic, assign) GHOST_SystemIOS *ghostSystem;
/** For save-to-folder mode: the default filename to append to the chosen directory. */
@property(nonatomic, copy) NSString *defaultFilename;
@end

@implementation GHOST_IOSFilePickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
  if (urls.count > 0) {
    NSURL *url = urls.firstObject;

    /* Start security-scoped access so Blender can read/write the file. */
    [url startAccessingSecurityScopedResource];

    /* Store the original security-scoped URL for later access (e.g., saving). */
    storeSecurityScopedURL(url);

    /* For save-to-folder: the user picked a directory, append the default filename. */
    if (_defaultFilename.length > 0) {
      NSURL *fileURL = [url URLByAppendingPathComponent:_defaultFilename];
      storeSecurityScopedURL(fileURL);
      url = fileURL;
    }

    const char *path = [url.path UTF8String];
    const size_t pathLen = strlen(path);
    char *pathCopy = (char *)malloc(pathLen + 1);
    memcpy(pathCopy, path, pathLen + 1);

    GHOST_WindowIOS *window = _ghostSystem->current_active_window;
    _ghostSystem->pushEvent(std::make_unique<GHOST_EventString>(
        _ghostSystem->getMilliSeconds(),
        GHOST_kEventNativeFileDialogResult,
        window,
        static_cast<GHOST_TEventDataPtr>(pathCopy)));
    _ghostSystem->notifyExternalEventProcessed();
  }
  else {
    [self documentPickerWasCancelled:controller];
  }
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller
{
  /* Push a cancel event (nullptr data). */
  GHOST_WindowIOS *window = _ghostSystem->current_active_window;
  _ghostSystem->pushEvent(std::make_unique<GHOST_EventString>(
      _ghostSystem->getMilliSeconds(),
      GHOST_kEventNativeFileDialogResult,
      window,
      static_cast<GHOST_TEventDataPtr>(nullptr)));
  _ghostSystem->notifyExternalEventProcessed();
}

- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController
{
  /* Handle swipe-to-dismiss as a cancel. */
  [self documentPickerWasCancelled:nil];
}

@end

#pragma mark -

namespace blender {
struct bContext;
}
static blender::bContext *C = nullptr;

int argc = 0;
const char **argv = nullptr;

/* Implemented in wm.cc (inside namespace blender). */
namespace blender {
void WM_main_loop_body(bContext *C);
}
int main_ios_callback(int argc, const char **argv);

/* Resolve WM/BKE lifecycle functions at runtime via dlsym to avoid
 * a link-time dependency from GHOST → windowmanager. All symbols live
 * in the same binary, so RTLD_DEFAULT finds them. */
#include <dlfcn.h>

namespace blender {
struct Main;
struct wmWindowManager;
}  // namespace blender

using CTX_wm_manager_fn = blender::wmWindowManager *(*)(const blender::bContext *);
using CTX_data_main_fn = blender::Main *(*)(const blender::bContext *);
using WM_autosave_write_fn = void (*)(blender::wmWindowManager *, blender::Main *);
using wm_autosave_timer_fn = void (*)(blender::wmWindowManager *);

static CTX_wm_manager_fn resolve_CTX_wm_manager()
{
  static auto fn = (CTX_wm_manager_fn)dlsym(
      RTLD_DEFAULT, "_ZN7blender14CTX_wm_managerEPKNS_8bContextE");
  return fn;
}
static CTX_data_main_fn resolve_CTX_data_main()
{
  static auto fn = (CTX_data_main_fn)dlsym(
      RTLD_DEFAULT, "_ZN7blender13CTX_data_mainEPKNS_8bContextE");
  return fn;
}
static WM_autosave_write_fn resolve_WM_autosave_write()
{
  static auto fn = (WM_autosave_write_fn)dlsym(
      RTLD_DEFAULT, "_ZN7blender17WM_autosave_writeEPNS_15wmWindowManagerEPNS_4MainE");
  return fn;
}
static wm_autosave_timer_fn resolve_wm_autosave_timer_begin()
{
  static auto fn = (wm_autosave_timer_fn)dlsym(
      RTLD_DEFAULT, "_ZN7blender23wm_autosave_timer_beginEPNS_15wmWindowManagerE");
  return fn;
}
static wm_autosave_timer_fn resolve_wm_autosave_timer_end()
{
  static auto fn = (wm_autosave_timer_fn)dlsym(
      RTLD_DEFAULT, "_ZN7blender21wm_autosave_timer_endEPNS_15wmWindowManagerE");
  return fn;
}

@interface IOSAppDelegate : UIResponder <UIApplicationDelegate>

@property(strong, nonatomic) UIWindow *window;

@end

@implementation IOSAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
  main_ios_callback(argc, argv);

  return YES;
}

- (BOOL)application:(UIApplication *)application
            openURL:(NSURL *)url
            options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options
{
  GHOST_SystemIOS *system = static_cast<GHOST_SystemIOS *>(GHOST_ISystem::getSystem());

  system->handleOpenDocumentRequest(url.path);

  return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
  if (!C) {
    return;
  }

  /* Request extra time from iOS to complete the save. */
  __block UIBackgroundTaskIdentifier bgTask = [application
      beginBackgroundTaskWithName:@"BlenderAutosave"
               expirationHandler:^{
                 [application endBackgroundTask:bgTask];
                 bgTask = UIBackgroundTaskInvalid;
               }];

  auto *wm = resolve_CTX_wm_manager() ? resolve_CTX_wm_manager()(C) : nullptr;
  auto *bmain = resolve_CTX_data_main() ? resolve_CTX_data_main()(C) : nullptr;
  if (wm && bmain && resolve_WM_autosave_write()) {
    NSLog(@"Blender: entering background, saving autosave...");
    resolve_WM_autosave_write()(wm, bmain);
    if (resolve_wm_autosave_timer_end()) {
      resolve_wm_autosave_timer_end()(wm);
    }
  }

  [application endBackgroundTask:bgTask];
  bgTask = UIBackgroundTaskInvalid;
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
  if (!C) {
    return;
  }

  auto *wm = resolve_CTX_wm_manager() ? resolve_CTX_wm_manager()(C) : nullptr;
  if (wm && resolve_wm_autosave_timer_begin()) {
    resolve_wm_autosave_timer_begin()(wm);
  }
}

- (void)applicationWillTerminate:(UIApplication *)application
{
  if (!C) {
    return;
  }

  auto *wm = resolve_CTX_wm_manager() ? resolve_CTX_wm_manager()(C) : nullptr;
  auto *bmain = resolve_CTX_data_main() ? resolve_CTX_data_main()(C) : nullptr;
  if (wm && bmain && resolve_WM_autosave_write()) {
    NSLog(@"Blender: app terminating, saving autosave...");
    resolve_WM_autosave_write()(wm, bmain);
  }
}

- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application
{
  size_t available = 0;
  if (@available(iOS 13.0, *)) {
    available = (size_t)os_proc_available_memory();
  }

  NSLog(@"Blender: iOS memory warning! Available: %.0f MB",
        (double)available / (1024.0 * 1024.0));

  /* Force an autosave in case iOS kills us next. */
  if (C) {
    auto *wm = resolve_CTX_wm_manager() ? resolve_CTX_wm_manager()(C) : nullptr;
    auto *bmain = resolve_CTX_data_main() ? resolve_CTX_data_main()(C) : nullptr;
    if (wm && bmain && resolve_WM_autosave_write()) {
      resolve_WM_autosave_write()(wm, bmain);
    }
  }
}

@end

@implementation GHOST_IOSMetalRenderer
{
  id<MTLDevice> _device;
  id<MTLCommandQueue> _commandQueue;
}

- (nonnull instancetype)initWithMetalKitView:(nonnull MTKView *)mtkView
{
  self = [super init];
  if (self) {
    _device = mtkView.device;

    /* Create the command queue. */
    _commandQueue = [_device newCommandQueue];
  }

  return self;
}

- (void)drawInMTKView:(nonnull MTKView *)MTKView
{
  GHOST_SystemIOS *system = static_cast<GHOST_SystemIOS *>(GHOST_ISystem::getSystem());

  /* We should always have a window... */
  if (system->current_active_window) {

    /* If the current window has some outstanding swaps we need to
     * service them before handing control back to Blender otherwise
     * they may go missing. */
    if (system->current_active_window->deferred_swap_buffers_count) {
      IOS_SYSTEM_LOG(@"Issuing oustanding swaps");
      system->current_active_window->flushDeferredSwapBuffers();
      /* Make sure we get another call to draw. */
      system->current_active_window->needsDisplayUpdate();
      return;
    }

    system->current_active_window->beginFrame();
  }

  /* Run the main loop to handle all events. */
  if (C) {
    blender::WM_main_loop_body(C);
  }

  if (system->current_active_window) {
    system->current_active_window->flushDeferredSwapBuffers();
    system->current_active_window->endFrame();
  }

  /* Was there a request to switch windows? */
  if (system->next_active_window != nullptr) {
    if (system->current_active_window) {
      system->current_active_window->resignKeyWindow();
    }
    system->next_active_window->makeKeyWindow();
    system->next_active_window = nullptr;
  }
}

- (void)mtkView:(nonnull MTKView *)view drawableSizeWillChange:(CGSize)size
{
  GHOST_SystemIOS *system = static_cast<GHOST_SystemIOS *>(GHOST_ISystem::getSystem());
  if (!system->current_active_window) {
    return;
  }

  system->pushEvent(std::make_unique<GHOST_Event>(
      system->getMilliSeconds(), GHOST_kEventWindowSize, system->current_active_window));
}

@end

int GHOST_iosmain(int _argc, const char **_argv)
{
  argc = _argc;
  argv = _argv;
  @autoreleasepool {
    return UIApplicationMain(
        _argc, (char *_Nullable *)_argv, nil, NSStringFromClass([IOSAppDelegate class]));
  }
}

void GHOST_iosfinalize(blender::bContext *CTX)
{
  C = CTX;
}

#pragma mark KeyMap, mouse converters

static GHOST_TButton convertButton(int button)
{
  switch (button) {
    case 0:
      return GHOST_kButtonMaskLeft;
    case 1:
      return GHOST_kButtonMaskRight;
    case 2:
      return GHOST_kButtonMaskMiddle;
    case 3:
      return GHOST_kButtonMaskButton4;
    case 4:
      return GHOST_kButtonMaskButton5;
    case 5:
      return GHOST_kButtonMaskButton6;
    case 6:
      return GHOST_kButtonMaskButton7;
    default:
      return GHOST_kButtonMaskLeft;
  }
}

/**
 * Converts Mac raw-key codes (same for Cocoa & Carbon)
 * into GHOST key codes
 * \param rawCode: The raw physical key code
 * \param recvChar: the character ignoring modifiers (except for shift)
 * \return Ghost key code
 */
GHOST_TKey convertKey(int rawCode, unichar recvChar, uint16_t /*keyAction*/)
{
  switch (rawCode) {
      /* Numbers keys: mapped to handle some int'l keyboard (e.g. French). */
      /*
    case kVK_ISO_Section:
      return GHOST_kKeyUnknown;
    case kVK_ANSI_1:
      return GHOST_kKey1;
    case kVK_ANSI_2:
      return GHOST_kKey2;
    case kVK_ANSI_3:
      return GHOST_kKey3;
    case kVK_ANSI_4:
      return GHOST_kKey4;
    case kVK_ANSI_5:
      return GHOST_kKey5;
    case kVK_ANSI_6:
      return GHOST_kKey6;
    case kVK_ANSI_7:
      return GHOST_kKey7;
    case kVK_ANSI_8:
      return GHOST_kKey8;
    case kVK_ANSI_9:
      return GHOST_kKey9;
    case kVK_ANSI_0:
      return GHOST_kKey0;

    case kVK_ANSI_Keypad0:
      return GHOST_kKeyNumpad0;
    case kVK_ANSI_Keypad1:
      return GHOST_kKeyNumpad1;
    case kVK_ANSI_Keypad2:
      return GHOST_kKeyNumpad2;
    case kVK_ANSI_Keypad3:
      return GHOST_kKeyNumpad3;
    case kVK_ANSI_Keypad4:
      return GHOST_kKeyNumpad4;
    case kVK_ANSI_Keypad5:
      return GHOST_kKeyNumpad5;
    case kVK_ANSI_Keypad6:
      return GHOST_kKeyNumpad6;
    case kVK_ANSI_Keypad7:
      return GHOST_kKeyNumpad7;
    case kVK_ANSI_Keypad8:
      return GHOST_kKeyNumpad8;
    case kVK_ANSI_Keypad9:
      return GHOST_kKeyNumpad9;
    case kVK_ANSI_KeypadDecimal:
      return GHOST_kKeyNumpadPeriod;
    case kVK_ANSI_KeypadEnter:
      return GHOST_kKeyNumpadEnter;
    case kVK_ANSI_KeypadPlus:
      return GHOST_kKeyNumpadPlus;
    case kVK_ANSI_KeypadMinus:
      return GHOST_kKeyNumpadMinus;
    case kVK_ANSI_KeypadMultiply:
      return GHOST_kKeyNumpadAsterisk;
    case kVK_ANSI_KeypadDivide:
      return GHOST_kKeyNumpadSlash;
    case kVK_ANSI_KeypadClear:
      return GHOST_kKeyUnknown;

    case kVK_F1:
      return GHOST_kKeyF1;
    case kVK_F2:
      return GHOST_kKeyF2;

    case kVK_F3:
      return GHOST_kKeyF3;
    case kVK_F4:
      return GHOST_kKeyF4;
    case kVK_F5:
      return GHOST_kKeyF5;
    case kVK_F6:
      return GHOST_kKeyF6;
    case kVK_F7:
      return GHOST_kKeyF7;
    case kVK_F8:
      return GHOST_kKeyF8;
    case kVK_F9:
      return GHOST_kKeyF9;
    case kVK_F10:
      return GHOST_kKeyF10;
    case kVK_F11:
      return GHOST_kKeyF11;
    case kVK_F12:
      return GHOST_kKeyF12;
    case kVK_F13:
      return GHOST_kKeyF13;
    case kVK_F14:
      return GHOST_kKeyF14;
    case kVK_F15:
      return GHOST_kKeyF15;
    case kVK_F16:
      return GHOST_kKeyF16;
    case kVK_F17:
      return GHOST_kKeyF17;
    case kVK_F18:
      return GHOST_kKeyF18;
    case kVK_F19:
      return GHOST_kKeyF19;
    case kVK_F20:
      return GHOST_kKeyF20;

    case kVK_UpArrow:
      return GHOST_kKeyUpArrow;
    case kVK_DownArrow:
      return GHOST_kKeyDownArrow;
    case kVK_LeftArrow:
      return GHOST_kKeyLeftArrow;
    case kVK_RightArrow:
      return GHOST_kKeyRightArrow;

    case kVK_Return:
      return GHOST_kKeyEnter;
    case kVK_Delete:
      return GHOST_kKeyBackSpace;
    case kVK_ForwardDelete:
      return GHOST_kKeyDelete;
    case kVK_Escape:
      return GHOST_kKeyEsc;
    case kVK_Tab:
      return GHOST_kKeyTab;
    case kVK_Space:
      return GHOST_kKeySpace;

    case kVK_Home:
      return GHOST_kKeyHome;
    case kVK_End:
      return GHOST_kKeyEnd;
    case kVK_PageUp:
      return GHOST_kKeyUpPage;
    case kVK_PageDown:
      return GHOST_kKeyDownPage;

       */

    default: {
      /* Alphanumerical or punctuation key that is remappable in int'l keyboards. */
      if ((recvChar >= 'A') && (recvChar <= 'Z')) {
        return (GHOST_TKey)(recvChar - 'A' + GHOST_kKeyA);
      }
      else if ((recvChar >= 'a') && (recvChar <= 'z')) {
        return (GHOST_TKey)(recvChar - 'a' + GHOST_kKeyA);
      }
      else {

        switch (recvChar) {
          case '-':
            return GHOST_kKeyMinus;
          case '+':
            return GHOST_kKeyPlus;
          case '=':
            return GHOST_kKeyEqual;
          case ',':
            return GHOST_kKeyComma;
          case '.':
            return GHOST_kKeyPeriod;
          case '/':
            return GHOST_kKeySlash;
          case ';':
            return GHOST_kKeySemicolon;
          case '\'':
            return GHOST_kKeyQuote;
          case '\\':
            return GHOST_kKeyBackslash;
          case '[':
            return GHOST_kKeyLeftBracket;
          case ']':
            return GHOST_kKeyRightBracket;
          case '`':
            return GHOST_kKeyAccentGrave;
          default:
            return GHOST_kKeyUnknown;
        }
      }
    }
  }
  return GHOST_kKeyUnknown;
}

#pragma mark Utility functions

#define FIRSTFILEBUFLG 512
static bool g_hasFirstFile = false;
static char g_firstFileBuf[512];

extern "C" int GHOST_HACK_getFirstFile(char buf[FIRSTFILEBUFLG])
{
  if (g_hasFirstFile) {
    strncpy(buf, g_firstFileBuf, FIRSTFILEBUFLG - 1);
    buf[FIRSTFILEBUFLG - 1] = '\0';
    return 1;
  }
  else {
    return 0;
  }
}

#pragma mark initialization/finalization

GHOST_SystemIOS::GHOST_SystemIOS()
{
  int mib[2];
  struct timeval boottime;
  size_t len;
  char *rstring = NULL;

  m_modifierMask = 0;
  m_outsideLoopEventProcessed = false;
  m_needDelayedApplicationBecomeActiveEventProcessing = false;

  /* TODO: sysctl likely should be replaced with another approach. */
  mib[0] = CTL_KERN;
  mib[1] = KERN_BOOTTIME;
  len = sizeof(struct timeval);

  sysctl(mib, 2, &boottime, &len, NULL, 0);
  m_start_time = ((boottime.tv_sec * 1000) + (boottime.tv_usec / 1000));

  /* Detect multi-touch track-pad. */
  mib[0] = CTL_HW;
  mib[1] = HW_MODEL;
  sysctl(mib, 2, NULL, &len, NULL, 0);
  rstring = (char *)malloc(len);
  sysctl(mib, 2, rstring, &len, NULL, 0);

  free(rstring);
  rstring = NULL;

  m_ignoreWindowSizedMessages = false;
  m_ignoreMomentumScroll = false;
  m_multiTouchScroll = false;
  m_last_warp_timestamp = 0;
}

GHOST_SystemIOS::~GHOST_SystemIOS() {}

GHOST_TSuccess GHOST_SystemIOS::init()
{
  GHOST_TSuccess success = GHOST_System::init();
  if (success) {

#ifdef WITH_INPUT_NDOF
    m_ndofManager = new GHOST_NDOFManagerCocoa(*this);
#endif
  }
  return success;
}

#pragma mark window management

uint64_t GHOST_SystemIOS::getMilliSeconds() const
{
  struct timeval currentTime;

  gettimeofday(&currentTime, NULL);
  return ((currentTime.tv_sec * 1000) + (currentTime.tv_usec / 1000) - m_start_time);
}

uint8_t GHOST_SystemIOS::getNumDisplays() const
{
  return 1;
}

void GHOST_SystemIOS::getMainDisplayDimensions(uint32_t &width, uint32_t &height) const
{
  /* Use the window scene's screen instead of deprecated [UIScreen mainScreen]. */
  UIWindow *keyWindow = nil;
  for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
    if ([scene isKindOfClass:[UIWindowScene class]]) {
      UIWindowScene *windowScene = (UIWindowScene *)scene;
      for (UIWindow *w in windowScene.windows) {
        if (w.isKeyWindow) {
          keyWindow = w;
          break;
        }
      }
      if (keyWindow) break;
    }
  }
  UIScreen *screen = keyWindow.windowScene.screen ?: [UIScreen mainScreen];
  CGRect screenRect = screen.bounds;
  CGFloat scaling_fac = screen.scale;
  CGFloat screenWidth = screenRect.size.width * scaling_fac;
  CGFloat screenHeight = screenRect.size.height * scaling_fac;

  if (screenWidth <= 0 || screenHeight <= 0) {
    GHOST_ASSERT(false, "Negative or null display dimensions");
    screenWidth = 2732;
    screenHeight = 2048;
  }

  width = screenWidth;
  height = screenHeight;
}

void GHOST_SystemIOS::getAllDisplayDimensions(uint32_t &width, uint32_t &height) const
{
  /* TOOD: iOS passthrough. */
  getMainDisplayDimensions(width, height);
}

GHOST_IWindow *GHOST_SystemIOS::createWindow(const char *title,
                                             int32_t /*left*/,
                                             int32_t /*top*/,
                                             uint32_t /*width*/,
                                             uint32_t /*height*/,
                                             GHOST_TWindowState state,
                                             GHOST_GPUSettings gpuSettings,
                                             const bool /*exclusive*/,
                                             const bool is_dialog,
                                             const GHOST_IWindow *parentWindow)
{
  const GHOST_ContextParams context_params = GHOST_CONTEXT_PARAMS_FROM_GPU_SETTINGS(gpuSettings);
  GHOST_IWindow *window = NULL;
  @autoreleasepool {

    /* Create window at native size from the active window scene. */
    CGRect bounds = CGRectMake(0, 0, 1024, 768);
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
      if ([scene isKindOfClass:[UIWindowScene class]]) {
        bounds = ((UIWindowScene *)scene).screen.bounds;
        break;
      }
    }

    window = (GHOST_IWindow *)new GHOST_WindowIOS(this,
                                                  title,
                                                  (int)bounds.origin.x,
                                                  (int)bounds.origin.y,
                                                  (unsigned int)bounds.size.width,
                                                  (unsigned int)bounds.size.height,
                                                  state,
                                                  gpuSettings.context_type,
                                                  context_params,
                                                  gpuSettings.flags & GHOST_gpuDebugContext,
                                                  is_dialog,
                                                  (GHOST_WindowIOS *)parentWindow);

    if (window->getValid()) {
      // Store the pointer to the window
      GHOST_ASSERT(window_manager_, "window_manager_ not initialized");
      window_manager_->addWindow(window);
      window_manager_->setActiveWindow(window);
      pushEvent(std::make_unique<GHOST_Event>(getMilliSeconds(), GHOST_kEventWindowActivate, window));
      pushEvent(std::make_unique<GHOST_Event>(getMilliSeconds(), GHOST_kEventWindowSize, window));
    }
    else {
      GHOST_PRINT("GHOST_SystemIOS::createWindow(): window invalid\n");
      delete window;
      window = NULL;
    }
  }
  return window;
}

/**
 * Create a new offscreen context.
 * Never explicitly delete the context, use #disposeContext() instead.
 * \return The new context (or 0 if creation failed).
 */
GHOST_IContext *GHOST_SystemIOS::createOffscreenContext(GHOST_GPUSettings /*gpuSettings*/)
{
  GHOST_Context *context = new GHOST_ContextIOS(GHOST_ContextParams(GHOST_CONTEXT_PARAMS_NONE), NULL, NULL);
  if (context->initializeDrawingContext())
    return context;
  else
    delete context;

  return NULL;
}

/**
 * Dispose of a context.
 * \param context: Pointer to the context to be disposed.
 * \return Indication of success.
 */
GHOST_TSuccess GHOST_SystemIOS::disposeContext(GHOST_IContext *context)
{
  delete context;

  return GHOST_kSuccess;
}

/**
 * \note : returns 0,0 on ios as no cursor is present.
 * TODO: If external mouse or trackpad is connected, we can query cursor position.
 */
GHOST_TSuccess GHOST_SystemIOS::getCursorPosition(int32_t & /*x*/, int32_t & /*y*/) const
{
  /* iOS Passthrough. */
  GHOST_IWindow *window = this->window_manager_->getActiveWindow();
  if (!window)
    return GHOST_kFailure;
  // GHOST_ASSERT(FALSE,"GHOST_SystemIOS::getCursorPosition unsupported on iOS");
  return GHOST_kSuccess;
}

/**
 * \note : expect Cocoa screen coordinates
 * TODO: If external mouse or trackpad is connected, we can set cursor position.
 */
GHOST_TSuccess GHOST_SystemIOS::setCursorPosition(int32_t x, int32_t y)
{
  GHOST_WindowIOS *window = (GHOST_WindowIOS *)window_manager_->getActiveWindow();
  if (!window)
    return GHOST_kFailure;

  pushEvent(std::make_unique<GHOST_EventCursor>(
      getMilliSeconds(), GHOST_kEventCursorMove, window, x, y, window->getTabletData()));
  m_outsideLoopEventProcessed = true;

  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_SystemIOS::setMouseCursorPosition(int32_t /*x*/, int32_t /*y*/)
{
  /* iOS Passthrough. */
  GHOST_WindowIOS *window = (GHOST_WindowIOS *)window_manager_->getActiveWindow();
  if (!window)
    return GHOST_kFailure;
  GHOST_ASSERT(FALSE, "GHOST_SystemIOS::setMouseCursorPosition unsupported on iOS");
  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_SystemIOS::getModifierKeys(GHOST_ModifierKeys &keys) const
{
  keys.set(GHOST_kModifierKeyLeftShift, (m_modifierMask & (1 << GHOST_kModifierKeyLeftShift)) != 0);
  keys.set(GHOST_kModifierKeyRightShift, (m_modifierMask & (1 << GHOST_kModifierKeyRightShift)) != 0);
  keys.set(GHOST_kModifierKeyLeftAlt, (m_modifierMask & (1 << GHOST_kModifierKeyLeftAlt)) != 0);
  keys.set(GHOST_kModifierKeyRightAlt, (m_modifierMask & (1 << GHOST_kModifierKeyRightAlt)) != 0);
  keys.set(GHOST_kModifierKeyLeftControl, (m_modifierMask & (1 << GHOST_kModifierKeyLeftControl)) != 0);
  keys.set(GHOST_kModifierKeyRightControl, (m_modifierMask & (1 << GHOST_kModifierKeyRightControl)) != 0);
  keys.set(GHOST_kModifierKeyLeftOS, (m_modifierMask & (1 << GHOST_kModifierKeyLeftOS)) != 0);
  keys.set(GHOST_kModifierKeyRightOS, (m_modifierMask & (1 << GHOST_kModifierKeyRightOS)) != 0);
  return GHOST_kSuccess;
}

void GHOST_SystemIOS::setModifierKey(GHOST_TModifierKey modifier, bool down)
{
  if (down) {
    m_modifierMask |= (1 << modifier);
  }
  else {
    m_modifierMask &= ~(1 << modifier);
  }
}

GHOST_TSuccess GHOST_SystemIOS::getButtons(GHOST_Buttons & /*buttons*/) const
{
  /* iOS Passthrough. */
  return GHOST_kSuccess;
}
GHOST_TCapabilityFlag GHOST_SystemIOS::getCapabilities() const
{
  return GHOST_TCapabilityFlag(GHOST_kCapabilityGPUReadFrontBuffer |
                               GHOST_kCapabilityNativeFileDialog);
}

#pragma mark Event handlers

/**
 * The event queue polling function
 */
bool GHOST_SystemIOS::processEvents(bool /*waitForEvent*/)
{
  /*
   Touch screen events are being processed through the UIView interactions
   We may need some additional code here to handle key presses if an external keybaord
   is attached
   */
  return true;
}

GHOST_TSuccess GHOST_SystemIOS::handleApplicationBecomeActiveEvent()
{
  m_modifierMask = 0;

  m_outsideLoopEventProcessed = true;
  return GHOST_kSuccess;
}

bool GHOST_SystemIOS::hasDialogWindow()
{
  for (GHOST_IWindow *iwindow : window_manager_->getWindows()) {
    GHOST_WindowIOS *window = (GHOST_WindowIOS *)iwindow;
    if (window->isDialog()) {
      return true;
    }
  }
  return false;
}

void GHOST_SystemIOS::notifyExternalEventProcessed()
{
  m_outsideLoopEventProcessed = true;
}

GHOST_TSuccess GHOST_SystemIOS::handleWindowEvent(GHOST_TEventType eventType,
                                                  GHOST_WindowIOS *window)
{
  if (!validWindow(window)) {
    return GHOST_kFailure;
  }
  switch (eventType) {
    case GHOST_kEventWindowClose:
      pushEvent(std::make_unique<GHOST_Event>(getMilliSeconds(), GHOST_kEventWindowClose, window));
      break;
    case GHOST_kEventWindowActivate:
      window_manager_->setActiveWindow(window);
      window->loadCursor(window->getCursorVisibility(), window->getCursorShape());
      pushEvent(std::make_unique<GHOST_Event>(getMilliSeconds(), GHOST_kEventWindowActivate, window));
      break;
    case GHOST_kEventWindowDeactivate:
      window_manager_->setWindowInactive(window);
      pushEvent(std::make_unique<GHOST_Event>(getMilliSeconds(), GHOST_kEventWindowDeactivate, window));
      break;
    case GHOST_kEventWindowUpdate:
      if (native_pixel_) {
        window->setNativePixelSize();
        pushEvent(std::make_unique<GHOST_Event>(getMilliSeconds(), GHOST_kEventNativeResolutionChange, window));
      }
      pushEvent(std::make_unique<GHOST_Event>(getMilliSeconds(), GHOST_kEventWindowUpdate, window));
      break;
    case GHOST_kEventWindowMove:
      pushEvent(std::make_unique<GHOST_Event>(getMilliSeconds(), GHOST_kEventWindowMove, window));
      break;
    case GHOST_kEventWindowSize:
      if (!m_ignoreWindowSizedMessages) {
        // Enforce only one resize message per event loop
        // (coalescing all the live resize messages)
        window->updateDrawingContext();
        pushEvent(std::make_unique<GHOST_Event>(getMilliSeconds(), GHOST_kEventWindowSize, window));
        // Mouse up event is trapped by the resizing event loop,
        // so send it anyway to the window manager.
        pushEvent(std::make_unique<GHOST_EventButton>(getMilliSeconds(),
                                        GHOST_kEventButtonUp,
                                        window,
                                        GHOST_kButtonMaskLeft,
                                        GHOST_TABLET_DATA_NONE));
      }
      break;
    case GHOST_kEventNativeResolutionChange:

      if (native_pixel_) {
        pushEvent(std::make_unique<GHOST_Event>(getMilliSeconds(), GHOST_kEventNativeResolutionChange, window));
      }
      break;

    default:
      return GHOST_kFailure;
      break;
  }

  m_outsideLoopEventProcessed = true;

  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_SystemIOS::popupOnScreenKeyboard(
    GHOST_IWindow *window, const GHOST_KeyboardProperties &keyboard_properties)
{
  if (!validWindow((GHOST_IWindow *)window)) {
    return GHOST_kFailure;
  }
  GHOST_WindowIOS *windowIOS = (GHOST_WindowIOS *)window;
  return windowIOS->popupOnscreenKeyboard(keyboard_properties);
}

GHOST_TSuccess GHOST_SystemIOS::hideOnScreenKeyboard(GHOST_IWindow *window)
{
  if (!validWindow((GHOST_IWindow *)window)) {
    return GHOST_kFailure;
  }

  GHOST_WindowIOS *windowIOS = (GHOST_WindowIOS *)window;

  return windowIOS->hideOnscreenKeyboard();
}

const char *GHOST_SystemIOS::getKeyboardInput(GHOST_IWindow *window)
{
  if (!validWindow((GHOST_IWindow *)window)) {
    return nullptr;
  }

  GHOST_WindowIOS *windowIOS = (GHOST_WindowIOS *)window;

  return windowIOS->getLastKeyboardString();
}

GHOST_TSuccess GHOST_SystemIOS::startSecurityScopedFileAccess(const char *filepath)
{
  /* First try to use a stored security-scoped URL from the file picker.
   * Plain NSURLs created from path strings are NOT security-scoped and
   * calling startAccessingSecurityScopedResource on them is a no-op. */
  NSURL *url = lookupSecurityScopedURL(filepath);
  if (!url) {
    /* Also try the parent directory — Blender writes to temp files in the same dir. */
    NSString *path = [NSString stringWithUTF8String:filepath];
    NSString *parentPath = [path stringByDeletingLastPathComponent];
    url = lookupSecurityScopedURL([parentPath UTF8String]);
  }
  if (!url) {
    /* Fallback to a plain URL (works for paths within the sandbox). */
    url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:filepath]];
  }
  BOOL success = [url startAccessingSecurityScopedResource];
  return success ? GHOST_kSuccess : GHOST_kFailure;
}

GHOST_TSuccess GHOST_SystemIOS::stopSecurityScopedFileAccess(const char *filepath)
{
  NSURL *url = lookupSecurityScopedURL(filepath);
  if (!url) {
    url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:filepath]];
  }
  [url stopAccessingSecurityScopedResource];
  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_SystemIOS::showNativeFileDialog(const char *title,
                                                      const char *default_path,
                                                      const char *filter_glob,
                                                      GHOST_TFileDialogAction action)
{
  @autoreleasepool {
    if (!current_active_window) {
      return GHOST_kFailure;
    }

    /* Build an array of UTTypes from the filter_glob.
     * Supported patterns: "*.blend", "*.png;*.jpg", etc.
     * Falls back to UTTypeData (all files) if nothing specific matches. */
    NSMutableArray<UTType *> *contentTypes = [NSMutableArray array];

    if (filter_glob && filter_glob[0] != '\0') {
      NSString *glob = [NSString stringWithUTF8String:filter_glob];
      /* Split by common separators: ";", " ", ",". */
      NSArray<NSString *> *patterns = [glob
          componentsSeparatedByCharactersInSet:
              [NSCharacterSet characterSetWithCharactersInString:@"; ,"]];

      for (NSString *pattern in patterns) {
        NSString *ext = pattern;
        /* Strip leading "*." or "." */
        if ([ext hasPrefix:@"*."]) {
          ext = [ext substringFromIndex:2];
        }
        else if ([ext hasPrefix:@"."]) {
          ext = [ext substringFromIndex:1];
        }

        if (ext.length == 0) {
          continue;
        }

        UTType *type = [UTType typeWithFilenameExtension:ext];
        if (type) {
          [contentTypes addObject:type];
        }
      }
    }

    /* If no specific types were resolved, allow all content. */
    if (contentTypes.count == 0) {
      [contentTypes addObject:UTTypeData];
      [contentTypes addObject:UTTypeFolder];
    }

    UIDocumentPickerViewController *picker = nil;

    /* Extract the default filename from default_path for save operations. */
    NSString *saveFilename = nil;

    if (action == GHOST_kFileDialogOpen) {
      picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:contentTypes];
      picker.allowsMultipleSelection = NO;
    }
    else {
      /* For save, use a folder picker. The user picks a destination directory, and Blender
       * writes the file directly into it with security-scoped access. This avoids the
       * initForExportingURLs approach which copies a placeholder — the copy is often not
       * writable afterward in the file provider's domain, leading to 0 KB files. */
      saveFilename = @"untitled.blend";
      if (default_path && default_path[0] != '\0') {
        NSString *pathStr = [NSString stringWithUTF8String:default_path];
        NSString *lastComponent = [pathStr lastPathComponent];
        if (lastComponent.length > 0 && [lastComponent containsString:@"."]) {
          saveFilename = lastComponent;
        }
      }

      picker = [[UIDocumentPickerViewController alloc]
          initForOpeningContentTypes:@[ UTTypeFolder ]];
      picker.allowsMultipleSelection = NO;
    }

    if (!picker) {
      return GHOST_kFailure;
    }

    /* Create and retain the delegate. The delegate will be released when the picker is dismissed.
     * We use objc_setAssociatedObject to tie its lifetime to the picker. */
    GHOST_IOSFilePickerDelegate *delegate = [[GHOST_IOSFilePickerDelegate alloc] init];
    delegate.ghostSystem = this;
    delegate.defaultFilename = saveFilename;
    picker.delegate = delegate;
    picker.presentationController.delegate = delegate;

    /* Tie delegate lifetime to picker via associated object. */
    objc_setAssociatedObject(
        picker, "ghost_delegate", delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (title) {
      picker.title = [NSString stringWithUTF8String:title];
    }

    /* Set initial directory if available. */
    if (default_path && default_path[0] != '\0') {
      NSString *pathStr = [NSString stringWithUTF8String:default_path];
      BOOL isDir = NO;
      if ([[NSFileManager defaultManager] fileExistsAtPath:pathStr isDirectory:&isDir]) {
        NSURL *dirURL;
        if (isDir) {
          dirURL = [NSURL fileURLWithPath:pathStr];
        }
        else {
          dirURL = [[NSURL fileURLWithPath:pathStr] URLByDeletingLastPathComponent];
        }
        picker.directoryURL = dirURL;
      }
    }

    /* Present the picker from the root view controller. */
    UIWindow *uiWindow = current_active_window->rootWindow;
    UIViewController *rootVC = uiWindow.rootViewController;
    if (!rootVC) {
      return GHOST_kFailure;
    }

    /* For save operations, prompt the user for a filename before showing the folder picker. */
    if (action == GHOST_kFileDialogSave && saveFilename.length > 0) {
      UIAlertController *alert = [UIAlertController
          alertControllerWithTitle:@"Save As"
                           message:@"Enter filename:"
                    preferredStyle:UIAlertControllerStyleAlert];

      [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = saveFilename;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        /* Select just the name part, without extension. */
        NSRange dotRange = [saveFilename rangeOfString:@"." options:NSBackwardsSearch];
        if (dotRange.location != NSNotFound) {
          UITextPosition *start = textField.beginningOfDocument;
          UITextPosition *end = [textField positionFromPosition:start
                                                        offset:(NSInteger)dotRange.location];
          if (start && end) {
            dispatch_async(dispatch_get_main_queue(), ^{
              textField.selectedTextRange = [textField textRangeFromPosition:start
                                                                 toPosition:end];
            });
          }
        }
      }];

      [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                style:UIAlertActionStyleCancel
                                              handler:^(UIAlertAction *_Nonnull a) {
                                                /* Push a cancel event. */
                                                GHOST_WindowIOS *window =
                                                    this->current_active_window;
                                                this->pushEvent(
                                                    std::make_unique<GHOST_EventString>(
                                                        this->getMilliSeconds(),
                                                        GHOST_kEventNativeFileDialogResult,
                                                        window,
                                                        static_cast<GHOST_TEventDataPtr>(
                                                            nullptr)));
                                                this->notifyExternalEventProcessed();
                                              }]];

      [alert
          addAction:[UIAlertAction
                        actionWithTitle:@"Save"
                                  style:UIAlertActionStyleDefault
                                handler:^(UIAlertAction *_Nonnull a) {
                                  NSString *newFilename = alert.textFields.firstObject.text;
                                  if (newFilename.length > 0) {
                                    delegate.defaultFilename = newFilename;
                                  }
                                  /* Now show the folder picker. */
                                  [rootVC presentViewController:picker
                                                       animated:YES
                                                     completion:nil];
                                }]];

      UIViewController *presenter = rootVC.presentedViewController ?: rootVC;
      if (presenter.presentedViewController) {
        [presenter dismissViewControllerAnimated:NO
                                      completion:^{
                                        [rootVC presentViewController:alert
                                                             animated:YES
                                                           completion:nil];
                                      }];
      }
      else {
        [presenter presentViewController:alert animated:YES completion:nil];
      }
    }
    else {
      /* Open mode or no filename — show the picker directly. */
      if (rootVC.presentedViewController) {
        [rootVC dismissViewControllerAnimated:NO
                                   completion:^{
                                     [rootVC presentViewController:picker
                                                          animated:YES
                                                        completion:nil];
                                   }];
      }
      else {
        [rootVC presentViewController:picker animated:YES completion:nil];
      }
    }

    return GHOST_kSuccess;
  }
}

// Note: called from NSWindow subclass
GHOST_TSuccess GHOST_SystemIOS::handleDraggingEvent(GHOST_TEventType eventType,
                                                    GHOST_TDragnDropTypes draggedObjectType,
                                                    GHOST_WindowIOS *window,
                                                    int mouseX,
                                                    int mouseY,
                                                    void *data)
{
  if (!validWindow((GHOST_IWindow *)window)) {
    return GHOST_kFailure;
  }
  switch (eventType) {
    case GHOST_kEventDraggingEntered:
    case GHOST_kEventDraggingUpdated:
    case GHOST_kEventDraggingExited:
      window->clientToScreenIntern(mouseX, mouseY, mouseX, mouseY);
      pushEvent(std::make_unique<GHOST_EventDragnDrop>(
          getMilliSeconds(), eventType, draggedObjectType, window, mouseX, mouseY, nullptr));
      break;

    case GHOST_kEventDraggingDropDone: {
      uint8_t *temp_buff;
      GHOST_TStringArray *strArray;
      NSArray *droppedArray;
      size_t pastedTextSize;
      NSString *droppedStr;
      GHOST_TDragnDropDataPtr eventData;
      int i;

      if (!data)
        return GHOST_kFailure;

      switch (draggedObjectType) {
        case GHOST_kDragnDropTypeFilenames:
          droppedArray = (NSArray *)data;

          strArray = (GHOST_TStringArray *)malloc(sizeof(GHOST_TStringArray));
          if (!strArray)
            return GHOST_kFailure;

          strArray->count = [droppedArray count];
          if (strArray->count == 0) {
            free(strArray);
            return GHOST_kFailure;
          }

          strArray->strings = (uint8_t **)malloc(strArray->count * sizeof(uint8_t *));

          for (i = 0; i < strArray->count; i++) {
            droppedStr = [droppedArray objectAtIndex:i];

            pastedTextSize = [droppedStr lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            temp_buff = (uint8_t *)malloc(pastedTextSize + 1);

            if (!temp_buff) {
              strArray->count = i;
              break;
            }

            strncpy((char *)temp_buff,
                    [droppedStr cStringUsingEncoding:NSUTF8StringEncoding],
                    pastedTextSize);
            temp_buff[pastedTextSize] = '\0';

            strArray->strings[i] = temp_buff;
          }

          eventData = static_cast<GHOST_TDragnDropDataPtr>(strArray);
          break;

        case GHOST_kDragnDropTypeString:
          droppedStr = (NSString *)data;
          pastedTextSize = [droppedStr lengthOfBytesUsingEncoding:NSUTF8StringEncoding];

          temp_buff = (uint8_t *)malloc(pastedTextSize + 1);

          if (temp_buff == NULL) {
            return GHOST_kFailure;
          }

          strncpy((char *)temp_buff,
                  [droppedStr cStringUsingEncoding:NSUTF8StringEncoding],
                  pastedTextSize);

          temp_buff[pastedTextSize] = '\0';

          eventData = static_cast<GHOST_TDragnDropDataPtr>(temp_buff);
          break;

        case GHOST_kDragnDropTypeBitmap: {
          /* Unsupported iOS. */
          return GHOST_kFailure;
          break;
        }
        default:
          return GHOST_kFailure;
          break;
      }

      pushEvent(std::make_unique<GHOST_EventDragnDrop>(
          getMilliSeconds(), eventType, draggedObjectType, window, mouseX, mouseY, eventData));

      break;
    }
    default:
      return GHOST_kFailure;
  }
  m_outsideLoopEventProcessed = true;
  return GHOST_kSuccess;
}

void GHOST_SystemIOS::handleQuitRequest()
{
  GHOST_Window *window = (GHOST_Window *)window_manager_->getActiveWindow();

  // Discard quit event if we are in cursor grab sequence
  if (window && window->getCursorGrabModeIsWarp())
    return;

  // Push the event to Blender so it can open a dialog if needed
  pushEvent(std::make_unique<GHOST_Event>(getMilliSeconds(), GHOST_kEventQuitRequest, window));
  m_outsideLoopEventProcessed = true;
}

bool GHOST_SystemIOS::handleOpenDocumentRequest(void *filepathStr)
{
  NSString *filepath = (NSString *)filepathStr;

  @autoreleasepool {
    if (!current_active_window) {
      return NO;
    }

    /* Discard event if we are in cursor grab sequence,
     * it'll lead to "stuck cursor" situation if the alert panel is raised. */
    if (current_active_window->getCursorGrabModeIsWarp()) {
      return NO;
    }

    const size_t filenameTextSize = [filepath lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    char *temp_buff = (char *)malloc(filenameTextSize + 1);

    if (temp_buff == nullptr) {
      return GHOST_kFailure;
    }

    memcpy(temp_buff, [filepath cStringUsingEncoding:NSUTF8StringEncoding], filenameTextSize);
    temp_buff[filenameTextSize] = '\0';

    pushEvent(std::make_unique<GHOST_EventString>(getMilliSeconds(),
                                    GHOST_kEventOpenMainFile,
                                    current_active_window,
                                    static_cast<GHOST_TEventDataPtr>(temp_buff)));
  }
  return YES;
}



#pragma mark Clipboard get/set

char *GHOST_SystemIOS::getClipboard(bool /*selection*/) const
{
  @autoreleasepool {
    UIPasteboard *pasteBoard = [UIPasteboard generalPasteboard];
    NSString *textPasted = pasteBoard.string;

    if (textPasted == nil) {
      return nullptr;
    }

    const size_t pastedTextSize = [textPasted lengthOfBytesUsingEncoding:NSUTF8StringEncoding];

    char *temp_buff = (char *)malloc(pastedTextSize + 1);

    if (temp_buff == nullptr) {
      return nullptr;
    }

    memcpy(temp_buff, [textPasted cStringUsingEncoding:NSUTF8StringEncoding], pastedTextSize);
    temp_buff[pastedTextSize] = '\0';
    return temp_buff;
  }
  return nullptr;
}

void GHOST_SystemIOS::putClipboard(const char *buffer, bool selection) const
{
  if (selection) {
    return; /* For copying the selection, used on X11. */
  }

  @autoreleasepool {
    UIPasteboard *pasteBoard = UIPasteboard.generalPasteboard;
    NSString *textToCopy = [NSString stringWithCString:buffer encoding:NSUTF8StringEncoding];
    [pasteBoard setString:textToCopy];
  }
}

GHOST_IWindow *GHOST_SystemIOS::getWindowUnderCursor(int32_t /*x*/, int32_t /*y*/)
{
  GHOST_ASSERT(FALSE, "GHOST_SystemIOS::getWindowUnderCursor unsupported on iOS");
  return NULL;
}
