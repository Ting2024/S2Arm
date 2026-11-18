// No game or archive IO: same production selector used by the iOS import gate.
#include "s2a_import_paths.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <assert.h>
uint64_t now_ns(void) { return 0; }
int s2a_import_docs_pick(const s2a_launch_ctx *, int, const char *, char *, size_t);
int main(void) {
    s2a_launch_ctx c = { .source = S2A_LCTX_CONTAINER }; char out[1024];
    strcpy(c.game_data, "/sandbox/Documents/games/0100000000010000/资源包");
    strcpy(c.docs, "/sandbox/Documents/games/0100000000010000/S2A/users/02/docs");
    assert(s2a_import_docs_pick(&c, 1, "/sandbox/Documents", out, sizeof out) == 1);
    assert(!strcmp(out, "/sandbox/Documents/games/0100000000010000"));
    assert(strcmp(out, c.docs));
    assert(s2a_import_apply_docs(&c, out, sizeof out) == 1);
    assert(!strcmp(out, "/sandbox/Documents/games/0100000000010000"));
    assert(s2a_import_apply_docs(&c, out, 4) == -1 && !out[0]);
    assert(s2a_import_apply_docs(NULL, out, sizeof out) == -1 && !out[0]);
    strcpy(c.docs, "/sandbox/Documents/games/0100000000010000");
    assert(s2a_import_docs_pick(&c, 1, "/sandbox/Documents", out, sizeof out) == 1 && !strcmp(out,c.docs));
    assert(s2a_import_docs_pick(&c, 1, "/sandbox/Documents", out, 4) == -1 && !out[0]);
    assert(s2a_import_docs_pick(&c, 1, "/sandbox/Documents", NULL, 0) == -1);
    const char *bad[] = {"", "relative/资源包", "/sandbox/wrong", "/资源包", "/sandbox/../other/资源包", "/sandbox/./资源包", "/sandbox//资源包"};
    for (unsigned i=0;i<sizeof bad/sizeof bad[0];i++) {
        strcpy(c.game_data,bad[i]);
        assert(s2a_import_docs_pick(&c,1,"/fallback",out,sizeof out)==-1 && !out[0]);
        assert(s2a_import_apply_docs(&c,out,sizeof out)==-1 && !out[0]);
    }
    memset(c.game_data,'x',sizeof c.game_data);
    assert(s2a_import_docs_pick(&c,1,"/fallback",out,sizeof out)==-1);
    c.source=S2A_LCTX_COMPAT;
    strcpy(c.docs, "/legacy/docs");
    assert(s2a_import_apply_docs(&c,out,sizeof out)==1 && !strcmp(out,c.docs));
    assert(s2a_import_apply_docs(&c,out,3)==-1 && !out[0]);
    assert(s2a_import_docs_pick(&c,1,"/legacy",out,sizeof out)==0);
    assert(s2a_import_docs_pick(&c,0,"/legacy",out,sizeof out)==1 && !strcmp(out,"/legacy"));
    assert(s2a_import_docs_pick(&c,0,"/legacy",out,3)==-1 && !out[0]);
    c.source=S2A_LCTX_FILE;
    assert(s2a_import_docs_pick(&c,1,"/legacy",out,sizeof out)==0);
    puts("User import routing: all checks passed; no file IO or game launch.");
}
