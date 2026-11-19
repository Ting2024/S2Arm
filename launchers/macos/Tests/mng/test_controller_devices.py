"""Test the actual device settings adapter and portable ownership resolver."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[4]
PROBE=r'''
#import <Foundation/Foundation.h>
#include <stdatomic.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#define RUNTIME_MAX_GAMEPADS 4
#define TARGET_OS_OSX 1
#define GAMEPAD_TYPE_THIRDPARTY_PRO 4
@interface GCController : NSObject
@property(copy) NSString *vendorName;
@property BOOL extendedGamepad;
@property(class,readonly) NSArray *controllers;
@end
static NSArray *connected;
@implementation GCController
+ (NSArray *)controllers { return connected ?: @[]; }
@end
static GCController *gamepadSlots[4];
static _Atomic int controllerType;
static int started=1, refreshed;
static const char *directory;
static int setting_path(const char *name,char *out,size_t size) { return snprintf(out,size,"%s/%s",directory,name)<(int)size; }
static int slot_valid(int slot) { return slot>=0 && slot<4; }
static void slot_load(void) {}
static void refresh_gamepads(void) { ++refreshed; }
static void runtime_fail(const char *message) { fprintf(stderr,"%s",message); abort(); }
static int padAllowed[4]={1,1,1,1};
#define DEVICE_SLOT_ACCEPTS_PAD(s) padAllowed[s]
#include "controller_devices.inc"
static GCController *pad(NSString *name) { GCController *p=[GCController new]; p.vendorName=name; p.extendedGamepad=YES; return p; }
int main(int argc,char **argv) { @autoreleasepool {
    assert(argc==2); directory=argv[1];
    GCController *a=pad(@"Same vendor"), *b=pad(@"Same vendor"), *c=pad(@"Switch");
    connected=@[a,b,c];
    NSArray *snapshot=runtime_gamepad_devices(); assert(snapshot.count==3);
    NSString *aid=snapshot[0][@"id"], *bid=snapshot[1][@"id"], *cid=snapshot[2][@"id"];
    assert(![aid isEqual:bid]); assert([device_id(a) isEqual:aid]);
    assert(device_slot_auto(0));
    gamepadSlots[0]=a; gamepadSlots[1]=b;
    assert(runtime_gamepad_device_bind(2,aid)); /* move out of automatic port */
    assert(refreshed==1);
    NSArray *r=device_resolve(device_list());
    assert(r[2]==a && r[1]==b && r[0]==c && r[3]==NSNull.null);
    assert(!runtime_gamepad_device_bind(1,aid)); /* no duplicated reservation */
    assert([runtime_gamepad_device_binding(1) isEqual:@"auto"]);
    assert(runtime_gamepad_device_bind(1,bid));
    assert(runtime_gamepad_device_bind(0,@"none"));
    r=device_resolve(device_list()); assert(r[0]==NSNull.null && r[1]==b && r[2]==a && r[3]==c);
    padAllowed[1]=0; r=device_resolve(device_list());
    assert(r[1]==NSNull.null && r[2]==a && r[3]==b);
    assert(!device_slot_auto(1));
    padAllowed[1]=1;
    /* A stale UI snapshot never chooses the next item in a reordered list. */
    connected=@[c,a]; assert(!runtime_gamepad_device_bind(3,bid));
    r=device_resolve(device_list()); assert(r[1]==NSNull.null && r[2]==a && r[3]==c);
    assert([runtime_gamepad_device_label(1) containsString:@"离线"]);
    GCController *replacement=pad(@"Same vendor"); connected=@[replacement,c,a];
    r=device_resolve(device_list()); assert(r[1]==NSNull.null && r[2]==a);
    assert(![device_id(replacement) isEqual:bid]);
    /* The same live object, if restored, does satisfy its reservation. */
    connected=@[b,a,c]; r=device_resolve(device_list()); assert(r[1]==b && r[2]==a);
    const char *saved=directory; directory="/nonexistent-mng-devices-test";
    assert(!runtime_gamepad_device_bind(2,@"none")); assert([runtime_gamepad_device_binding(2) isEqual:aid]);
    directory=saved;
    deviceBindingsLoaded=0;
    assert([runtime_gamepad_device_binding(0) isEqual:@"none"]);
    assert([runtime_gamepad_device_binding(1) isEqual:bid]);
    assert([runtime_gamepad_device_binding(2) isEqual:aid]);
    assert(!runtime_gamepad_device_bind(-1,@"auto")); assert(!runtime_gamepad_device_bind(4,@"auto"));
    assert(!runtime_gamepad_device_bind(0,@"vendor:Same vendor"));
    assert(!runtime_gamepad_device_bind(0,@"session:bad"));
    assert(!runtime_gamepad_device_bind(0,nil));
    atomic_store(&controllerType,4); assert(!runtime_gamepad_device_bind(0,@"auto"));
    assert(!device_slot_auto(0)); /* explicit none still respected */
    assert(device_slot_auto(1) && device_slot_auto(2)); /* session reservations bypassed, not erased */
    padAllowed[2]=0; assert(!device_slot_auto(2)); padAllowed[2]=1;
    assert([runtime_gamepad_device_binding(1) isEqual:bid]);
    atomic_store(&controllerType,0);
    assert(!device_slot_auto(1) && !device_slot_auto(2));
    r=device_resolve(device_list());assert(r[1]==b && r[2]==a);
    /* Duplicate persisted ownership is rejected as one transaction. */
    NSMutableDictionary *root=[[NSDictionary dictionaryWithContentsOfFile:device_path()] mutableCopy];
    NSMutableArray *ports=[root[@"ports"] mutableCopy]; ports[0]=ports[1]; root[@"ports"]=ports;
    assert([root writeToFile:device_path() atomically:YES]); deviceBindingsLoaded=0;
    for(int s=0;s<4;++s)assert(device_slot_auto(s));
    /* Ambiguous identity input cannot be selected explicitly. */
    const char *binding[]={"id-a","auto","none","absent"};
    const char *ids[]={"id-a","id-a","id-b"}; int prev[]={-1,2,-1,-1}, result[4];
    controller_assignment_resolve(4,binding,3,ids,prev,result);
    assert(result[0]==-1 && result[1]==2 && result[2]==-1 && result[3]==-1);
    /* Reservation wins even when its port is later than an automatic owner. */
    const char *binding2[]={"auto","id-b","id-a","none"};
    const char *ids2[]={"id-a","id-b","id-c"}; int prev2[]={0,1,2,-1};
    controller_assignment_resolve(4,binding2,3,ids2,prev2,result);
    assert(result[0]==2 && result[1]==1 && result[2]==0 && result[3]==-1);
    /* A new process creates fresh connection IDs; old reservations stay offline. */
    assert(runtime_gamepad_device_bind(2,aid));
    deviceIDs=nil; deviceNames=nil; deviceBindingsLoaded=0;
    r=device_resolve(device_list()); assert(r[2]==NSNull.null);
    assert([runtime_gamepad_device_label(2) containsString:@"离线"]);
    /* Exhaust every combination of auto/none/A/B/absent across four ports. */
    const char *options[]={"auto","none","id-a","id-b","missing"};
    const char *unique[]={"id-a","id-b","id-c"};
    for(int code=0;code<625;++code) {
        int n=code; const char *configuration[4];
        for(int s=0;s<4;++s) { configuration[s]=options[n%5]; n/=5; }
        controller_assignment_resolve(4,configuration,3,unique,prev2,result);
        for(int s=0;s<4;++s) {
            assert(result[s]>=-1 && result[s]<3);
            if(!strcmp(configuration[s],"none") || !strcmp(configuration[s],"missing")) assert(result[s]==-1);
            if(result[s]>=0) {
                for(int p=0;p<s;++p) assert(result[p]!=result[s]);
                if(strcmp(configuration[s],"auto")) assert(!strcmp(configuration[s],unique[result[s]]));
            }
        }
    }
    (void)cid;
    puts("PASS exclusive device routing, conservative reconnect, stale snapshots, persistence and save failure");
} }
'''
class DeviceAssignmentTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform=='darwin' and shutil.which('clang'),'requires macOS')
    def test_production_adapter(self):
        with tempfile.TemporaryDirectory() as tmp:
            source=Path(tmp)/'probe.m'; source.write_text(PROBE); exe=Path(tmp)/'probe'
            build=subprocess.run(['clang','-fobjc-arc','-Wall','-Wextra','-Werror',
                '-I'+str(ROOT/'macos/controllers/mng'),str(source),'-framework','Foundation','-o',str(exe)],capture_output=True,text=True)
            self.assertEqual(build.returncode,0,build.stderr)
            subprocess.run(['ps','-axo','pid=,comm='],check=True,stdout=subprocess.DEVNULL)
            run=subprocess.run([exe,tmp],capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr)
            self.assertIn('PASS',run.stdout)
