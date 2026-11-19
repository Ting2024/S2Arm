"""Isolated lifecycle tests; no phone access or formal profiles."""
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import mobile_lifecycle as M
from core import Failure


class Lifecycle(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.c = SimpleNamespace(private=Path(self.tmp.name))
        self.host = 'a' * 64
        self.receipt = dict(schema=1, version='1234.56.78', host=self.host,
                            games={'GAME': 'input'}, expires=1000, installationPath='/synthetic/installation/App')
        p = M.receipt_path(self.c, 'device', 'bundle'); p.parent.mkdir()
        p.write_text(json.dumps(self.receipt))

    def test_live_match_required(self):
        self.assertEqual(M.read_receipt(self.c, 'device', 'bundle',
                         dict(installed=True, CFBundleVersion='1234.56.78', Path='/synthetic/installation/App')), self.receipt)
        for live in [dict(installed=True, CFBundleVersion='1'), dict(installed=True), {}]:
            with self.assertRaises(Failure): M.read_receipt(self.c, 'device', 'bundle', live)

    def test_reinstalled_same_version_does_not_reuse_receipt(self):
        with self.assertRaises(Failure):
            M.read_receipt(self.c, 'device', 'bundle', dict(installed=True,
                CFBundleVersion='1234.56.78', Path='/synthetic/different-installation/App'))

    def test_missing_app_does_not_trust_receipt(self):
        self.assertIsNone(M.read_receipt(self.c, 'device', 'bundle', {'installed': False}))

    def test_device_or_bundle_change_not_trusted(self):
        with self.assertRaises(Failure):
            M.read_receipt(self.c, 'other-device', 'bundle', dict(installed=True, CFBundleVersion='1234.56.78', Path='/synthetic/installation/App'))

    def test_same_module_retry_skips_install(self):
        self.assertTrue(M.can_push(self.receipt, 'GAME', 'input', now=500))
        self.assertFalse(M.can_push(self.receipt, 'GAME', 'changed', now=500))
        self.assertFalse(M.can_push(self.receipt, 'NEW', 'input', now=500))

    def test_expired_signing_cannot_skip_install(self):
        self.assertFalse(M.can_push(self.receipt, 'GAME', 'input', now=701))

    def test_host_change_requires_explicit_predecessor(self):
        M.require_host(self.receipt, dict(id=self.host))
        with self.assertRaises(Failure): M.require_host(self.receipt, dict(id='b' * 64))
        M.require_host(self.receipt, dict(id='b' * 64, replaces=[self.host]))

    def test_inputs_include_code_and_tables_not_resources(self):
        root = self.c.private/'root'; root.mkdir()
        for name in ['main.npdm', 'main.patched.bin', 'main.gates.tsv']:
            (root/name).write_bytes(b'original')
        a = M.input_identity(root, 'sid')
        (root/'romfs.bin').write_bytes(b'data'); self.assertEqual(a, M.input_identity(root, 'sid'))
        (root/'main.gates.tsv').write_bytes(b'changed'); self.assertNotEqual(a, M.input_identity(root, 'sid'))
        self.assertNotEqual(a, M.input_identity(root, 'other-sid'))

    def test_symlink_inputs_rejected(self):
        root = self.c.private/'root'; root.mkdir()
        (root/'main.npdm').write_bytes(b'n'); (root/'main.patched.bin').symlink_to(root/'main.npdm')
        with self.assertRaises(Failure): M.input_identity(root, 'sid')


class ResourceOnlyPlan(unittest.TestCase):
    def test_only_confirmed_absence_admits_automatic_install(self):
        from unittest import mock
        import ipa
        c = SimpleNamespace()
        with mock.patch.object(M, 'live_info', return_value={'installed': False}),              mock.patch.object(M, 'read_receipt', return_value=None),              mock.patch.object(M, 'verified_host') as host,              mock.patch.object(ipa, 'current_root') as current:
            self.assertIsNone(M.plan(c, 'GAME', 'device', 'bundle'))
            host.assert_called_once_with(c); current.assert_not_called()

    def test_existing_app_never_falls_back_to_reinstallation(self):
        from unittest import mock
        import ipa
        c = SimpleNamespace()
        for root, games, expiry in [(None, {}, 9999999999), (Path('/synthetic'), {}, 9999999999),
                                    (Path('/synthetic'), {'GAME': 'other'}, 9999999999),
                                    (Path('/synthetic'), {'GAME': 'input'}, 0)]:
            with self.subTest(root=root, games=games, expiry=expiry),                  mock.patch.object(M, 'live_info', return_value={'installed': True}),                  mock.patch.object(M, 'read_receipt', return_value={'games': games, 'expires': expiry}),                  mock.patch.object(ipa, 'current_shell_id', return_value='sid'),                  mock.patch.object(ipa, 'current_root', return_value=root),                  mock.patch.object(M, 'input_identity', return_value='input'),                  mock.patch.object(M, 'verified_host') as host:
                with self.assertRaises(Failure) as error: M.plan(c, 'GAME', 'device', 'bundle')
                self.assertEqual(error.exception.code, 'ios_host_action_required')
                host.assert_not_called()

    def test_known_unexpired_module_returns_only_transfer_plan(self):
        from unittest import mock
        import ipa
        with mock.patch.object(M, 'live_info', return_value={'installed': True}),              mock.patch.object(M, 'read_receipt', return_value={'games': {'GAME': 'input'}, 'expires': 9999999999}),              mock.patch.object(ipa, 'current_shell_id', return_value='sid'),              mock.patch.object(ipa, 'current_root', return_value=Path('/synthetic')),              mock.patch.object(M, 'input_identity', return_value='input'),              mock.patch.object(M, 'verified_host') as host:
            self.assertEqual(M.plan(SimpleNamespace(), 'GAME', 'device', 'bundle'), {'games': ['GAME'], 'fresh': ['GAME']})
            host.assert_not_called()


class BeforeOverwrite(unittest.TestCase):
    def setUp(self):
        from unittest import mock
        self.mock = mock
        self.c = SimpleNamespace(check=mock.Mock())
        self.live = dict(installed=True, CFBundleVersion='1234.56.78', Path='/synthetic/App')

    def run_check(self, current=None, processes=None, rc=0):
        import diag
        with self.mock.patch.object(M, 'live_info', return_value=self.live if current is None else current), \
             self.mock.patch.object(M.subprocess, 'run', return_value=SimpleNamespace(returncode=0)), \
             self.mock.patch.object(diag, 'devicectl', return_value=(rc, {'result': {'runningProcesses': processes}}, '')):
            M.before_install(self.c, 'device', 'bundle', 'device-id', self.live)

    def test_unchanged_idle_installation_admitted(self):
        self.run_check(processes=[])
        self.c.check.assert_called_once()

    def test_replacement_during_signing_rejected(self):
        with self.assertRaises(Failure):
            self.run_check(current=dict(self.live, Path='/synthetic/reinstalled/App'), processes=[])

    def test_running_game_terminated_before_overwrite(self):
        import diag
        with self.mock.patch.object(M, 'live_info', return_value=self.live), \
             self.mock.patch.object(M.subprocess, 'run', return_value=SimpleNamespace(returncode=0)), \
             self.mock.patch.object(diag, 'devicectl', side_effect=[
                 (0, {'result': {'runningProcesses': [{'executable': '/some/S2Arm.app/S2Arm', 'processIdentifier': 1309}]}}, ''),
                 (0, {}, ''),
             ]) as dctl:
            M.before_install(self.c, 'device', 'bundle', 'device-id', self.live)
            dctl.assert_any_call(self.c, 'device', 'process', 'terminate', '--device', 'device-id', '--pid', '1309', '--kill', timeout=30)
        self.c.check.assert_called_once()

    def test_unknown_process_inventory_does_not_block_install(self):
        for rc, processes in [(1, []), (0, None)]:
            with self.subTest(rc=rc):
                self.run_check(processes=processes, rc=rc)


class TransferRouting(unittest.TestCase):
    def test_resource_retry_does_not_assemble_install_or_refresh_signing(self):
        import install
        import ipa
        import unittest.mock as mock
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); gid = "0100000000000000"
            out = root / "iPhone" / gid; out.mkdir(parents=True)
            (out / "game.ipa").write_bytes(b"fixture")
            pack = out / "game资源包"; pack.mkdir()
            record = root / "games" / gid / "ios-install.json"
            record.parent.mkdir(parents=True); record.write_text('{"at": 10}')
            c = SimpleNamespace(library=root, begin=mock.Mock(), emit=mock.Mock())
            ph = object.__new__(install.MacPhone)
            ph.bid = "test.bundle"; ph.info = dict(free=True, device="fixture")
            ph.transfer_plan = mock.Mock(return_value=dict(games=[gid], fresh=[gid]))
            ph.install = mock.Mock(); ph.before_push = mock.Mock()
            ph.push = mock.Mock(return_value=(3, 123))
            with mock.patch.object(ipa, "assemble") as assemble:
                result = install.put_game(c, gid, ph)
            assemble.assert_not_called(); ph.install.assert_not_called()
            ph.push.assert_called_once_with(gid, pack)
            self.assertEqual(record.read_text(), '{"at": 10}')
            self.assertEqual(result['packBytes'], 123)

    def test_unknown_live_version_stops_before_assembly_or_transfer(self):
        import install
        import ipa
        import unittest.mock as mock
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); gid = "0100000000000000"
            out = root / "iPhone" / gid; out.mkdir(parents=True)
            (out / "game.ipa").write_bytes(b"fixture"); (out / "game资源包").mkdir()
            c = SimpleNamespace(library=root, begin=mock.Mock())
            ph = object.__new__(install.MacPhone)
            ph.transfer_plan = mock.Mock(side_effect=Failure("unknown", code="ios_host_unknown"))
            ph.install = mock.Mock(); ph.push = mock.Mock()
            with mock.patch.object(ipa, "assemble") as assemble, self.assertRaises(Failure):
                install.put_game(c, gid, ph)
            assemble.assert_not_called(); ph.install.assert_not_called(); ph.push.assert_not_called()


if __name__ == '__main__': unittest.main()
