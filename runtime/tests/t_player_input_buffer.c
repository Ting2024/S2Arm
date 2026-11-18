// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#include "s2a_player_input_buffer.h"
#include <stddef.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned checks;
#define CHECK(x) do { checks++; if (!(x)) { fprintf(stderr,"player buffer failed at line %d\n",__LINE__); exit(1); } } while (0)
static s2a_player_input_frame frame(unsigned n) {
    s2a_player_input_frame f = {.version=1, .bytes=96, .connected_mask=15, .active=1};
    for (int i=0;i<4;i++) f.slots[i]=(s2a_player_input_slot){1u<<i,(int)n+i,-(int)n-i,(int)n+i+10,-(int)n-i-10};
    return f;
}
typedef struct { s2a_player_input_buffer *buffer; uint64_t token; _Atomic int done, errors; } fixture;
static void *writer(void *ptr) {
    fixture *f=ptr;
    for (unsigned i=1;i<=50000;i++) {
        s2a_player_input_frame sample=frame(i);
        if (!s2a_player_buffer_publish(f->buffer,f->token,&sample,100)) atomic_fetch_add(&f->errors,1);
    }
    atomic_store(&f->done,1); return NULL;
}
static void *reader(void *ptr) {
    fixture *f=ptr;
    do {
        s2a_player_input_frame sample;
        if (s2a_player_buffer_read(f->buffer,&sample,sizeof sample,101)) {
            int n=sample.slots[0].lx;
            for (int i=0;i<4;i++)
                if (sample.slots[i].buttons!=(1u<<i) || sample.slots[i].lx!=n+i ||
                    sample.slots[i].ly!=-n-i || sample.slots[i].rx!=n+i+10 || sample.slots[i].ry!=-n-i-10)
                    atomic_fetch_add(&f->errors,1);
        }
    } while (!atomic_load(&f->done));
    return NULL;
}
int main(void) {
    CHECK(offsetof(s2a_player_input_frame, slots[3])==76);
    s2a_player_input_buffer b; CHECK(s2a_player_buffer_init(&b));
    s2a_player_input_frame out, zero={0}, sample=frame(1000);
    CHECK(!s2a_player_buffer_read(&b,&out,sizeof out,100)); CHECK(!memcmp(&out,&zero,sizeof out));
    uint64_t first=s2a_player_buffer_begin(&b);
    CHECK(first!=0); CHECK(s2a_player_buffer_publish(&b,first,&sample,100));
    CHECK(s2a_player_buffer_read(&b,&out,sizeof out,100)); CHECK(!memcmp(&out,&sample,sizeof out));
    CHECK(!s2a_player_buffer_read(&b,&out,sizeof out,99)); CHECK(!memcmp(&out,&zero,sizeof out));
    CHECK(s2a_player_buffer_read(&b,&out,sizeof out,250100));
    CHECK(!s2a_player_buffer_read(&b,&out,sizeof out,250101)); CHECK(!memcmp(&out,&zero,sizeof out));
    memset(&out,0x5a,sizeof out); s2a_player_input_frame untouched=out;
    CHECK(!s2a_player_buffer_read(&b,&out,95,100)); CHECK(!memcmp(&out,&untouched,sizeof out));
    CHECK(!s2a_player_buffer_read(&b,NULL,96,100));
    s2a_player_buffer_stop(&b);
    CHECK(!s2a_player_buffer_publish(&b,first,&sample,100));
    CHECK(!s2a_player_buffer_read(&b,&out,sizeof out,100));
    uint64_t next=s2a_player_buffer_begin(&b); CHECK(next!=first);
    CHECK(s2a_player_buffer_publish(&b,next,&sample,100));
    CHECK(!s2a_player_buffer_publish(&b,first,NULL,100)); // stale clear must not erase new state
    CHECK(s2a_player_buffer_read(&b,&out,sizeof out,100)); CHECK(!memcmp(&out,&sample,sizeof out));
    for(int i=0;i<6;i++) {
        s2a_player_input_frame bad=sample;
        if(i==0) bad.version=2;
        if(i==1) bad.bytes=95;
        if(i==2) bad.connected_mask=16;
        if(i==3) bad.active=2;
        CHECK(!s2a_player_buffer_publish(&b,next,i==4?NULL:&bad,i==5?0:100));
        CHECK(!s2a_player_buffer_read(&b,&out,sizeof out,100)); CHECK(!memcmp(&out,&zero,sizeof out));
        CHECK(s2a_player_buffer_publish(&b,next,&sample,100));
    }
    sample.active=0; CHECK(s2a_player_buffer_publish(&b,next,&sample,100));
    CHECK(s2a_player_buffer_read(&b,&out,sizeof out,100) && !out.active && out.connected_mask==15);
    // Three real threads exercise coherent frames; never retain caller pointers.
    fixture f={.buffer=&b,.token=next}; pthread_t w,r1,r2;
    sample=frame(1); CHECK(s2a_player_buffer_publish(&b,next,&sample,100));
    CHECK(!pthread_create(&r1,NULL,reader,&f)); CHECK(!pthread_create(&r2,NULL,reader,&f));
    CHECK(!pthread_create(&w,NULL,writer,&f));
    CHECK(!pthread_join(w,NULL)); CHECK(!pthread_join(r1,NULL)); CHECK(!pthread_join(r2,NULL));
    CHECK(atomic_load(&f.errors)==0);
    s2a_player_buffer_stop(&b); s2a_player_buffer_destroy(&b);
    printf("✓ t_player_input_buffer: %u checks; 50000 concurrent publications, no torn frames\n",checks);
    return 0;
}
