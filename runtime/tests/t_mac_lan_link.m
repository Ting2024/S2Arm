// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Links the real provider + Mac permission adapter against the host's weak
// fallback. Never starts Bonjour: stop invalidates each queued start first.
#import <Foundation/Foundation.h>
#include "s2a_lan_discovery.h"
#include <assert.h>
#include <errno.h>
#include <stdio.h>

// Same weak fallback as host_main.c. A missing build input must fail, not pass
// by directly including the provider into this translation unit.
__attribute__((weak)) const s2a_lan_discovery_v1 *s2a_ldn_lan_provider(void) { return NULL; }
static unsigned selection_calls;
void S2A_LdnSetServer(const char *ip) { (void)ip; selection_calls++; }
void s2a_lan_permission_then(int dev_mode, void (^go)(void));
int main(void) {
    @autoreleasepool {
        const s2a_lan_discovery_v1 *p = s2a_ldn_lan_provider();
        assert(p && p->abi == 1 && p->start && p->set_hosting && p->stop);
        assert(p->start(42, 0) == -EINVAL);
        assert(p->start(42, 41234) == 0);
        assert(p->start(42, 41234) == 0);
        assert(p->start(43, 41234) == -EBUSY);
        assert(p->start(42, 41235) == -EBUSY);
        p->set_hosting(1); p->stop(); p->stop();
        assert(p->start(43, 41235) == 0);
        p->stop();
        // Drain queued starts/hosting/cleanup: retired sessions must stay dead.
        __block BOOL drained = NO;
        dispatch_async(dispatch_get_main_queue(), ^{ drained = YES; });
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
        while (!drained && deadline.timeIntervalSinceNow > 0)
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
        assert(drained && selection_calls == 0);
        __block unsigned continued = 0;
        s2a_lan_permission_then(0, ^{ continued++; });
        s2a_lan_permission_then(1, ^{ continued++; });
        assert(continued == 2);
        puts("✓ t_mac_lan_link：强符号绑定、ABI、0 端口拒收、幂等、忙态、stop/restart、退休回调与权限续传全部通过（无网络访问）");
    }
}
