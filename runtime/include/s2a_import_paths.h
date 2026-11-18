// Shared resource roots must not be derived from per-user writable docs.
#ifndef S2A_IMPORT_PATHS_H
#define S2A_IMPORT_PATHS_H
#include "s2a_launch_ctx.h"
// Gate: 1 checks out, 0 intentionally skips, -1 invalid (must fail closed).
int s2a_import_docs_pick(const s2a_launch_ctx *ctx, int game_data_env,
                         const char *process_docs, char *out, size_t size);
// Explicit apply-only: 1 valid, -1 invalid. Legacy uses ctx.docs unchanged;
// containers always use the shared resource root, even with isolated user docs.
int s2a_import_apply_docs(const s2a_launch_ctx *ctx, char *out, size_t size);
#endif
