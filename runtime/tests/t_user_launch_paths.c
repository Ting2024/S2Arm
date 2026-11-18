// Independent temporary App/home only. Never reads or writes a real profile.
#include "s2a_launch_ctx.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <mach-o/dyld.h>

static int failures, checks;
#define CHECK(x) do { checks++; if (!(x)) { failures++; fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); } } while (0)
static void file(const char *p, const char *s) { FILE *f = fopen(p, "w"); if (!f) exit(90); fputs(s, f); fclose(f); }
static void directory(const char *p) { if (mkdir(p, 0700)) exit(91); }
static void copy(const char *from, const char *to) {
    FILE *in = fopen(from, "rb"), *out = fopen(to, "wb"); if (!in || !out) exit(92);
    char buf[16384]; size_t n;
    while ((n = fread(buf, 1, sizeof buf, in))) if (fwrite(buf, 1, n, out) != n) exit(93);
    fclose(in); fclose(out); chmod(to, 0700);
}
static const char *gid = "0100000000000001";
static int child(const char *home, const char *user) {
    CHECK(s2a_launch_ctx_container()); CHECK(!s2a_launch_ctx_get());
    CHECK(!s2a_launch_ctx_account_service_v1());
    s2a_launch_user_v1 unsupported = {1, "01", "fixture", NULL};
    CHECK(s2a_launch_ctx_select_user(gid, &unsupported) != NULL);
    CHECK(!s2a_launch_ctx_get() && !getenv("S2A_SESSION_USER"));
    CHECK(s2a_launch_ctx_select_user_paths(gid, "../02") != NULL);
    CHECK(!s2a_launch_ctx_get()); CHECK(!getenv("S2A_DOCS"));
    CHECK(s2a_launch_ctx_select_user_paths("0100000000000002", user) != NULL);
    CHECK(!s2a_launch_ctx_get()); CHECK(!getenv("S2A_RYU_DATA"));
    CHECK(s2a_launch_ctx_select_user_paths(gid, user) == NULL);
    const s2a_launch_ctx *c = s2a_launch_ctx_get(); CHECK(c);
    if (!c) return 1;
    char expected[1024];
    snprintf(expected, sizeof expected, "%s/Documents/games/%s%s", home, gid,
             !strcmp(user, "01") ? "" : "/S2A/users/02/docs");
    CHECK(!strcmp(c->docs, expected)); CHECK(!strcmp(getenv("S2A_DOCS"), expected));
    snprintf(expected, sizeof expected, "%s/Library/Application Support/S2Arm/games/%s/资源包", home, gid);
    CHECK(!strcmp(c->game_data, expected)); CHECK(!strcmp(getenv("S2A_GAME_DATA"), expected));
    CHECK(!strcmp(c->user_id, user)); CHECK(!strcmp(getenv("S2A_RYU_DATA"), c->ryu_data));
    struct stat st; CHECK(!lstat(c->docs, &st) && S_ISDIR(st.st_mode));
    CHECK(!strcmp(s2a_launch_ctx_game_env_dir("/not-this-session"), c->docs));
    s2a_launch_ctx frozen = *c;
    CHECK(s2a_launch_ctx_select_user_paths(gid, "03") != NULL);
    CHECK(s2a_launch_ctx_select(gid) != NULL);
    CHECK(!memcmp(c, &frozen, sizeof frozen));
    // Environment contains only paths: this sub-contract doesn't claim an account binding.
    CHECK(!getenv("S2A_SESSION_USER"));
    printf("user path child: %d checks, %d failures\n", checks, failures);
    return failures != 0;
}
int main(int argc, char **argv) {
    if (argc == 4) return child(argv[2], argv[3]);
    unsetenv("S2A_LAUNCH_CTX"); unsetenv("S2A_DOCS"); unsetenv("S2A_RYU_DATA");
    unsetenv("S2A_GAME_DATA"); unsetenv("S2A_SESSION_USER");
    char temp[] = "/tmp/s2a-user-paths-XXXXXX";
    if (!mkdtemp(temp)) return 90;
    char *root = realpath(temp, NULL); if (!root) return 90;
    char app[1024], home[1024], p[1500], q[1500];
    snprintf(app, sizeof app, "%s/App", root); directory(app);
    snprintf(home, sizeof home, "%s/home", root); directory(home);
    snprintf(p, sizeof p, "%s/Games", app); directory(p);
    snprintf(p, sizeof p, "%s/Games/%s", app, gid); directory(p);
    snprintf(p, sizeof p, "%s/Frameworks", app); directory(p);
    snprintf(p, sizeof p, "%s/Frameworks/S2AImages-%s.dylib", app, gid); file(p, "fixture");
    snprintf(p, sizeof p, "%s/s2a_catalogue.json", app); file(p, "{\"games\":[{\"title_id\":\"0100000000000001\"}]}");
    s2a_launch_ctx a, b; char why[600];
    CHECK(!s2a_launch_ctx_resolve_user_paths(&a, app, home, gid, "01", why, sizeof why));
    CHECK(!s2a_launch_ctx_resolve_user_paths(&b, app, home, gid, "02", why, sizeof why));
    CHECK(!strcmp(a.game_data, b.game_data)); CHECK(strcmp(a.docs, b.docs)); CHECK(strcmp(a.ryu_data, b.ryu_data));
    snprintf(p, sizeof p, "%s/Documents/games/%s/S2A/ryujinx", home, gid); CHECK(!strcmp(a.ryu_data, p));
    snprintf(p, sizeof p, "%s/Documents/games/%s/S2A/users/02/ryujinx", home, gid); CHECK(!strcmp(b.ryu_data, p));
    snprintf(p, sizeof p, "%s/Documents", home); CHECK(access(p, F_OK) != 0); // pure plan
    CHECK(!getenv("S2A_DOCS") && !getenv("S2A_RYU_DATA"));
    const char *bad[] = {NULL, "", "1", "00", "002", "1000000", "../02", "02/03", "2a", " 02"};
    s2a_launch_ctx zero = {0};
    for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
        memset(&b, 0x55, sizeof b);
        CHECK(s2a_launch_ctx_resolve_user_paths(&b, app, home, gid, bad[i], why, sizeof why) == -1);
        CHECK(!memcmp(&b, &zero, sizeof b) && why[0]);
    }
    CHECK(!s2a_launch_ctx_resolve_user_paths(&b, app, home, gid, "999999", why, sizeof why));
    // Internal links and regular-file path components cannot target another profile.
    snprintf(q, sizeof q, "%s/outside", root); directory(q);
    CHECK(!symlink(q, p));
    CHECK(s2a_launch_ctx_resolve_user_paths(&b, app, home, gid, "01", why, sizeof why) == -1);
    CHECK(s2a_launch_ctx_resolve_user_paths(&b, app, home, gid, "02", why, sizeof why) == -1);
    CHECK(!memcmp(&b, &zero, sizeof b)); unlink(p); file(p, "not a directory");
    CHECK(s2a_launch_ctx_resolve_user_paths(&b, app, home, gid, "02", why, sizeof why) == -1); unlink(p);
    snprintf(p, sizeof p, "%s/home-link", root); CHECK(!symlink(home, p));
    CHECK(s2a_launch_ctx_resolve_user_paths(&b, app, p, gid, "02", why, sizeof why) == -1);
    // Deep per-user/state/resource links must be rejected too; user 01 never
    // traverses another user's branch merely to resolve its legacy paths.
    snprintf(p, sizeof p, "%s/Documents", home); directory(p);
    snprintf(p, sizeof p, "%s/Documents/games", home); directory(p);
    snprintf(p, sizeof p, "%s/Documents/games/%s", home, gid); directory(p);
    snprintf(p, sizeof p, "%s/Documents/games/%s/S2A", home, gid); directory(p);
    snprintf(p, sizeof p, "%s/Documents/games/%s/S2A/users", home, gid); directory(p);
    snprintf(p, sizeof p, "%s/Documents/games/%s/S2A/users/02", home, gid); CHECK(!symlink(q, p));
    CHECK(s2a_launch_ctx_resolve_user_paths(&b, app, home, gid, "02", why, sizeof why) == -1);
    CHECK(!s2a_launch_ctx_resolve_user_paths(&a, app, home, gid, "01", why, sizeof why)); unlink(p); directory(p);
    snprintf(p, sizeof p, "%s/Documents/games/%s/S2A/users/02/ryujinx", home, gid); CHECK(!symlink(q, p));
    CHECK(s2a_launch_ctx_resolve_user_paths(&b, app, home, gid, "02", why, sizeof why) == -1); unlink(p);
    snprintf(p, sizeof p, "%s/Library", home); directory(p);
    snprintf(p, sizeof p, "%s/Library/Application Support", home); directory(p);
    snprintf(p, sizeof p, "%s/Library/Application Support/S2Arm", home); directory(p);
    snprintf(p, sizeof p, "%s/Library/Application Support/S2Arm/games", home); directory(p);
    snprintf(p, sizeof p, "%s/Library/Application Support/S2Arm/games/%s", home, gid); directory(p);
    snprintf(p, sizeof p, "%s/Library/Application Support/S2Arm/games/%s/资源包", home, gid); CHECK(!symlink(q, p));
    CHECK(s2a_launch_ctx_resolve_user_paths(&b, app, home, gid, "02", why, sizeof why) == -1);
    CHECK(s2a_launch_ctx_resolve_user_paths(&a, app, home, gid, "01", why, sizeof why) == -1); unlink(p);
    CHECK(!getenv("S2A_DOCS") && !getenv("S2A_RYU_DATA"));
    char self[1024]; uint32_t n = sizeof self;
    CHECK(!_NSGetExecutablePath(self, &n));
    snprintf(p, sizeof p, "%s/test-host", app); copy(self, p);
#ifndef USER_PATH_CHILD_COUNT
#define USER_PATH_CHILD_COUNT 2
#endif
    for (int i = 1; i <= USER_PATH_CHILD_COUNT; i++) {
        // Each process gets its own home. Nothing is merged into any profile.
        snprintf(home, sizeof home, "%s/session%d", root, i); directory(home);
        pid_t pid = fork(); CHECK(pid >= 0);
        if (!pid) {
#ifdef S2A_TEST_LAUNCH_ENV
            char mode[16]; snprintf(mode, sizeof mode, "%d", i - 2); setenv("S2A_TEST_ENV_FAILURE", mode, 1);
#endif
            setenv("HOME", home, 1); execl(p, p, "child", home, i == 1 ? "01" : "02", (char *)NULL); _exit(94); }
        if (pid > 0) { int status; CHECK(waitpid(pid, &status, 0) == pid); CHECK(WIFEXITED(status) && !WEXITSTATUS(status)); }
    }
    // Remove only this mkdtemp tree, never a user-supplied path.
    snprintf(p, sizeof p, "rm -rf '%s'", root); CHECK(system(p) == 0); free(root);
    printf("user paths: %d checks, %d failures\n", checks, failures);
    return failures != 0;
}
