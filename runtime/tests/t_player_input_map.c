// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#include "s2a_player_input_map.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned checks;
#define CHECK(x) do { checks++; if (!(x)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x); exit(1); } } while(0)
static s2a_input_config empty(void) {
    s2a_input_config c = {0};
    for (int i=0;i<24;i++) c.gamepad[i]=-1;
    for (int i=0;i<4;i++) c.axes[i].source=-1;
    return c;
}
static int neutral(s2a_player_input_slot s) { return !s.buttons && !s.lx && !s.ly && !s.rx && !s.ry; }
int main(void) {
    s2a_input_config c = empty();
    s2a_player_raw_input raw = {0}; s2a_player_input_slot out;
    CHECK(s2a_player_map(&c,&raw,&out) && neutral(out));
    // All source-to-target combinations, including the eight digital directions.
    for (int target=0;target<24;target++) for (int source=0;source<16;source++) {
        c=empty(); c.gamepad[target]=source;
        for (int button=0;button<16;button++) {
            raw=(s2a_player_raw_input){.buttons=1u<<button};
            CHECK(s2a_player_map(&c,&raw,&out));
            s2a_player_input_slot expected={0};
            if (source==button) {
                if (target<16) expected.buttons=1u<<target;
                else {
                    int d=target-16, v=(d%4==0||d%4==3)?-32767:32767;
                    switch ((d<4?0:2)+d%2) {
                        case 0:expected.lx=v;break; case 1:expected.ly=v;break;
                        case 2:expected.rx=v;break; case 3:expected.ry=v;break;
                    }
                }
            }
            CHECK(!memcmp(&expected,&out,sizeof out));
        }
    }
    for (int target=0;target<4;target++) for (int source=0;source<4;source++) for (int invert=0;invert<2;invert++) {
        c=empty(); c.axes[target]=(s2a_input_axis){source,invert}; c.deadzone=.25;
        const float cases[]={-INFINITY,NAN,INFINITY,-2,-1,-.5f,-.25f,0,.25f,.5f,1,2};
        for (unsigned i=0;i<sizeof cases/sizeof cases[0];i++) {
            raw=(s2a_player_raw_input){.axes={.75f,.75f,.75f,.75f}}; raw.axes[source]=cases[i];
            CHECK(s2a_player_map(&c,&raw,&out));
            float v=cases[i]; if (!isfinite(v)) v=0;
            v=fminf(1,fmaxf(-1,v));
            int32_t expected=fabsf(v)>.25f?(int32_t)(v*(invert?-32767:32767)):0;
            int32_t axes[]={out.lx,out.ly,out.rx,out.ry};
            for (int j=0;j<4;j++) CHECK(axes[j]==(j==target?expected:0));
        }
    }
    c=empty(); c.gamepad[16]=0;c.gamepad[18]=1;c.axes[0].source=0;
    raw=(s2a_player_raw_input){.buttons=3,.axes={.5f,0,0,0}};
    CHECK(s2a_player_map(&c,&raw,&out)&&out.lx==16383); // digital opposites cancel before analog
    raw.buttons=2; CHECK(s2a_player_map(&c,&raw,&out)&&out.lx==32767);
    raw.buttons=1; raw.axes[0]=-.5f; CHECK(s2a_player_map(&c,&raw,&out)&&out.lx==-32767);
    c=empty(); for (int i=0;i<16;i++) c.gamepad[i]=i;
    raw=(s2a_player_raw_input){.buttons=0xffff0000};
    CHECK(s2a_player_map(&c,&raw,&out)&&neutral(out));
    // Validation does not read unrelated keyboard/mouse/controller fields.
    c.keyboard[0].code=999;c.mouse[0]=999;c.players[0].backend=999;
    CHECK(s2a_player_mapping_valid(&c));
    for (int kind=0;kind<11;kind++) {
        c=empty();
        switch(kind) {
            case 0:c.deadzone=NAN;break; case 1:c.deadzone=INFINITY;break;
            case 2:c.deadzone=-.1;break;case 3:c.deadzone=1.1;break;
            case 4:c.gamepad[23]=-2;break;case 5:c.gamepad[23]=16;break;
            case 6:c.axes[3].source=-2;break;case 7:c.axes[3].source=4;break;
            case 10:c.deadzone=1;break;
            case 8:c.axes[3].invert=-1;break;case 9:c.axes[3].invert=2;break;
        }
        memset(&out,0xff,sizeof out);
        CHECK(!s2a_player_mapping_valid(&c));CHECK(!s2a_player_map(&c,&raw,&out)&&neutral(out));
    }
    c=empty();CHECK(!s2a_player_map(NULL,&raw,&out)&&neutral(out));
    CHECK(!s2a_player_map(&c,NULL,&out)&&neutral(out)); CHECK(!s2a_player_map(&c,&raw,NULL));
    printf("✓ t_player_input_map: %u checks\n",checks);
}
