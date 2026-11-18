"""Host actions never transfer resources; synthetic fixtures only."""
from pathlib import Path
from types import SimpleNamespace
from unittest import TestCase, mock
import json, sys, tempfile
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import mobile_lifecycle as M
import install, ipa
from core import Failure


class HostPlan(TestCase):
    def plan(self, receipt, host='a'*64, now=100):
        with mock.patch.object(M, 'live_info', return_value={'installed': receipt is not None}), \
             mock.patch.object(M, 'read_receipt', return_value=receipt), \
             mock.patch.object(M, 'verified_host', return_value={'id': host, 'replaces': ['a'*64]}), \
             mock.patch.object(ipa, 'current_shell_id', return_value='sid'), \
             mock.patch.object(ipa, 'current_root', return_value=Path('/synthetic')), \
             mock.patch.object(M, 'input_identity', return_value='input'):
            return M.host_plan(SimpleNamespace(), 'GAME', 'device', 'bundle', now=now)

    def receipt(self, **changes):
        return dict(dict(host='a'*64, games={'GAME': 'input'}, expires=1000000), **changes)

    def test_unchanged_valid_host_is_noop(self):
        self.assertFalse(self.plan(self.receipt())['required'])

    def test_absent_host_can_be_installed(self):
        self.assertEqual(self.plan(None)['reasons'], ['notInstalled'])

    def test_host_module_and_signing_reasons_are_distinct(self):
        self.assertEqual(self.plan(self.receipt(), 'b'*64)['reasons'], ['hostChanged'])
        self.assertEqual(self.plan(self.receipt(games={}))['reasons'], ['moduleChanged'])
        self.assertEqual(self.plan(self.receipt(expires=100))['reasons'], ['signingDue'])

    def test_unapproved_host_cannot_replace_newer_host(self):
        with self.assertRaises(Failure): self.plan(self.receipt(host='c'*64))


class HostAction(TestCase):
    def test_noop_never_assembles_signs_or_transfers(self):
        c = SimpleNamespace(r={'gameId': 'GAME'}, begin=mock.Mock())
        ph = SimpleNamespace(udid='device', bid='bundle', install=mock.Mock(), push=mock.Mock())
        with mock.patch.object(install, 'phone_for', return_value=ph), \
             mock.patch.object(M, 'host_plan', return_value={'required': False}), \
             mock.patch.object(ipa, 'assemble') as assemble:
            self.assertTrue(install.install_host(c)['unchanged'])
        assemble.assert_not_called(); ph.install.assert_not_called(); ph.push.assert_not_called()

    def run_action(self, change=None):
        with tempfile.TemporaryDirectory() as td:
            c = SimpleNamespace(private=Path(td), r={'gameId': 'GAME'}, begin=mock.Mock())
            live = dict(installed=True, CFBundleVersion='1234', Path='/synthetic/App')
            plan = dict(required=True, reasons=['moduleChanged'], expectedGames={'GAME': 'old', 'OTHER': 'keep'},
                        expectedInstallation=live, host='host', gameIdentity='new')
            ph = SimpleNamespace(udid='device', bid='bundle', info={}, install=mock.Mock(), push=mock.Mock())
            def assemble(c, gid, dest, *, expected_games):
                self.assertEqual(expected_games, plan['expectedGames'])
                app = dest/'S2Arm.app'; app.mkdir()
                inputs = {'GAME': 'new', 'OTHER': 'keep'}
                if change == 'missing': del inputs['OTHER']
                if change == 'other': inputs['OTHER'] = 'changed'
                if change == 'selected': inputs['GAME'] = 'changed'
                (app/'s2a_game_inputs.json').write_text(json.dumps(inputs))
                (app/'s2a_host.json').write_text(json.dumps({'id': 'changed' if change == 'host' else 'host'}))
                return dest/'S2Arm.ipa', list(inputs), ['GAME']
            with mock.patch.object(install, 'phone_for', return_value=ph), \
                 mock.patch.object(M, 'host_plan', return_value=plan), \
                 mock.patch.object(M, 'live_info', return_value=dict(live, Path='/changed') if change == 'live' else live), \
                 mock.patch.object(ipa, 'assemble', side_effect=assemble):
                if change:
                    with self.assertRaises(Failure): install.install_host(c)
                    ph.install.assert_not_called()
                else:
                    result = install.install_host(c)
                    self.assertTrue(result['installed']); self.assertEqual(result['packBytes'], 0)
                    ph.install.assert_called_once()
            ph.push.assert_not_called()

    def test_explicit_host_update_never_pushes(self): self.run_action()

    def test_changes_or_missing_existing_modules_block_before_install(self):
        for change in ('missing', 'other', 'selected', 'host', 'live'):
            with self.subTest(change=change): self.run_action(change)


class ResourceAdmissionRace(TestCase):
    def test_app_appearing_after_absence_check_blocks_before_candidate_or_signing(self):
        c = SimpleNamespace(operation='install')
        for live in ({'installed': True}, {}):
            with mock.patch.object(M, 'live_info', return_value=live), \
                 mock.patch.object(M, 'read_receipt') as receipt, \
                 mock.patch.object(M, 'verified_host') as verify:
                with self.assertRaises(Failure) as error:
                    M.stamp_install(c, Path('/not-opened'), 'device', 'bundle')
                self.assertEqual(error.exception.code, 'ios_host_action_required')
                receipt.assert_not_called(); verify.assert_not_called()

    def test_removed_or_changed_app_blocks_transfer_without_reinstall(self):
        ph = object.__new__(install.MacPhone)
        ph.c = SimpleNamespace(); ph.dev = {'id': 'device'}; ph.udid = 'device'; ph.bid = 'bundle'
        for result in (None, Failure('changed', code='ios_host_unknown')):
            ph.transfer_plan = mock.Mock(side_effect=result if isinstance(result, Failure) else None, return_value=None)
            with mock.patch.object(install, 'push_pack') as push, mock.patch.object(ph, 'install') as reinstall:
                with self.assertRaises(Failure): ph.push('GAME', Path('/synthetic'))
                push.assert_not_called(); reinstall.assert_not_called()

    def test_matching_installation_transfers_without_install(self):
        ph = object.__new__(install.MacPhone)
        ph.c = SimpleNamespace(); ph.dev = {'id': 'device'}; ph.udid = 'device'; ph.bid = 'bundle'
        ph.transfer_plan = mock.Mock(return_value={'games': ['0100000000000000'], 'fresh': ['0100000000000000']})
        with mock.patch.object(install, 'push_pack', return_value=(1, 2)) as push, mock.patch.object(ph, 'install') as reinstall:
            self.assertEqual(ph.push('0100000000000000', Path('/synthetic')), (1, 2))
            push.assert_called_once(); reinstall.assert_not_called()

class HostSigningIsolation(TestCase):
    def test_existing_profile_only_no_shader_merge_and_no_push(self):
        import plistlib, zipfile, diag
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            package = root/'fixture.ipa'
            with zipfile.ZipFile(package, 'w') as z:
                z.writestr('Payload/S2Arm.app/Info.plist', plistlib.dumps({'CFBundleIdentifier':'synthetic'}))
            c = SimpleNamespace(private=root, engine=root, task='fixture', operation='installHost',
                                env=lambda: {}, run=mock.Mock(), r={})
            stamp = {'expectedInstallation': {'installed': True}}
            with mock.patch.object(install, 'check_shell_sdk'), \
                 mock.patch.object(M, 'stamp_install', return_value=stamp), \
                 mock.patch.object(M, 'before_install') as before, \
                 mock.patch.object(M, 'finish_install') as finish, \
                 mock.patch.object(install, 'pull_seen') as seen, \
                 mock.patch.object(install, 'backup_saves') as backup, \
                 mock.patch.object(install, 'push_pack') as push, \
                 mock.patch.object(diag, 'devicectl', return_value=(0, {}, '')) as device:
                install.sign_and_install(c, package, {'id':'synthetic'}, {'id':'synthetic'},
                                         'synthetic', 'synthetic', ['GAME'], steps=False)
            self.assertEqual(c.run.call_count, 1)
            args = c.run.call_args.args[0]
            self.assertEqual(Path(args[1]).name, 'dev_sign.py')
            self.assertEqual(c.run.call_args.kwargs['env']['S2A_SIGN_PRIVATE'], '1')
            self.assertEqual(c.run.call_args.kwargs['env']['S2A_PROFILE_NEED_UDIDS'], 'synthetic')
            seen.assert_not_called(); push.assert_not_called(); backup.assert_called_once()
            before.assert_called_once(); finish.assert_called_once(); device.assert_called_once()

    def test_expired_profile_in_host_action_falls_back_to_ensure_profile(self):
        import plistlib, zipfile, diag
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            package = root/'fixture.ipa'
            with zipfile.ZipFile(package, 'w') as z:
                z.writestr('Payload/S2Arm.app/Info.plist', plistlib.dumps({'CFBundleIdentifier':'synthetic'}))
            c = SimpleNamespace(private=root, engine=root, task='fixture', operation='installHost',
                                env=lambda: {}, r={}, last_rc=3, job={'diagnostics': [{'code': 'tool_exit'}]})
            calls = []
            def run_side_effect(args, *a, **kw):
                calls.append(Path(args[1]).name)
                if len(calls) == 1:
                    raise Failure('exit 3', code='tool_exit')
            c.run = mock.Mock(side_effect=run_side_effect)
            stamp = {'expectedInstallation': {'installed': True}}
            with mock.patch.object(install, 'check_shell_sdk'), \
                 mock.patch.object(M, 'stamp_install', return_value=stamp), \
                 mock.patch.object(M, 'before_install'), \
                 mock.patch.object(M, 'finish_install'), \
                 mock.patch.object(install, 'pull_seen'), \
                 mock.patch.object(install, 'backup_saves'), \
                 mock.patch.object(diag, 'devicectl', return_value=(0, {}, '')):
                install.sign_and_install(c, package, {'id':'synthetic'}, {'id':'synthetic'},
                                         'synthetic', 'synthetic', ['GAME'], steps=False)
            self.assertEqual(calls, ['dev_sign.py', 'ensure_profile.sh', 'dev_sign.py'])
            self.assertEqual(c.job['diagnostics'], [])

