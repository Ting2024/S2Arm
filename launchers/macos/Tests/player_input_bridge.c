// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Synthetic shared-library bridge for the managed HID test, not a game host.
#include "s2a_player_input_buffer.h"
#include "s2a_player_input_map.h"
static s2a_player_input_buffer buffer;
static uint64_t token;
static s2a_input_config config;
int s2a_test_player_begin(void) {
    if (!s2a_player_buffer_init(&buffer)) return 0;
    // Nonidentity raw mapping; managed test expects the mapped game controls.
    for (unsigned i=0;i<24;i++) config.gamepad[i]=-1;
    for (unsigned i=0;i<4;i++) { config.gamepad[i]=3-(int)i; config.axes[i].source=-1; }
    config.axes[0]=(s2a_input_axis){3,0};
    config.axes[3]=(s2a_input_axis){0,1};
    token = s2a_player_buffer_begin(&buffer);
    return 1;
}
int s2a_test_player_publish(uint32_t mask, uint32_t active) {
    s2a_player_input_frame frame = {.version=1,.bytes=sizeof frame,.connected_mask=mask,.active=active};
    for (unsigned i=0;i<4;i++) {
        int axis=(int)(i+1)*1000;
        // Quarter-unit margin avoids binary floating-point truncation at an
        // exact integer boundary; mapper itself still truncates like Mac input.
        float value=(axis+.25f)/32767;
        s2a_player_raw_input raw={.buttons=1u<<(3-i),.axes={value,0,0,value}};
        if (!s2a_player_map(&config,&raw,&frame.slots[i])) return 0;
    }
    return s2a_player_buffer_publish(&buffer,token,&frame,100);
}
int s2a_test_player_read(s2a_player_input_frame *out, uint32_t capacity) {
    return s2a_player_buffer_read(&buffer,out,capacity,101);
}
void s2a_test_player_stop(void) { s2a_player_buffer_stop(&buffer); }
void s2a_test_player_end(void) { s2a_player_buffer_stop(&buffer); s2a_player_buffer_destroy(&buffer); }
