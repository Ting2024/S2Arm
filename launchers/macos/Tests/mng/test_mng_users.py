"""Original MNG user registry/ownership, isolated fixtures, no save migration."""
from pathlib import Path
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[4]
SOURCE=r'''
#import "user_store.h"
#include <assert.h>
int main(int argc,char **argv) { @autoreleasepool {
 assert(argc==2); NSString *root=@(argv[1]), *error=nil;
 MNGUserStore *store=[[MNGUserStore alloc] initWithRoot:root];
 assert([store reload:&error]);assert(store.selected==1);
 assert([store edit:@"add" user:0 name:nil error:&error]);assert(store.selected==2);
 assert([store edit:@"rename" user:2 name:@"Second fixture" error:&error]);
 assert([store edit:@"select" user:1 name:nil error:&error]);
 MNGUserStore *second=[[MNGUserStore alloc] initWithRoot:root];
 assert([second reload:&error]);assert(second.selected==1);
 assert([second.users[@2] isEqual:@"Second fixture"]);
 assert([store edit:@"reserve" user:2 name:nil error:&error]);
 assert(![second edit:@"reserve" user:2 name:nil error:&error]);
 assert(![second edit:@"delete" user:2 name:nil error:&error]);
 assert([second reload:&error]);assert(second.users[@2]);
 assert(![second edit:@"rename" user:2 name:@"bad\nname" error:&error]);
 assert([second reload:&error]);assert([second.users[@2] isEqual:@"Second fixture"]);
 puts("PASS original registry, rename, selection, ownership and deletion exclusion");
} }
'''
class MNGUsersTests(unittest.TestCase):
    def test_original_store_and_lifetime_lock(self):
        with tempfile.TemporaryDirectory(prefix='s2a-mng-users-') as tmp:
            root=Path(tmp).resolve();src=root/'probe.m';src.write_text(SOURCE);exe=root/'probe'
            result=subprocess.run(['clang','-fobjc-arc','-Wall','-Wextra','-Werror',
                '-I'+str(ROOT/'macos/controllers/mng'),str(src),'-framework','Foundation','-o',str(exe)],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            profile=root/'profile';profile.mkdir()
            subprocess.run(['ps','-axo','pid=,comm='],stdout=subprocess.DEVNULL,check=True)
            result=subprocess.run([exe,profile],capture_output=True,text=True,timeout=10)
            self.assertEqual(result.returncode,0,result.stderr)
