// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Actual production sampler with injected sensor objects, no hardware discovery.
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import "../../../macos/controllers/include/S2AControllerInput.h"
#include <math.h>
#include <pthread.h>
@interface S2AControllerInput (SystemMotionTest)
- (void)updateSystemMotion:(GCMotion *)motion;
@end
@interface SensorFixture : NSObject
@property GCAcceleration acceleration;
@property GCRotationRate rotationRate;
@property BOOL hasRotationRate, sensorsActive, sensorsRequireManualActivation;
@property(copy) GCMotionValueChangedHandler valueChangedHandler;
@end
@implementation SensorFixture
@end
static unsigned checks;
#define CHECK(x) do { checks++; if (!(x)) { fprintf(stderr,"FAIL %d: %s\n",__LINE__,#x); exit(1); } } while(0)
static SensorFixture *sensor(void) {
    SensorFixture *s=[SensorFixture new];s.hasRotationRate=YES;s.sensorsRequireManualActivation=YES;
    s.acceleration=(GCAcceleration){1,-2,-1};s.rotationRate=(GCRotationRate){M_PI,-M_PI/2,0};return s;
}
static void emit(SensorFixture *s) { if(s.valueChangedHandler) s.valueChangedHandler((GCMotion *)s); }
typedef struct { void *handler,*sensor; } Context;
static void *late(void *arg) {
    @autoreleasepool { Context *c=arg; GCMotionValueChangedHandler h=(__bridge id)c->handler;
        for(unsigned i=0;i<10000;i++) h((__bridge GCMotion *)c->sensor); }
    return NULL;
}
int main(void) { @autoreleasepool {
    S2AControllerInput *input=[S2AControllerInput new];SensorFixture *a=sensor(),*b=sensor();
    S2AControllerMotion sample;
    [input updateSystemMotion:(GCMotion *)a];CHECK(!a.sensorsActive&&!a.valueChangedHandler);
    input.motionEnabled=YES;[input updateSystemMotion:(GCMotion *)a];
    CHECK(a.sensorsActive&&a.valueChangedHandler);CHECK(![input readMotion:&sample]);
    emit(a);CHECK([input readMotion:&sample]);
    CHECK(sample.acceleration[0]==-1&&sample.acceleration[1]==2&&sample.acceleration[2]==1);
    CHECK(fabs(sample.gyro[0]-180)<.001&&fabs(sample.gyro[1]+90)<.001&&sample.gyro[2]==0);
    uint64_t timestamp=sample.timestampUs;CHECK([input readMotion:&sample]&&sample.timestampUs==timestamp);
    GCMotionValueChangedHandler old=a.valueChangedHandler;
    input.motionEnabled=NO;CHECK(!a.sensorsActive&&!a.valueChangedHandler);
    old((GCMotion *)a);CHECK(![input readMotion:&sample]&&!sample.timestampUs);
    input.motionEnabled=YES;[input updateSystemMotion:(GCMotion *)b];
    old((GCMotion *)a);CHECK(![input readMotion:&sample]);
    b.acceleration=(GCAcceleration){3,4,5};emit(b);CHECK([input readMotion:&sample]&&sample.acceleration[0]==-3);
    old((GCMotion *)a);CHECK([input readMotion:&sample]&&sample.acceleration[0]==-3);
    [NSThread sleepForTimeInterval:.27];CHECK(![input readMotion:&sample]&&!sample.timestampUs);
    emit(b);CHECK([input readMotion:&sample]);
    b.rotationRate=(GCRotationRate){NAN,0,0};emit(b);CHECK(![input readMotion:&sample]);
    b.rotationRate=(GCRotationRate){0,INFINITY,0};emit(b);CHECK(![input readMotion:&sample]);
    b.rotationRate=(GCRotationRate){0,0,0};b.acceleration=(GCAcceleration){NAN,0,0};emit(b);CHECK(![input readMotion:&sample]);
    // Do not steal another user's callbacks, including an intervening replacement.
    GCMotionValueChangedHandler other=^(GCMotion *m){(void)m;};
    b.valueChangedHandler=other;CHECK(![input readMotion:&sample]);
    CHECK(b.valueChangedHandler==other&&b.sensorsActive);
    [input updateSystemMotion:(GCMotion *)b];CHECK(b.valueChangedHandler==other);
    CHECK([input.status containsString:@"another reader"]);
    b.valueChangedHandler=nil;b.sensorsActive=NO;b.hasRotationRate=NO;
    [input updateSystemMotion:(GCMotion *)b];CHECK(!b.valueChangedHandler&&!b.sensorsActive);
    CHECK([input.status containsString:@"does not expose"]);
    // Already-active sensors are borrowed, never disabled on detach.
    a.sensorsActive=YES;[input updateSystemMotion:(GCMotion *)a];emit(a);CHECK([input readMotion:&sample]);
    [input updateSystemMotion:nil];CHECK(a.sensorsActive&&!a.valueChangedHandler&&! [input readMotion:&sample]);
    a.sensorsActive=NO;[input updateSystemMotion:(GCMotion *)a];
    old=a.valueChangedHandler;Context c={(__bridge void *)old,(__bridge void *)a};pthread_t thread;
    CHECK(!pthread_create(&thread,NULL,late,&c));
    [input stop];CHECK(!pthread_join(thread,NULL));
    CHECK(![input readMotion:&sample]&&!a.sensorsActive&&!a.valueChangedHandler);
    // Callback retained by the framework can finish after sampler destruction.
    input=nil;old((GCMotion *)a);
    puts("System motion: callback freshness, units, ownership, opt-in and teardown passed");
    printf("System motion checks: %u; synthetic sensors only\n",checks);
} }
