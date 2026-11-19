#import "mng_settings.h"
#include "mng/runtime.h"
static NSWindow *window;
static void (*update_mouse)(void);
static void front_mouse_update(void) { if (update_mouse) update_mouse(); }
#include "mng/input_settings_macos.inc"
void s2a_mng_settings_open(NSWindow *gameWindow, void (*mouseUpdate)(void)) {
    NSCAssert(NSThread.isMainThread, @"Input settings require main thread");
    window = gameWindow; update_mouse = mouseUpdate;
    if (!inputSettingsWindow) inputSettingsWindow = [D3InputSettings new];
    [inputSettingsWindow open:nil];
}
