"""Original MNG settings/sampling through the S2Arm ABI, synthetic state only."""
from pathlib import Path
import json
import hashlib
import os
import sys
from types import SimpleNamespace
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[4]
MNG = ROOT / 'macos/controllers/mng'
PROBE = r'''
#import <Foundation/Foundation.h>
#include <assert.h>
#include <time.h>
#include "mng/runtime.h"
#include "mng_adapter.h"
// The original producer is included to inject synthetic state, never hardware.
#include "mng/gamepad.m"
_Noreturn void runtime_fail(const char *text) { fprintf(stderr,"%s\n",text); abort(); }
uint64_t runtime_now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec*1000000000ull+t.tv_nsec; }
int runtime_handheld_mode(void) { return 0; }
void runtime_keys_clear(void) { s2a_mng_input_keys_clear(); runtime_keyboard_clear(); }
void runtime_input_clear(void) { runtime_keys_clear(); runtime_gamepad_clear(); }
void runtime_input_gamepads_changed(void) { s2a_mng_input_keys_clear(); }
static int test_rumble_on, test_gyro_on;
int runtime_rumble_enabled(void) { return test_rumble_on; }
int runtime_gyro_enabled(void) { return test_gyro_on; }
void runtime_hid_feedback_stats(uint64_t *values,uint64_t *reads) { if(values)*values=0; if(reads)*reads=0; }
int main(int argc,char **argv) { @autoreleasepool {
 assert(argc==3);
 int ok=s2a_mng_input_prepare(argv[1]);
 if(!strcmp(argv[2],"reject")) { assert(!ok); return 0; }
 assert(ok); assert(!s2a_mng_input_prepare(argv[1]));
 if(!strcmp(argv[2],"hold")) { puts("ready");fflush(stdout);getchar();return 0; }
 if(!strcmp(argv[2],"feedback")) {
  test_rumble_on=1; test_gyro_on=1;
  assert(s2a_mng_pad_rumble_session()==1);
  s2a_pad_vibration pair[2]={{0.5f,160.0f,0.25f,320.0f},{0.75f,180.0f,0.125f,360.0f}};
  s2a_mng_pad_set_player_rumble_pair(1,2,pair);
  s2a_mng_pad_stop_rumble(1);
  s2a_pad_motion motion={0};
  assert(!s2a_mng_pad_read_motion(&motion));
  s2a_mng_pad_set_motion_enabled(1);
  runtime_motion_live(1);
  double acc[3]={0.25,-0.5,-1.0}, gyro[3]={M_PI,-2*M_PI,0.5*M_PI};
  uint64_t ts0=runtime_now_ns();
  runtime_motion_feed(acc,gyro,ts0);
  assert(s2a_mng_pad_read_motion(&motion)==1);
  assert(motion.host_timestamp_us>0);
  assert(fabsf(motion.acceleration_x - (-0.25f)) < 1e-4f);
  assert(fabsf(motion.acceleration_y - 0.5f) < 1e-4f);
  assert(fabsf(motion.acceleration_z - 1.0f) < 1e-4f);
  assert(fabsf(motion.gyro_x - 180.0f) < 1e-2f);
  assert(fabsf(motion.gyro_y - (-360.0f)) < 1e-2f);
  assert(fabsf(motion.gyro_z - 90.0f) < 1e-2f);
  uint64_t ts1=motion.host_timestamp_us;
  assert(s2a_mng_pad_read_motion(&motion)==1);
  assert(motion.host_timestamp_us==ts1);
  runtime_motion_feed(acc,gyro,ts0);
  assert(s2a_mng_pad_read_motion(&motion)==1);
  assert(motion.host_timestamp_us>ts1);
  assert(runtime_input_source_set(0,INPUT_SOURCE_KEYBOARD));
  assert(!s2a_mng_pad_read_motion(&motion));
  assert(runtime_input_source_set(0,INPUT_SOURCE_PAD));
  runtime_motion_live(1);
  runtime_motion_feed(acc,gyro,runtime_now_ns());
  assert(s2a_mng_pad_read_motion(&motion)==1);
  s2a_mng_pad_set_motion_enabled(0);
  assert(!s2a_mng_pad_read_motion(&motion));
  return 0;
 }
 if(!strcmp(argv[2],"keyboard")) {
  // No hardware discovery: original coalesced keyboard producer only.
  kb_start();
  s2a_player_input_frame frame;
  assert(runtime_keyboard_slot()==-1);
  s2a_mng_input_key(38,1); s2a_mng_input_key(38,0); // J / A, short edge
  s2a_mng_input_key(2,1); // D / left stick right
  assert(s2a_mng_input_read(&frame,sizeof frame));
  assert(frame.connected_mask==1 && frame.slots[0].buttons==1 && frame.slots[0].lx==32767);
  assert(s2a_mng_input_read(&frame,sizeof frame) && !frame.slots[0].buttons);
  runtime_keys_clear();
  s2a_mng_input_key(49,1); // Original legacy Space / B alias
  assert(s2a_mng_input_read(&frame,sizeof frame) && frame.slots[0].buttons==2);
  runtime_input_settings_suspend(1);
  s2a_mng_input_key(38,1);
  assert(s2a_mng_input_read(&frame,sizeof frame) && !frame.slots[0].buttons && !frame.slots[0].lx);
  runtime_input_settings_suspend(0);
  assert(s2a_mng_input_read(&frame,sizeof frame) && !frame.slots[0].buttons);
  s2a_mng_input_key(38,1);
  assert(runtime_input_source_set(0,INPUT_SOURCE_PAD));
  assert(runtime_input_source_set(0,INPUT_SOURCE_COMPAT));
  assert(s2a_mng_input_read(&frame,sizeof frame) && !frame.slots[0].buttons);
  s2a_mng_input_key(38,1);
  assert(runtime_keyboard_bind(1)); // Binding transition discards P1 fallback.
  s2a_mng_input_key(38,1); // P2 off: must NOT redirect into P1.
  assert(s2a_mng_input_read(&frame,sizeof frame) && !frame.slots[0].buttons && !frame.slots[1].buttons);
  assert(runtime_input_source_set(1,INPUT_SOURCE_KEYBOARD));
  s2a_mng_input_key(38,1); s2a_mng_input_key(38,0);
  assert(s2a_mng_input_read(&frame,sizeof frame));
  assert(!frame.slots[0].buttons && frame.slots[1].buttons==1 && (frame.connected_mask&2));
  assert(s2a_mng_input_read(&frame,sizeof frame) && !frame.slots[1].buttons);
  return 0;
 }
 if(!strcmp(argv[2],"launcher")) {
  input_source_load();
  int sources[4]={3,2,1,5}, types[4]={0,4,2,3};
  for(int i=0;i<4;i++) {
   assert(runtime_input_source(i)==sources[i]);
   assert(runtime_gamepad_slot_type(i)==types[i]);
  }
  assert([runtime_gamepad_device_binding(0) isEqual:@"auto"]);
  assert([runtime_gamepad_device_binding(1) isEqual:@"none"]);
  assert([runtime_gamepad_device_binding(3) isEqual:@"session:12345678-1234-1234-1234-123456789ABC"]);
  return 0;
 }
 if(!strcmp(argv[2],"load")) {
  assert(runtime_gamepad_slot_mapping_get(1,0)==7); return 0;
 }
 assert(runtime_gamepad_slot_type_set(0,GAMEPAD_TYPE_XBOX));
 assert(runtime_gamepad_slot_type_set(1,GAMEPAD_TYPE_SWITCH));
 assert(runtime_input_source_set(0,INPUT_SOURCE_PAD));
 assert(runtime_input_source_set(1,INPUT_SOURCE_PAD));
 assert(runtime_gamepad_slot_mapping_set(1,0,7));
 assert(runtime_gamepad_slot_mapping_get(0,0)==1);
 // Original state publisher -> original consumer -> S2Arm four-port POD ABI.
 pthread_mutex_lock(&gamepadLock);
 gamepadStates[0]=(RuntimeGamepadState){.buttons=1,.lx=123,.connected=1};
 gamepadStates[1]=(RuntimeGamepadState){.buttons=128,.ry=-456,.connected=1};
 pressedEdgesSlot[1]=4;
 pthread_mutex_unlock(&gamepadLock);
 s2a_player_input_frame frame;
 assert(!s2a_mng_input_read(&frame,sizeof frame-1));
 assert(s2a_mng_input_read(&frame,sizeof frame));
 assert(frame.version==1 && frame.bytes==sizeof frame && frame.connected_mask==3);
 assert(frame.slots[0].buttons==1 && frame.slots[0].lx==123);
 assert(frame.slots[1].buttons==132 && frame.slots[1].ry==-456);
 assert(!frame.slots[2].buttons && !frame.slots[3].buttons);
 assert(s2a_mng_input_read(&frame,sizeof frame) && frame.slots[1].buttons==128);
 runtime_input_settings_suspend(1);
 assert(s2a_mng_input_read(&frame,sizeof frame));
 assert(!frame.slots[0].buttons && !frame.slots[1].buttons);
 runtime_input_settings_suspend(0);
 puts("PASS original mapping persistence and actual S2Arm readout");
} }
'''

class MNGAdapterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='s2a-mng-adapter-')
        cls.root = Path(cls.temp.name).resolve()
        src=cls.root/'probe.m';src.write_text(PROBE);cls.exe=cls.root/'probe'
        command=['clang','-fobjc-arc','-Wall','-Wextra','-I'+str(MNG.parent),str(src),
                 str(MNG.parent/'mng_adapter.m'),str(MNG.parent/'mng_ownership.c'),
                 str(MNG/'gamepad_feedback.m'),str(MNG/'motion_fusion.c'),
                 '-framework','Foundation','-framework','AppKit','-framework','GameController',
                 '-framework','IOKit','-framework','CoreHaptics','-o',str(cls.exe)]
        result=subprocess.run(command,capture_output=True,text=True)
        if result.returncode: raise AssertionError(result.stderr)
    @classmethod
    def tearDownClass(cls): cls.temp.cleanup()
    def launch(self,folder,mode):
        subprocess.run(['ps','-axo','pid=,comm='],check=True,stdout=subprocess.DEVNULL)
        env={k:v for k,v in os.environ.items() if not k.startswith(('TOTK_','MNG_'))}
        return subprocess.run([self.exe,folder,mode],env=env,capture_output=True,text=True,timeout=15)
    def test_migration_hashes_and_documented_adaptations(self):
        manifest = json.loads((MNG/'migration.json').read_text())
        adaptations = manifest.get('localAdaptations', {})
        self.assertLessEqual(set(adaptations), set(manifest['files']))
        for name, original in manifest['files'].items():
            expected = original
            if name in adaptations:
                self.assertTrue(adaptations[name]['reason'].strip(), name)
                expected = adaptations[name]['sha256']
                self.assertNotEqual(original, expected, name)
            self.assertEqual(hashlib.sha256((MNG/name).read_bytes()).hexdigest(), expected, name)
    def test_jobs_writer_to_native_loader_and_owner_exclusion(self):
        sys.path.insert(0, str(ROOT/'pack/jobs'))
        from library import _sync_mng_players
        from library import _mng_input_root as mng_input_root
        from core import Failure
        with tempfile.TemporaryDirectory(dir=self.root) as tmp:
            root = Path(tmp)
            c = SimpleNamespace(library=root/'library', private=root/'private', r={'userId': '01'})
            gid = '0100000000000000'
            sources = [3, 2, 1, 5]; types = [0, 4, 2, 3]
            devices = ['', 'none', '', 'session:12345678-1234-1234-1234-123456789ABC']
            config = dict(players={str(i+1):dict(backend='nspro-hid' if types[i] == 4 else 'system',
                device=devices[i], type=types[i], source=sources[i]) for i in range(4)})
            _sync_mng_players(c, gid, config)
            folder = mng_input_root(c, gid)
            result = self.launch(folder, 'launcher')
            self.assertEqual(result.returncode, 0, result.stderr)
            before = {p.name: p.read_bytes() for p in folder.glob('*.plist')}
            subprocess.run(['ps','-axo','pid=,comm='], check=True, stdout=subprocess.DEVNULL)
            env = {k:v for k,v in os.environ.items() if not k.startswith(('TOTK_', 'MNG_'))}
            p = subprocess.Popen([self.exe, folder, 'hold'], env=env, stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                self.assertEqual(p.stdout.readline().strip(), 'ready')
                with self.assertRaises(Failure): _sync_mng_players(c, gid, config)
                self.assertEqual({p.name: p.read_bytes() for p in folder.glob('*.plist')}, before)
            finally: p.communicate('\n', timeout=5)

    def test_two_user_roots_persist_without_cross_reads(self):
        with tempfile.TemporaryDirectory(dir=self.root) as tmp:
            one=Path(tmp)/'one';two=Path(tmp)/'two';one.mkdir();two.mkdir()
            for root in (one,two):
                result=self.launch(root,'write');self.assertEqual(result.returncode,0,result.stderr)
                result=self.launch(root,'load');self.assertEqual(result.returncode,0,result.stderr)
            self.assertNotEqual((one/'controller-slots.plist').stat().st_ino,(two/'controller-slots.plist').stat().st_ino)
    def test_original_keyboard_fallback_and_inactive_reservation(self):
        with tempfile.TemporaryDirectory(dir=self.root) as tmp:
            result=self.launch(tmp,'keyboard');self.assertEqual(result.returncode,0,result.stderr)
    def test_motion_and_rumble_bridge(self):
        with tempfile.TemporaryDirectory(dir=self.root) as tmp:
            result=self.launch(tmp,'feedback');self.assertEqual(result.returncode,0,result.stderr)
    def test_linked_config_rejected_before_write(self):
        with tempfile.TemporaryDirectory(dir=self.root) as tmp:
            root=Path(tmp);target=root/'fixture';target.write_text('unchanged')
            (root/'controller-slots.plist').symlink_to(target)
            result=self.launch(root,'reject');self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(target.read_text(),'unchanged')
    def test_original_kernel_lock_excludes_same_root(self):
        with tempfile.TemporaryDirectory(dir=self.root) as tmp:
            subprocess.run(['ps','-axo','pid=,comm='],check=True,stdout=subprocess.DEVNULL)
            env={k:v for k,v in os.environ.items() if not k.startswith(('TOTK_','MNG_'))}
            p=subprocess.Popen([self.exe,tmp,'hold'],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            try:
                self.assertEqual(p.stdout.readline().strip(),'ready')
                result=self.launch(tmp,'reject');self.assertEqual(result.returncode,0,result.stderr)
            finally: p.communicate('\n',timeout=5)
            result=self.launch(tmp,'write');self.assertEqual(result.returncode,0,result.stderr)
