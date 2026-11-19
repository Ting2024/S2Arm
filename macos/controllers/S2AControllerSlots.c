// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#include "include/s2a_controller_slots.h"
#include <string.h>

static int valid_string(const char *s) { return memchr(s, 0, S2A_CONTROLLER_ID_BYTES) != NULL; }
static int eligible(const s2a_controller_selection *s, const s2a_controller_candidate *d) {
    return s->backend != S2A_CONTROLLER_DISABLED &&
        (s->backend == S2A_CONTROLLER_AUTO || s->backend == d->backend) &&
        (!s->device[0] || !strcmp(s->device, d->device));
}
static void assign(s2a_controller_assignment *a, const s2a_controller_candidate *d) {
    a->backend = d->backend;
    memcpy(a->device, d->device, sizeof a->device);
    memcpy(a->physical, d->physical, sizeof a->physical);
}
static int preferred(const s2a_controller_candidate *a, const s2a_controller_candidate *b) {
    int order = strcmp(a->physical, b->physical);
    if (order) return order < 0;
    if (a->backend != b->backend) return a->backend == S2A_CONTROLLER_SYSTEM;
    return strcmp(a->device, b->device) < 0;
}
static int used(const char *physical, const s2a_controller_assignment *plan) {
    for (int s = 0; s < S2A_CONTROLLER_SLOTS; s++)
        if (plan[s].physical[0] && !strcmp(physical, plan[s].physical)) return 1;
    return 0;
}
int s2a_controller_assign(const s2a_controller_selection slots[S2A_CONTROLLER_SLOTS],
                          const s2a_controller_candidate *devices, size_t count,
                          const s2a_controller_assignment previous[S2A_CONTROLLER_SLOTS],
                          s2a_controller_assignment out[S2A_CONTROLLER_SLOTS]) {
    if (!slots || !out || (count && !devices) || count > S2A_CONTROLLER_MAX_DEVICES) return 0;
    for (int s = 0; s < S2A_CONTROLLER_SLOTS; s++) {
        if (slots[s].backend < 0 || slots[s].backend > S2A_CONTROLLER_AUTO || !valid_string(slots[s].device)) return 0;
        if (previous && (!valid_string(previous[s].device) || !valid_string(previous[s].physical))) return 0;
    }
    for (size_t d = 0; d < count; d++) {
        if ((devices[d].backend != S2A_CONTROLLER_SYSTEM && devices[d].backend != S2A_CONTROLLER_NSPRO) ||
            !valid_string(devices[d].device) || !valid_string(devices[d].physical) ||
            !devices[d].device[0] || !devices[d].physical[0]) return 0;
    }
    s2a_controller_assignment plan[S2A_CONTROLLER_SLOTS] = {0};
    int explicit[S2A_CONTROLLER_SLOTS] = {-1, -1, -1, -1};
    unsigned reserved[S2A_CONTROLLER_MAX_DEVICES] = {0};
    for (int s = 0; s < S2A_CONTROLLER_SLOTS; s++) {
        plan[s].backend = S2A_CONTROLLER_DISABLED;
        if (!slots[s].device[0] || slots[s].backend == S2A_CONTROLLER_DISABLED) continue;
        int ambiguous = 0;
        for (size_t d = 0; d < count; d++) {
            if (!eligible(&slots[s], &devices[d])) continue;
            // Even ambiguous explicit claims reserve all their candidates:
            // none is silently handed to an automatic player instead.
            for (size_t j = 0; j < count; j++)
                if (!strcmp(devices[j].physical, devices[d].physical)) reserved[j] |= 1u << s;
            if (explicit[s] >= 0 && strcmp(devices[explicit[s]].physical, devices[d].physical)) ambiguous = 1;
            if (explicit[s] < 0 || preferred(&devices[d], &devices[explicit[s]])) explicit[s] = (int)d;
        }
        if (ambiguous) explicit[s] = -1;
    }
    for (int s = 0; s < S2A_CONTROLLER_SLOTS; s++) {
        int d = explicit[s];
        if (d >= 0 && reserved[d] == (1u << s)) assign(&plan[s], &devices[d]);
    }
    // Keep all surviving automatic assignments before filling holes. Unplugging
    // 1P must not move 2P's still-connected controller into 1P.
    if (previous) for (int s = 0; s < S2A_CONTROLLER_SLOTS; s++) {
        if (slots[s].device[0] || !previous[s].physical[0]) continue;
        for (size_t d = 0; d < count; d++) {
            if (!reserved[d] && eligible(&slots[s], &devices[d]) &&
                !strcmp(previous[s].physical, devices[d].physical) &&
                previous[s].backend == devices[d].backend && !strcmp(previous[s].device, devices[d].device) &&
                !used(devices[d].physical, plan)) { assign(&plan[s], &devices[d]); break; }
        }
    }
    for (int s = 0; s < S2A_CONTROLLER_SLOTS; s++) {
        if (slots[s].device[0] || plan[s].physical[0]) continue;
        int best = -1;
        for (size_t d = 0; d < count; d++)
            if (!reserved[d] && eligible(&slots[s], &devices[d]) && !used(devices[d].physical, plan) &&
                (best < 0 || preferred(&devices[d], &devices[best]))) best = (int)d;
        if (best >= 0) assign(&plan[s], &devices[best]);
    }
    memcpy(out, plan, sizeof plan);
    return 1;
}
