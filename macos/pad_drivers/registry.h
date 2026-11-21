// SPDX-License-Identifier: Apache-2.0
#pragma once
#include <string.h>
#include <strings.h>
#include "betop_ns.h"

typedef enum { S2A_DRIVER_GENERIC_HID, S2A_DRIVER_SWITCH_PRO } s2a_driver_protocol;
typedef struct {
    const char *id;
    s2a_driver_protocol protocol;
    int (*matches)(const char *manufacturer, const char *product, int vid, int pid);
} s2a_driver;

static const s2a_driver s2a_drivers[] = {
    {"betop-ns", S2A_DRIVER_SWITCH_PRO, s2a_hidg_betop_ns},
};
#define S2A_DRIVER_COUNT (sizeof(s2a_drivers) / sizeof(s2a_drivers[0]))

// An explicit but unknown ID can come from a newer launcher. Keep the original host path.
static inline const s2a_driver *s2a_driver_resolve(const char *choice, const char *maker, const char *name, int vid, int pid) {
    for (size_t i = 0; i < S2A_DRIVER_COUNT; ++i) {
        const s2a_driver *driver = &s2a_drivers[i];
        if (choice && strcmp(choice, "auto") != 0) {
            if (!strcmp(choice, driver->id)) return driver;
        } else if (driver->matches(maker, name, vid, pid)) return driver;
    }
    return NULL;
}
