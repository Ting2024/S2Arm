// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#include "s2a_controller_slots.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned checks;
#define CHECK(x) do { checks++; if (!(x)) { fprintf(stderr, "controller slots failed at line %d\n", __LINE__); exit(1); } } while (0)
static void defaults(s2a_controller_selection s[4]) {
    memset(s, 0, 4 * sizeof *s);
    for (int i = 0; i < 4; i++) s[i].backend = S2A_CONTROLLER_AUTO;
}
static void unique(const s2a_controller_assignment out[4]) {
    for (int i = 0; i < 4; i++) for (int j = i + 1; j < 4; j++)
        CHECK(!out[i].physical[0] || strcmp(out[i].physical, out[j].physical));
}
int main(void) {
    s2a_controller_selection s[4]; defaults(s);
    s2a_controller_assignment out[4], saved[4];
    s2a_controller_candidate devices[] = {
        {S2A_CONTROLLER_SYSTEM, "gc:one", "one"},
        {S2A_CONTROLLER_NSPRO, "hid:one", "one"},
        {S2A_CONTROLLER_SYSTEM, "gc:two", "two"},
        {S2A_CONTROLLER_SYSTEM, "gc:three", "three"},
        {S2A_CONTROLLER_NSPRO, "hid:four", "four"}};
    CHECK(s2a_controller_assign(s, NULL, 0, NULL, out));
    for (int i = 0; i < 4; i++) CHECK(out[i].backend == S2A_CONTROLLER_DISABLED && !out[i].physical[0]);
    CHECK(s2a_controller_assign(s, devices, 5, NULL, out)); unique(out);
    CHECK(!strcmp(out[0].physical, "four") && !strcmp(out[1].device, "gc:one"));
    for (int i = 0; i < 4; i++) CHECK(out[i].physical[0]);
    // Enumeration order is not player identity, including identical models.
    memcpy(saved, out, sizeof out);
    s2a_controller_candidate reverse[5];
    for (int i = 0; i < 5; i++) reverse[i] = devices[4 - i];
    CHECK(s2a_controller_assign(s, reverse, 5, NULL, out)); CHECK(!memcmp(out, saved, sizeof out));
    CHECK(s2a_controller_assign(s, devices, 4, saved, out)); unique(out);
    CHECK(!out[0].physical[0]);
    for (int i = 1; i < 4; i++) CHECK(!strcmp(saved[i].physical, out[i].physical));
    CHECK(s2a_controller_assign(s, devices, 5, out, out)); CHECK(!memcmp(out, saved, sizeof out));
    // Explicit fourth-player reservation takes priority over automatic first.
    strcpy(s[3].device, "hid:one"); s[3].backend = S2A_CONTROLLER_NSPRO;
    CHECK(s2a_controller_assign(s, devices, 5, saved, out)); unique(out);
    CHECK(!strcmp(out[3].device, "hid:one"));
    // System/HID aliases cannot control two players.
    strcpy(s[0].device, "gc:one"); s[0].backend = S2A_CONTROLLER_SYSTEM;
    CHECK(s2a_controller_assign(s, devices, 5, NULL, out)); unique(out);
    CHECK(!out[0].physical[0] && !out[3].physical[0]);
    for (int i = 0; i < 4; i++) CHECK(strcmp(out[i].physical, "one"));
    // Missing explicit device never falls back to any other pad.
    defaults(s); strcpy(s[1].device, "disconnected");
    CHECK(s2a_controller_assign(s, devices, 5, NULL, out)); CHECK(!out[1].physical[0]);
    // A legacy model ID may match multiple identical physical controllers.
    s2a_controller_candidate twins[] = {{0,"gc:model","first"}, {0,"gc:model","second"}};
    defaults(s); strcpy(s[2].device, "gc:model");
    CHECK(s2a_controller_assign(s, twins, 2, NULL, out));
    for (int i = 0; i < 4; i++) CHECK(!out[i].physical[0]);
    defaults(s); CHECK(s2a_controller_assign(s, twins, 2, NULL, out)); unique(out);
    CHECK(out[0].physical[0] && out[1].physical[0]);
    s[0].backend = S2A_CONTROLLER_DISABLED;
    CHECK(s2a_controller_assign(s, twins, 2, NULL, out)); CHECK(!out[0].physical[0]);
    // All invalid inputs are transactional, including nonterminated identifiers.
    memcpy(saved, out, sizeof out);
    s[0].backend = 99;
    CHECK(!s2a_controller_assign(s, devices, 5, NULL, out)); CHECK(!memcmp(out, saved, sizeof out));
    defaults(s); memset(s[2].device, 'x', sizeof s[2].device);
    CHECK(!s2a_controller_assign(s, devices, 5, NULL, out)); CHECK(!memcmp(out, saved, sizeof out));
    defaults(s); CHECK(!s2a_controller_assign(s, devices, 65, NULL, out));
    CHECK(!s2a_controller_assign(s, NULL, 1, NULL, out)); CHECK(!memcmp(out, saved, sizeof out));
    // Exhaustively exercise driver choices and explicit/automatic combinations.
    for (unsigned mask = 0; mask < 4096; mask++) {
        defaults(s);
        for (int i = 0; i < 4; i++) {
            s[i].backend = (mask >> (i * 3)) & 3;
            if ((mask >> (i * 3)) & 4) strcpy(s[i].device, i % 2 ? "hid:one" : "gc:one");
        }
        CHECK(s2a_controller_assign(s, devices, 5, NULL, out)); unique(out);
        for (int i = 0; i < 4; i++) if (out[i].physical[0]) {
            CHECK(s[i].backend == S2A_CONTROLLER_AUTO || s[i].backend == out[i].backend);
            CHECK(!s[i].device[0] || !strcmp(s[i].device, out[i].device));
        }
    }
    printf("controller slots: %u checks passed\n", checks);
    return 0;
}
