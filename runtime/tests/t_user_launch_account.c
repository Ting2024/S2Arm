// Reuse only temporary fixture construction, no real game or user data.
#define USER_PATH_CHILD_COUNT 29
#define main path_fixture_main
#include "t_user_launch_paths.c"
#undef main
#include <errno.h>

// Must never be invoked: NativeAOT initialization must follow environment commit.
int S2A_LauncherAccount_v1(void) { abort(); }
static int fail_at, writes, fail_restore;
int s2a_test_launch_setenv(const char *key, const char *value, int overwrite) {
    writes++;
    if (writes == fail_at) {
        setenv(key, value, overwrite); // strongest failure case: changed then failed
        errno = ENOMEM; return -1;
    }
    if (fail_restore && writes > fail_at) { errno = ENOMEM; return -1; }
    return setenv(key, value, overwrite);
}
int s2a_test_launch_unsetenv(const char *key) {
    if (fail_restore) { errno = ENOMEM; return -1; }
    return unsetenv(key);
}
static const char *keys[] = {"S2A_GAME_DATA", "S2A_DOCS", "S2A_RYU_DATA", "S2A_LAUNCH_GAME_ID", "S2A_SESSION_USER",
    "S2A_SAVE_DIR", "S2A_COLD_START", "S2A_PSO_HARVEST",
    "DM_PSO_RECORD", "DM_NVN_SHDUMP", "DM_NVN_CBDUMP", "NXGAL_PSO_ARCHIVE_OUT", "NXGAL_PSO_SCRIPT",
    "NXGAL_SHADER_CACHE_DIR", "NXGAL_PSO_DEV_DIR", "S2A_MACRO_DUMP", "S2A_SHCOLLECT", "GAL_AIR_CACHE",
    "GAL_PSO_CACHE", "S2A_SCHED_DIR", "DM_PSO_USER", "TMPDIR", "S2A_WIDEN_FLAT_CACHE"};
enum { BLOCKED_START = 5, CACHE_START = 13, ENV_COUNT = sizeof keys / sizeof keys[0],
       POISON_MODE = ENV_COUNT + 1, LINK_MODE = ENV_COUNT + 2 };
static int account_child(const char *home, const char *id) {
    CHECK(s2a_launch_ctx_account_service_v1()); CHECK(s2a_launch_ctx_container()); CHECK(!s2a_launch_ctx_get());
    const char *uid = !strcmp(id, "01") ? NULL : "1234567890abcdef1234567890abcdef";
    char name[] = "test\\\"名";
    s2a_launch_user_v1 user = {1, id, name, uid};
    s2a_launch_user_v1 bad = user; bad.version = 2;
    CHECK(s2a_launch_ctx_select_user(gid, &bad));
    const char *bad_names[] = {"", " a", "a ", "\xc0\xaf", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\xc2\x80", "\xe3\x80\x80x", "x\xe2\x80\xaf", "a\n"};
    for (size_t i = 0; i < sizeof bad_names / sizeof bad_names[0]; i++) {
        bad = user; bad.name = bad_names[i]; CHECK(s2a_launch_ctx_select_user(gid, &bad));
    }
    bad = user; bad.account_uid = uid ? NULL : "1234567890abcdef1234567890abcdef";
    CHECK(s2a_launch_ctx_select_user(gid, &bad));
    for (int i = BLOCKED_START; i < CACHE_START; i++) {
        const char *key = keys[i];
        setenv(key, "1", 1); CHECK(s2a_launch_ctx_select_user(gid, &user)); unsetenv(key);
    }
    CHECK(!s2a_launch_ctx_get()); CHECK(writes == 0);
    // Every third entry is absent, empty, or populated. Failed admission must
    // restore all three states byte-for-byte, including the failed write itself.
    for (int i = 0; i < ENV_COUNT; i++) {
        if (!(i % 3)) unsetenv(keys[i]); else setenv(keys[i], i % 3 == 1 || (i >= BLOCKED_START && i < CACHE_START) ? "" : "fixture-old", 1);
    }
    int mode = atoi(getenv("S2A_TEST_ENV_FAILURE"));
    fail_at = mode > 0 ? mode : 0;
    if (mode == POISON_MODE) { fail_at = 4; fail_restore = 1; }
    if (mode >= LINK_MODE) {
        // Check a cache leaf link before any environment mutation.
        char p[1500]; snprintf(p, sizeof p, "%s/Documents", home); directory(p);
        snprintf(p, sizeof p, "%s/Documents/games", home); directory(p);
        snprintf(p, sizeof p, "%s/Documents/games/%s", home, gid); directory(p);
        snprintf(p, sizeof p, "%s/Documents/games/%s/S2A", home, gid); directory(p);
        snprintf(p, sizeof p, "%s/Documents/games/%s/S2A/users", home, gid); directory(p);
        snprintf(p, sizeof p, "%s/Documents/games/%s/S2A/users/02", home, gid); directory(p);
        snprintf(p, sizeof p, "%s/Documents/games/%s/S2A/users/02/cache", home, gid); directory(p);
        snprintf(p, sizeof p, "%s/Documents/games/%s/S2A/users/02/cache/direct", home, gid); directory(p);
        snprintf(p, sizeof p, "%s/Documents/games/%s/S2A/users/02/cache/direct/%s", home, gid,
                 mode == LINK_MODE ? "pso_user.tsv" : "widen_flat3.tsv");
        char target[1500]; snprintf(target, sizeof target, "%s/independent-cache", home);
        if (mode == LINK_MODE + 2) { file(target, "untouched"); CHECK(!link(target, p)); }
        else CHECK(!symlink(home, p)); CHECK(s2a_launch_ctx_select_user(gid, &user)); CHECK(!writes); CHECK(!s2a_launch_ctx_get());
        unlink(p); fail_at = 0;
    } else if (mode > 0) {
        CHECK(s2a_launch_ctx_select_user(gid, &user)); CHECK(!s2a_launch_ctx_get());
        if (mode == POISON_MODE) {
            fail_restore = 0; fail_at = 0;
            CHECK(s2a_launch_ctx_select_user(gid, &user)); CHECK(s2a_launch_ctx_select(gid));
            CHECK(s2a_launch_ctx_select_user_paths(gid, id)); CHECK(!s2a_launch_ctx_get());
            CHECK(s2a_launch_ctx_begin());
            printf("poisoned admission: %d checks, %d failures\n", checks, failures);
            return failures != 0;
        }
        for (int i = 0; i < ENV_COUNT; i++) {
            const char *v = getenv(keys[i]);
            CHECK(!(i % 3) ? !v : v && !strcmp(v, i % 3 == 1 || (i >= BLOCKED_START && i < CACHE_START) ? "" : "fixture-old"));
        }
        fail_at = 0;
    }
    CHECK(!s2a_launch_ctx_select_user(gid, &user));
    const s2a_launch_ctx *c = s2a_launch_ctx_get(); CHECK(c);
    if (!c) return 1;
    CHECK(!strcmp(c->user_id, id)); CHECK(c->session_user[0]);
    CHECK(!strcmp(c->session_user, getenv("S2A_SESSION_USER")));
    CHECK(strstr(c->session_user, "test\\\\\\\"名"));
    CHECK(strstr(c->session_user, c->ryu_data));
    for (int i = BLOCKED_START; i < CACHE_START; i++) CHECK(getenv(keys[i]) && !*getenv(keys[i]));
    CHECK(strstr(c->session_user, uid ? uid : "\"accountUid\":null"));
    if (uid) {
        char root[1500]; snprintf(root, sizeof root, "%s/Documents/games/%s/S2A/users/02/", home, gid);
        for (int i = CACHE_START; i < ENV_COUNT; i++) CHECK(getenv(keys[i]) && !strncmp(getenv(keys[i]), root, strlen(root)));
        struct stat st; CHECK(!stat(getenv("TMPDIR"), &st) && S_ISDIR(st.st_mode));
    } else {
        for (int i = CACHE_START; i < ENV_COUNT; i++) {
            const char *v = getenv(keys[i]); CHECK(!(i % 3) ? !v : v && !strcmp(v, i % 3 == 1 || (i >= BLOCKED_START && i < CACHE_START) ? "" : "fixture-old"));
        }
    }
    s2a_launch_ctx frozen = *c; name[0] = 'X';
    CHECK(s2a_launch_ctx_select_user(gid, &user)); CHECK(s2a_launch_ctx_select(gid));
    CHECK(!memcmp(&frozen, c, sizeof frozen));
    printf("account admission: %d checks, %d failures\n", checks, failures);
    return failures != 0;
}
int main(int argc, char **argv) {
    if (argc == 4) return account_child(argv[2], argv[3]);
    return path_fixture_main(argc, argv);
}
