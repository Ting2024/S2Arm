// Reuse the original lifetime lock, not another PID registry.
#include "mng/user_lock.h"
int s2a_mng_config_lock(const char *root) {
    return mng_lock_file(root, ".input-owner.lock", LOCK_EX | LOCK_NB);
}
