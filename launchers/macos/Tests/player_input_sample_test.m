// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#import <GameController/GameController.h>
#import "../../../macos/player_input_sample.h"
#include <pthread.h>
#include <string.h>
static unsigned checks;
#define CHECK(x) do { checks++; if (!(x)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x); exit(1); } } while(0)
static s2a_player_input_frame readFrame(S2AMacPlayerInput *input, uint64_t now) {
    s2a_player_input_frame f; CHECK([input readFrame:&f capacity:sizeof f nowUs:now]); return f;
}
static BOOL neutral(s2a_player_input_frame f) {
    s2a_player_input_slot zero[4]={0}; return !memcmp(zero,f.slots,sizeof zero);
}
// Reader never touches platform objects. Main joins it before object destruction.
typedef struct { void *input; s2a_player_input_frame expected; } ReaderContext;
static void *reader(void *context) {
    @autoreleasepool {
        ReaderContext *c=context;
        S2AMacPlayerInput *input=(__bridge S2AMacPlayerInput *)c->input;
        for (unsigned i=0;i<10000;i++) {
            s2a_player_input_frame f;
            if (![input readFrame:&f capacity:sizeof f nowUs:100] || f.version!=1 || f.bytes!=96 || f.connected_mask!=15) return (void *)1;
            if ((!f.active && !neutral(f)) || f.active>1) return (void *)1;
            if (f.active && memcmp(f.slots,c->expected.slots,sizeof f.slots)) return (void *)1;
        }
    }
    return NULL;
}
int main(void) { @autoreleasepool {
    s2a_input_config config;s2a_input_config_default(&config);config.players_present=1;
    // Deliberately map four shoulder inputs to different face outputs, not identity.
    for(int i=0;i<24;i++) config.gamepad[i]=-1;
    for(int i=0;i<4;i++) config.gamepad[3-i]=6+i;
    config.axes[0]=(s2a_input_axis){3,0};config.axes[3]=(s2a_input_axis){0,1};config.deadzone=.25;
    S2AMacPlayerInput *input=[[S2AMacPlayerInput alloc] initWithConfig:&config];CHECK(input!=nil);
    // Config captured by value, never uses caller mutations during async sampling.
    config.gamepad[3]=-1; config.deadzone=1;
    NSMutableArray<GCController *> *pads=[NSMutableArray array];
    for(unsigned i=0;i<4;i++) {
        GCController *pad=[GCController controllerWithExtendedGamepad];CHECK(pad.isSnapshot);
        [pad.extendedGamepad.leftThumbstick.xAxis setValue:(i+1)*.2f];
        [pad.extendedGamepad.rightThumbstick.yAxis setValue:(i+1)*.2f];
        NSArray *buttons=@[pad.extendedGamepad.leftShoulder,pad.extendedGamepad.rightShoulder,pad.extendedGamepad.leftTrigger,pad.extendedGamepad.rightTrigger];
        [buttons[i] setValue:1];[pads addObject:pad];
    }
    s2a_player_input_frame f={0};
    CHECK(![input readFrame:&f capacity:sizeof f nowUs:100]);
    CHECK(![input publishControllers:pads token:0 active:YES nowUs:100]);
    uint64_t token=[input begin];CHECK(token!=0);
    CHECK([input publishControllers:pads token:token active:YES nowUs:100]);
    f=readFrame(input,100);CHECK(f.connected_mask==15&&f.active==1);
    NSMutableArray *assigned=[NSMutableArray array];
    for(unsigned i=0;i<4;i++) {
        unsigned source=0;while(source<4&&f.slots[i].buttons!=(1u<<(3-source))) source++;
        CHECK(source<4);[assigned addObject:pads[source]];
        int expected=source==0?0:(int)((source+1)*.2f*32767);
        CHECK(f.slots[i].lx==expected && f.slots[i].ry==-expected);
    }
    s2a_player_input_frame original=f;
    CHECK([input publishControllers:pads.reverseObjectEnumerator.allObjects token:token active:YES nowUs:100]);
    f=readFrame(input,100);CHECK(!memcmp(&f,&original,sizeof f));
    CHECK(([input publishControllers:@[assigned[1],assigned[3]] token:token active:YES nowUs:100]));
    f=readFrame(input,100);CHECK(f.connected_mask==10);
    CHECK(!memcmp(&f.slots[1],&original.slots[1],sizeof f.slots[1]));
    CHECK(!memcmp(&f.slots[3],&original.slots[3],sizeof f.slots[3]));
    CHECK(!f.slots[0].buttons&&!f.slots[2].buttons);
    CHECK([input publishControllers:pads token:token active:NO nowUs:100]);
    f=readFrame(input,100);CHECK(f.connected_mask==15&&!f.active&&neutral(f));
    CHECK([input readFrame:&f capacity:sizeof f nowUs:250100]);
    CHECK(![input readFrame:&f capacity:sizeof f nowUs:250101]&&neutral(f)&&!f.version);
    CHECK(![input readFrame:&f capacity:sizeof f nowUs:99]);
    uint64_t old=token;token=[input begin];CHECK(old!=token);
    CHECK([input publishControllers:pads token:token active:YES nowUs:100]);original=readFrame(input,100);
    CHECK(![input publishControllers:@[] token:old active:NO nowUs:100]);
    f=readFrame(input,100);CHECK(!memcmp(&f,&original,sizeof f));
    CHECK([input publishControllers:pads token:token active:YES nowUs:100]);
    f=readFrame(input,100);CHECK(!memcmp(&f,&original,sizeof f)); // stale callback did not retire ownership
    CHECK(![input publishControllers:pads token:token active:YES nowUs:0]);
    CHECK(![input readFrame:&f capacity:sizeof f nowUs:100]);
    CHECK([input publishControllers:pads token:token active:YES nowUs:100]);
    memset(&f,0xab,sizeof f);s2a_player_input_frame sentinel=f;
    CHECK(![input readFrame:&f capacity:sizeof f-1 nowUs:100]&&!memcmp(&f,&sentinel,sizeof f));
    ReaderContext context={(__bridge void *)input,readFrame(input,100)};
    pthread_t thread;CHECK(!pthread_create(&thread,NULL,reader,&context));
    for(unsigned i=0;i<1000;i++) CHECK([input publishControllers:pads token:token active:(i%2==0) nowUs:100]);
    void *result=NULL;CHECK(!pthread_join(thread,&result)&&!result);
    [input stop];CHECK(![input readFrame:&f capacity:sizeof f nowUs:100]&&neutral(f));
    CHECK(![input publishControllers:pads token:token active:YES nowUs:100]);
    token=[input begin];CHECK([input publishControllers:@[] token:token active:YES nowUs:100]);
    f=readFrame(input,100);CHECK(!f.connected_mask&&neutral(f));[input stop];
    // No acceptance of legacy configs or unfinished raw-HID routing.
    s2a_input_config_default(&config);CHECK(![[S2AMacPlayerInput alloc] initWithConfig:&config]);
    config.players_present=1;config.players[2].backend=1;CHECK(![[S2AMacPlayerInput alloc] initWithConfig:&config]);
    config.players[2].backend=3;config.axes[2].source=8;CHECK(![[S2AMacPlayerInput alloc] initWithConfig:&config]);
    s2a_input_config_default(&config);config.players_present=1;
    for(unsigned i=0;i<4;i++) config.players[i].backend=2;
    config.players[3].backend=3;
    S2AMacPlayerInput *fourth=[[S2AMacPlayerInput alloc] initWithConfig:&config];CHECK(fourth!=nil);
    uint64_t fourthToken=[fourth begin];
    CHECK([fourth publishControllers:pads token:fourthToken active:YES nowUs:100]);
    f=readFrame(fourth,100);CHECK(f.connected_mask==8);
    s2a_player_input_slot zeros[3]={0};CHECK(!memcmp(f.slots,zeros,sizeof zeros));
    CHECK(f.slots[3].buttons!=0);[fourth stop];
    printf("Mac sampled player snapshots: %u checks; synthetic controllers only\n",checks);
} }
