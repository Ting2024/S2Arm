// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#include "s2a_player_input_buffer.h"
#include <string.h>
#define S2A_PLAYER_FRESH_US 250000u
int s2a_player_buffer_init(s2a_player_input_buffer *b) {
    if (!b) return 0;
    memset(b, 0, sizeof *b);
    return pthread_mutex_init(&b->mutex, NULL) == 0;
}
void s2a_player_buffer_destroy(s2a_player_input_buffer *b) { pthread_mutex_destroy(&b->mutex); }
static void invalidate(s2a_player_input_buffer *b) {
    b->generation++;
    if (!b->generation) b->generation++; // zero is never an owned publisher
    b->valid = 0; b->timestamp_us = 0;
    memset(&b->frame, 0, sizeof b->frame);
}
uint64_t s2a_player_buffer_begin(s2a_player_input_buffer *b) {
    pthread_mutex_lock(&b->mutex);
    invalidate(b); b->enabled = 1;
    uint64_t token = b->generation;
    pthread_mutex_unlock(&b->mutex);
    return token;
}
void s2a_player_buffer_stop(s2a_player_input_buffer *b) {
    pthread_mutex_lock(&b->mutex);
    invalidate(b); b->enabled = 0;
    pthread_mutex_unlock(&b->mutex);
}
int s2a_player_buffer_publish(s2a_player_input_buffer *b, uint64_t token,
                             const s2a_player_input_frame *frame, uint64_t now_us) {
    pthread_mutex_lock(&b->mutex);
    int owned = b->enabled && token && token == b->generation;
    int valid = owned && frame && frame->version == S2A_PLAYER_INPUT_VERSION &&
        frame->bytes == sizeof *frame && !(frame->connected_mask & ~15u) && frame->active <= 1 && now_us;
    if (owned) {
        b->valid = valid;
        if (valid) { b->frame = *frame; b->timestamp_us = now_us; }
        else { memset(&b->frame, 0, sizeof b->frame); b->timestamp_us = 0; }
    }
    // A stale callback must not publish OR clear the new owner's sample.
    pthread_mutex_unlock(&b->mutex);
    return valid;
}
int s2a_player_buffer_read(s2a_player_input_buffer *b, s2a_player_input_frame *out,
                          uint32_t capacity, uint64_t now_us) {
    if (!out || capacity < sizeof *out) return 0;
    memset(out, 0, sizeof *out);
    pthread_mutex_lock(&b->mutex);
    int valid = b->enabled && b->valid && now_us >= b->timestamp_us && now_us - b->timestamp_us <= S2A_PLAYER_FRESH_US;
    if (valid) *out = b->frame;
    pthread_mutex_unlock(&b->mutex);
    return valid;
}
