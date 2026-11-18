"""Real launch orchestration, fake host execution, independent synthetic state."""
import json
from contextlib import ExitStack
from pathlib import Path
from unittest.mock import patch

from jobcase import JobCase
from core import Context, Failure, atomic
import build
import host_update
import saves
import toolchain
import users

GID = '0100000000000000'


class UserLaunchTests(JobCase):
    def setUp(self):
        super().setUp()
        self.game = dict(id=GID, name='Synthetic', packages=[])
        atomic(self.c.library / 'catalog.json', dict(schema=1, games=[self.game]))
        self.c.r.update(action='create', name='Second Fixture', revision=0)
        users.update(self.c)

    def context(self, user='02'):
        extra = {} if user is None else dict(userId=user)
        return Context(self.request | dict(gameId=GID, taskId='launch-fixture') | extra)

    def host(self, supported=True, signed=True):
        stack = ExitStack()
        stack.enter_context(patch.object(build, 'validate_runtime', return_value=dict(gameId=GID, memoryRequirementsVersion=2)))
        stack.enter_context(patch.object(host_update, 'current_host', return_value=None))
        stack.enter_context(patch.object(host_update, 'verify_signature', side_effect=None if signed else Failure('signature failed')))
        stack.enter_context(patch.object(toolchain, 'launcher_account_interface', return_value=(supported, 'unsupported fixture')))
        return stack

    def test_unsupported_or_unsigned_host_rejected_before_recovery_and_profile_creation(self):
        for supported, signed in ((False, True), (True, False)):
            c = self.context()
            with self.host(supported, signed), patch.object(saves, 'recover') as recover, patch.object(c, 'run') as run:
                with self.assertRaises(Failure):
                    build.launch(c)
                recover.assert_not_called()
                run.assert_not_called()
            self.assertFalse(users.paths(c, GID)['save'].exists())

    def test_player_layout_is_accepted_across_sources_and_users(self):
        config = dict(schema=1, players={str(i): dict(backend='auto', device='') for i in range(1, 5)},
                      keyboard={}, mouse={}, gamepad={}, axes={}, deadzone=.15,
                      mouseOptions=dict(mode='off', sensitivityX=1, sensitivityY=1))
        for source in ('request', 'game', 'default'):
            for user in (None, '01', '02'):
                c = self.context(user)
                game_path = users.input_path(c, GID)
                default_path = c.private / 'default-input.json'
                game_path.unlink(missing_ok=True)
                default_path.unlink(missing_ok=True)
                if source == 'request': c.r['launchInputConfig'] = config
                elif source == 'game': atomic(game_path, config)
                else: atomic(default_path, config)
                account = users.session_descriptor(c, GID) if (user is not None or users.selected(c)['id'] != '01') else None
                env = build.runtime_env(c, self.game, self.root / 'runtime', account=account)
                self.assertIn('S2A_INPUT_CONFIG', env)
                Path(env['S2A_INPUT_CONFIG']).unlink(missing_ok=True)

    def test_explicit_launch_binds_uid_root_and_holds_pair_lock_until_exit(self):
        c = self.context()
        uid = users.selected(c)['accountUid']
        calls = []
        def run(command, log, env, **kw):
            calls.append(command)
            descriptor = json.loads(env['S2A_SESSION_USER'])
            self.assertEqual(descriptor['id'], '02')
            self.assertEqual(descriptor['accountUid'], uid)
            self.assertEqual(descriptor['stateRoot'], env['S2A_RYU_DATA'])
            self.assertEqual(Path(env['S2A_RYU_DATA']), c.library / 'saves/users/02' / GID)
            self.assertEqual(kw['cwd'], Path(env['S2A_DOCS']))
            with self.assertRaises(Failure):
                with users.session_lock(self.context(), GID): pass
            with users.session_lock(self.context('01'), GID): pass
            with self.assertRaises(Failure):
                with c.lock('game-' + GID): pass
            self.assertNotIn('S2A_SAVE_DIR', env)
        with self.host(), patch.object(c, 'run', side_effect=run):
            result = build.launch(c)
        self.assertEqual(result, dict(gameId=GID, userId='02'))
        self.assertEqual(len(calls), 1)
        with users.session_lock(c, GID): pass
        self.assertFalse((c.library / 'saves' / GID).exists())

    def test_two_launch_orchestrations_share_resources_but_not_user_state(self):
        first, second = self.context('01'), self.context('02')
        first.task, second.task = 'first-launch', 'second-launch'
        environments = []
        def second_run(command, log, env, **kw):
            environments.append(env)
            with self.assertRaises(Failure):
                saves.status(self.context('01'))
            with self.assertRaises(Failure):
                saves.status(self.context('02'))
        def first_run(command, log, env, **kw):
            environments.append(env)
            with patch.object(second, 'run', side_effect=second_run):
                build.launch(second)
            # The other session's exit releases only its own ownership.
            with self.assertRaises(Failure):
                with users.session_lock(self.context('01'), GID): pass
            with users.session_lock(self.context('02'), GID): pass
        with self.host(), patch.object(first, 'run', side_effect=first_run):
            build.launch(first)
        self.assertEqual(len(environments), 2)
        self.assertEqual(environments[0]['S2A_GAME_DATA'], environments[1]['S2A_GAME_DATA'])
        for key in (*users.runtime_paths(first, GID), 'S2A_MNG_INPUT_ROOT'):
            self.assertNotEqual(environments[0][key], environments[1][key])
        self.assertEqual(Path(environments[0]['S2A_MNG_INPUT_ROOT']).stat().st_mode & 0o777, 0o700)
        self.assertEqual(Path(environments[1]['S2A_MNG_INPUT_ROOT']).stat().st_mode & 0o777, 0o700)
        with users.session_lock(first, GID), users.session_lock(second, GID): pass

    def test_implicit_legacy_launch_preserves_identity_and_explicit_01_requires_host_support(self):
        c = self.context(None)
        with self.host(False), patch.object(c, 'run') as run:
            build.launch(c)
        self.assertNotIn('S2A_SESSION_USER', run.call_args.args[2])
        explicit = self.context('01')
        with self.host(False), patch.object(explicit, 'run') as run:
            with self.assertRaises(Failure): build.launch(explicit)
            run.assert_not_called()
        with self.host(), patch.object(explicit, 'run') as run:
            build.launch(explicit)
        descriptor = json.loads(run.call_args.args[2]['S2A_SESSION_USER'])
        self.assertIsNone(descriptor['accountUid'])
        self.assertEqual(descriptor['stateRoot'], str(c.library / 'saves' / GID))

    def test_duplicate_pair_rejects_before_host_admission_and_exception_releases_lock(self):
        c = self.context()
        with users.session_lock(c, GID), patch.object(build, 'validate_runtime') as validate:
            with self.assertRaises(Failure): build.launch(self.context())
            validate.assert_not_called()
        with self.host(), patch.object(c, 'run', side_effect=Failure('synthetic exit')):
            with self.assertRaises(Failure): build.launch(c)
        with users.session_lock(self.context(), GID): pass
