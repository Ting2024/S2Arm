// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#pragma once
#include "s2a_player_input.h"
#include <pthread.h>
// Private host transport, not an exported runtime capability. Main-thread device
// sampler publishes; HID thread reads copied POD only. Initialize before threads
// start and destroy only after they join. No borrowed pointers or heap allocation.
typedef struct {
    pthread_mutex_t mutex;
    uint64_t generation, timestamp_us;
    int enabled, valid;
    s2a_player_input_frame frame;
} s2a_player_input_buffer;
int s2a_player_buffer_init(s2a_player_input_buffer *buffer);
void s2a_player_buffer_destroy(s2a_player_input_buffer *buffer);
// Beginning or stopping invalidates all old publisher tokens. Token 0 is invalid.
uint64_t s2a_player_buffer_begin(s2a_player_input_buffer *buffer);
void s2a_player_buffer_stop(s2a_player_input_buffer *buffer);
int s2a_player_buffer_publish(s2a_player_input_buffer *buffer, uint64_t token,
                             const s2a_player_input_frame *frame, uint64_t now_us);
// Output is always cleared on failure when capacity is sufficient. Read never
// falls back to primary input. Freshness uses the caller's monotonic microseconds.
int s2a_player_buffer_read(s2a_player_input_buffer *buffer, s2a_player_input_frame *out,
                          uint32_t capacity, uint64_t now_us);
