"""Execute D3's actual port persistence and mode state, without real controllers."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[4]
PROBE = r'''
#import <Foundation/Foundation.h>
#include <pthread.h>
#include <stdatomic.h>
#include <assert.h>
#include "controller_state.h"
#include "gamepad_layout.h"
#define RUNTIME_MAX_GAMEPADS 4
#define TARGET_OS_OSX 1
static uint16_t controllerMap[CONTROLLER_BUTTONS], slotMap[4][CONTROLLER_BUTTONS];
static uint8_t controllerModes[CONTROLLER_BUTTONS], slotModes[4][CONTROLLER_BUTTONS];
static ControllerModeState slotModeState[4];
static int slotTypes[4], slotsInitialized, started, handheld, refreshes, backendChanges;
#define SLOT_BACKEND_CHANGED(slot, previous, next) do { (void)(slot); if ((previous)==4 && (next)!=4) ++backendChanges; } while(0)
static _Atomic int controllerType;
typedef struct { uint64_t buttons; int connected; } RuntimeGamepadState;
static RuntimeGamepadState gamepadStates[4], gamepadState;
static uint64_t pressedEdgesSlot[4], pressedEdges;
static pthread_mutex_t gamepadLock = PTHREAD_MUTEX_INITIALIZER;
static const char *directory;
static int setting_path(const char *name, char *out, size_t size) {
    return snprintf(out, size, "%s/%s", directory, name) < (int)size;
}
static void load_controller_map(void) { controller_map_default(controllerMap, controllerModes); }
static void load_controller_type(void) { atomic_store(&controllerType, GAMEPAD_TYPE_AUTO); }
static void refresh_gamepads(void) { ++refreshes; }
static int runtime_handheld_mode(void) { return handheld; }
#include "controller_slots.inc"
int main(int argc, char **argv) { @autoreleasepool {
    assert(argc == 2); directory = argv[1];
    assert(runtime_gamepad_slot_count() == 4);
    handheld = 1; assert(runtime_gamepad_slot_count() == 1);
    setenv("TOTK_CONTROLLER_MODE","fullkey",1); assert(runtime_gamepad_slot_count() == 4);
    unsetenv("TOTK_CONTROLLER_MODE"); handheld = 0;
    assert(runtime_gamepad_slot_type(0) == GAMEPAD_TYPE_AUTO);
    /* Global Pro is reversible via P1, never an independent P2 backend. */
    assert(runtime_gamepad_slot_type_set(0,4));
    assert(atomic_load(&controllerType)==4);
    slotsInitialized=0; assert(runtime_gamepad_slot_type(0)==4);
    /* Imported legacy thirdparty-pro must have an exit via per-player UI. */
    slotTypes[0]=4; atomic_store(&controllerType,4);
    const char *initialDir=directory; directory="/nonexistent-mng-slots-test";
    assert(!runtime_gamepad_slot_type_set(0,GAMEPAD_TYPE_AUTO));
    assert(slotTypes[0]==4 && !backendChanges);
    directory=initialDir;
    assert(runtime_gamepad_slot_type_set(0,GAMEPAD_TYPE_AUTO));
    assert(atomic_load(&controllerType)==0 && backendChanges==1);
    slotTypes[2]=4; assert(runtime_gamepad_slot_type_set(2,GAMEPAD_TYPE_AUTO));

    assert(runtime_gamepad_slot_type_set(0, GAMEPAD_TYPE_XBOX));
    assert(runtime_gamepad_slot_type_set(1, GAMEPAD_TYPE_SWITCH));
    assert(runtime_gamepad_slot_type(0) == GAMEPAD_TYPE_XBOX);
    assert(runtime_gamepad_slot_type(1) == GAMEPAD_TYPE_SWITCH);
    assert(runtime_gamepad_slot_type(2) == GAMEPAD_TYPE_AUTO);
    assert(runtime_gamepad_slot_mapping_set(1, 0, 7));
    assert(runtime_gamepad_slot_mapping_get(1, 0) == 7);
    assert(runtime_gamepad_slot_mapping_get(0, 0) == 1);
    assert(runtime_gamepad_slot_mapping_set(1, 17, 2));
    assert(!runtime_gamepad_slot_mapping_set(4, 0, 1));
    assert(!runtime_gamepad_slot_mapping_set(0, 22, 1));
    assert(!runtime_gamepad_slot_mapping_set(0, 0, 16));
    assert(runtime_gamepad_slot_type_set(1, GAMEPAD_TYPE_THIRDPARTY_PRO));
    assert(runtime_gamepad_slot_type(1) == GAMEPAD_TYPE_THIRDPARTY_PRO);
    assert(atomic_load(&controllerType) == GAMEPAD_TYPE_THIRDPARTY_PRO);
    assert(runtime_gamepad_slot_type_set(1, GAMEPAD_TYPE_SWITCH));
    assert(atomic_load(&controllerType) == GAMEPAD_TYPE_XBOX);
    assert(!runtime_gamepad_slot_type_set(-1, 0));
    assert(!runtime_gamepad_slot_type_set(1, GAMEPAD_TYPE_COUNT));
    slotsInitialized = 0;
    assert(runtime_gamepad_slot_type(0) == GAMEPAD_TYPE_XBOX);
    assert(runtime_gamepad_slot_type(1) == GAMEPAD_TYPE_SWITCH);
    assert(runtime_gamepad_slot_mapping_get(1, 0) == 7);
    const char *savedDirectory = directory; directory = "/nonexistent-mng-slots-test";
    assert(!runtime_gamepad_slot_type_set(1, GAMEPAD_TYPE_XBOX));
    assert(!runtime_gamepad_slot_mapping_set(1, 0, 4));
    assert(runtime_gamepad_slot_type(1) == GAMEPAD_TYPE_SWITCH);
    assert(runtime_gamepad_slot_mapping_get(1, 0) == 7);
    directory = savedDirectory;
    /* Changing one port clears only that port's mode and latched edges. */
    slotModeState[0].previous = 12; slotModeState[1].previous = 13;
    pressedEdgesSlot[0] = 3; pressedEdgesSlot[1] = 5;
    started = 1;
    assert(runtime_gamepad_slot_mapping_reset(1)); assert(refreshes == 1);
    assert(slotModeState[0].previous == 12 && slotModeState[1].previous == 0);
    assert(pressedEdgesSlot[0] == 3 && pressedEdgesSlot[1] == 0);
    assert(runtime_gamepad_slot_mapping_get(1, 17) == 2); /* preserve mouse */
    assert(runtime_gamepad_slot_mapping_get(1, 0) == 1);
    /* Target-first edits persist atomically and do not touch another group. */
    assert(runtime_input_binding_get(1,0,0)==1);
    assert(runtime_input_binding_set(1,0,0,2));
    assert(runtime_input_binding_get(1,0,0)==2 && runtime_gamepad_slot_mapping_get(1,1)==-1);
    assert(runtime_gamepad_slot_mapping_get(1,17)==2);
    assert(runtime_gamepad_slot_mapping_set(1,3,0));assert(runtime_input_binding_get(1,0,0)==-2);
    directory="/nonexistent-mng-slots-test";
    assert(!runtime_input_binding_set(1,0,0,4));assert(runtime_input_binding_get(1,0,0)==-2);
    directory=savedDirectory;
    assert(!runtime_input_binding_set(1,1,0,17));
    assert(!runtime_input_binding_set(0,0,0,17));
    assert(runtime_input_binding_set(0,1,0,17));assert(runtime_input_binding_get(0,1,0)==17);
    assert(runtime_input_binding_reset(0,1));assert(runtime_input_binding_get(0,1,3)==17);
    assert(runtime_input_binding_set(1,0,0,-1));assert(runtime_input_binding_get(1,0,0)==-1);
    slotsInitialized=0;assert(runtime_input_binding_get(1,0,0)==-1);
    /* Reject a bad later port atomically, not after applying the first one. */
    NSMutableDictionary *root = [[NSDictionary dictionaryWithContentsOfFile:slot_path()] mutableCopy];
    NSMutableArray *ports = [root[@"ports"] mutableCopy];
    ports[3] = @{@"type":@99, @"layout":@""}; root[@"ports"] = ports;
    assert([root writeToFile:slot_path() atomically:YES]);
    slotsInitialized = 0; started = 0;
    assert(runtime_gamepad_slot_type(0) == GAMEPAD_TYPE_AUTO);
    assert(runtime_gamepad_slot_type(1) == GAMEPAD_TYPE_AUTO);

    uint16_t map[CONTROLLER_BUTTONS]; uint8_t modes[CONTROLLER_BUTTONS];
    controller_map_default(map, modes);
    ControllerModeState a = {0}, b = {0}; int pulse;
    map[0] = 1; modes[0] = CONTROLLER_TOGGLE;
    assert(controller_state_apply(&a, map, modes, 1, 0, 1, 10, &pulse) == 1);
    assert(controller_state_apply(&b, map, modes, 0, 0, 1, 10, &pulse) == 0);
    assert(controller_state_apply(&a, map, modes, 0, 1, 1, 20, &pulse) == 1);
    assert(controller_state_apply(&a, map, modes, 0, 0, 1, 30, &pulse) == 0);
    assert(controller_state_apply(&a, map, modes, 1, 0, 1, 40, &pulse) == 1);
    assert(controller_state_apply(&a, map, modes, 0, 0, 0, 50, &pulse) == 0);
    a = (ControllerModeState){0}; modes[0] = CONTROLLER_TAP;
    assert(controller_state_apply(&a, map, modes, 1, 0, 1, 100, &pulse) == 1 && pulse);
    assert(controller_state_apply(&a, map, modes, 1, 0, 1, 200, &pulse) == 1 && !pulse);
    assert(controller_state_apply(&b, map, modes, 0, 0, 1, 200, &pulse) == 0);
    assert(controller_state_apply(&a, map, modes, 0, 0, 1, 400000100, &pulse) == 0);
    /* Two inputs targeting the same button keep independent physical edges. */
    a = (ControllerModeState){0}; modes[0] = CONTROLLER_HOLD; map[1] = 1; modes[1] = CONTROLLER_TOGGLE;
    assert(controller_state_apply(&a, map, modes, 1, 0, 1, 1, &pulse) == 1);
    assert(controller_state_apply(&a, map, modes, 3, 0, 1, 2, &pulse) == 1);
    assert(controller_state_apply(&a, map, modes, 0, 0, 1, 3, &pulse) == 1);
    a = (ControllerModeState){0}; controller_map_default(map, modes);
    const uint64_t left = UINT64_C(1) << CONTROLLER_MOUSE_FIRST;
    const uint64_t right = left << 1;
    assert(controller_state_apply(&a, map, modes, right, 0, 1, 1, &pulse) == (1u << 9));
    assert(controller_state_apply(&a, map, modes, right | left, 0, 1, 2, &pulse) == 0);
    puts("PASS independent port types/maps/modes, atomic persistence and reset");
} }
'''

class ControllerSlotTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'darwin' and shutil.which('clang'), 'requires macOS')
    def test_production_port_settings(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp)/'probe.m'; src.write_text(PROBE)
            exe = Path(tmp)/'probe'
            build = subprocess.run(['clang', '-fobjc-arc', '-Wall', '-Wextra', '-Werror',
                '-I'+str(ROOT/'macos/controllers/mng'), str(src), '-framework', 'Foundation', '-o', str(exe)],
                capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stderr)
            subprocess.run(['ps', '-axo', 'pid=,comm='], check=True, stdout=subprocess.DEVNULL)
            run = subprocess.run([exe, tmp], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stdout+run.stderr)
            self.assertIn('PASS', run.stdout)

