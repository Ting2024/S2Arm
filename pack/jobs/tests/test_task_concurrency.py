# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Execution readers coexist; mutations and same-game work remain exclusive."""
from jobcase import JobCase
from core import Failure


class TaskConcurrency(JobCase):
    def test_play_and_other_game_build_can_hold_execution(self):
        with self.c.lock('execution', shared=True), self.c.lock('play'), self.c.lock('game-A'):
            with self.c.lock('execution', shared=True), self.c.lock('build'), self.c.lock('game-B'):
                pass
            with self.assertRaises(Failure):
                with self.c.lock('execution'): pass
            with self.assertRaises(Failure):
                with self.c.lock('game-A'): pass
            with self.assertRaises(Failure):
                with self.c.lock('play'): pass

    def test_mutation_prevents_play_and_build(self):
        with self.c.lock('execution'):
            with self.assertRaises(Failure):
                with self.c.lock('execution', shared=True): pass


class UserSessionConcurrency(JobCase):
    def setUp(self):
        super().setUp()
        import users
        from core import Context
        self.c.r.update(action='create', name='Second Fixture', revision=0)
        users.update(self.c)
        self.first = Context(self.c.r | dict(userId='01', taskId='first-fixture'))
        self.second = Context(self.c.r | dict(userId='02', taskId='second-fixture'))
        self.gid = '0100000000000000'

    def test_different_users_coexist_duplicate_pair_and_resource_mutations_block(self):
        import users
        with users.session_lock(self.first, self.gid):
            with users.session_lock(self.second, self.gid):
                for context in (self.first, self.second):
                    with self.assertRaises(Failure):
                        with users.session_lock(context, self.gid):
                            self.fail('duplicate pair admitted')
                with self.assertRaises(Failure):
                    with self.c.lock('game-' + self.gid):
                        self.fail('shared resources writable during play')
                with self.assertRaises(Failure):
                    with self.c.lock('execution'):
                        self.fail('library mutation admitted during play')
                # A different game's build and a different game for the same
                # launcher user do not share mutable per-game state.
                with self.c.lock('execution', shared=True), self.c.lock('game-0100000000000001'):
                    pass
                with users.session_lock(self.first, '0100000000000002'):
                    pass
        with self.c.lock('execution'), self.c.lock('game-' + self.gid):
            pass

    def test_resource_writer_and_library_mutation_block_session_and_release_partial_locks(self):
        import users
        for name in ('execution', 'game-' + self.gid):
            with self.c.lock(name):
                with self.assertRaises(Failure):
                    with users.session_lock(self.first, self.gid):
                        self.fail('session admitted during mutation')
            with users.session_lock(self.first, self.gid):
                pass
        try:
            with users.session_lock(self.first, self.gid):
                raise RuntimeError('fixture cancellation')
        except RuntimeError:
            pass
        with self.c.lock('execution'), self.c.lock('game-' + self.gid):
            pass

    def test_real_child_contends_for_same_pair_but_not_other_user(self):
        import json
        import subprocess
        import sys
        import users
        from jobcase import JOBS
        code = '''
import json, sys
sys.path.insert(0, sys.argv[1])
from core import Context, Failure
import users
c = Context(json.loads(sys.stdin.read()))
try:
    with users.session_lock(c, '0100000000000000'): pass
except Failure:
    sys.exit(23)
'''
        with users.session_lock(self.first, self.gid):
            for context, expected in ((self.first, 23), (self.second, 0)):
                result = subprocess.run([sys.executable, '-B', '-c', code, str(JOBS)],
                                        input=json.dumps(context.r), text=True,
                                        capture_output=True, timeout=20)
                self.assertEqual(result.returncode, expected)
