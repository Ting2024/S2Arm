"""Packaging must ship the host closure referenced by the worker."""
from pathlib import Path
import sys
import shutil
import tempfile
import unittest
from unittest import mock
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_app
sys.path.insert(0, str(build_app.ROOT))
from pack import ios_host
from pack.shell import manifest


class HostBundle(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name); self.shell = self.root/'Shell'
        (self.shell/'root').mkdir(parents=True)
        (self.shell/'root/S2Arm').write_bytes(b'host')
        (self.shell/'root/main.npdm').write_bytes(b'not-host')
        self.patch = mock.patch.object(manifest, 'verify', return_value={'details': {'shellId': 'shell'}})
        self.patch.start(); self.addCleanup(self.patch.stop)

    def test_shell_derived_closure_excludes_game_files(self):
        target = self.root/'IOSHost'
        build_app.bundle_ios_host(self.shell, target)
        doc = ios_host.load(target)
        self.assertEqual(list(doc['files']), ['S2Arm'])
        self.assertEqual(doc['compatibleShellIds'], ['shell'])

    def test_explicit_update_must_match_release_shell(self):
        update = self.root/'Update'; build_app.bundle_ios_host(self.shell, update)
        target = self.root/'IOSHost'; build_app.bundle_ios_host(self.shell, target, update)
        self.assertEqual(ios_host.load(update), ios_host.load(target))
        with mock.patch.object(manifest, 'verify', return_value={'details': {'shellId': 'other'}}):
            with self.assertRaises(SystemExit): build_app.bundle_ios_host(self.shell, self.root/'Rejected', update)
        self.assertFalse((self.root/'Rejected').exists())

    def test_corrupt_update_never_ships(self):
        update = self.root/'Update'; build_app.bundle_ios_host(self.shell, update)
        (update/'root/S2Arm').write_bytes(b'bad')
        with self.assertRaises(ValueError): build_app.bundle_ios_host(self.shell, self.root/'Rejected', update)
        self.assertFalse((self.root/'Rejected').exists())


class MobileDelivery(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name); self.source = self.root / 'source'
        self.resources = self.root / 'Resources'
        tool_check = mock.patch.object(build_app, 'verify_mobile_query_tool')
        self.tool_check = tool_check.start(); self.addCleanup(tool_check.stop)
        for name in ('main.py', 'install.py', 'ipa.py', 'mobile_lifecycle.py', 'mobile_confirmation.py', 'users.py', 'core.py', 'errors.py', 'future_dependency.py'):
            for directory in (self.source/'pack/jobs', self.resources/'Jobs', self.resources/'Engine/pack/jobs'):
                directory.mkdir(parents=True, exist_ok=True)
                (directory/name).write_text('tested ' + name)
        for directory in (self.source/'pack', self.resources/'Engine/pack'):
            (directory/'ios_host.py').write_text('tested verifier')

    def test_both_worker_copies_and_actual_host_are_required(self):
        with mock.patch.object(ios_host, 'load', return_value={'id': 'verified'}) as load:
            self.assertEqual(build_app.verify_mobile_delivery(self.resources, self.source), {'id': 'verified'})
            load.assert_called_once_with(self.resources/'IOSHost')
            self.tool_check.assert_called_once_with(self.resources)

    def test_missing_or_old_executed_jobs_cannot_hide_behind_updated_engine(self):
        for directory in ('Jobs', 'Engine/pack/jobs'):
            for name in ('main.py', 'install.py', 'ipa.py', 'mobile_lifecycle.py', 'mobile_confirmation.py', 'users.py', 'core.py', 'errors.py', 'future_dependency.py'):
                path = self.resources/directory/name; original = path.read_bytes()
                for content in (None, b'old unprotected installer'):
                    with self.subTest(directory=directory, name=name, missing=content is None):
                        if content is None: path.unlink()
                        else: path.write_bytes(content)
                        with mock.patch.object(ios_host, 'load') as load, self.assertRaises(ValueError):
                            build_app.verify_mobile_delivery(self.resources, self.source)
                        load.assert_not_called()
                        path.write_bytes(original)

    def test_linked_worker_and_stale_host_helper_rejected(self):
        path = self.resources/'Jobs/install.py'; path.unlink()
        path.symlink_to(self.source/'pack/jobs/install.py')
        with self.assertRaises(ValueError): build_app.verify_mobile_delivery(self.resources, self.source)
        path.unlink(); shutil.copy2(self.source/'pack/jobs/install.py', path)
        (self.resources/'Engine/pack/ios_host.py').write_text('old')
        with self.assertRaises(ValueError): build_app.verify_mobile_delivery(self.resources, self.source)

    def test_missing_or_corrupt_host_is_not_a_delivered_fix(self):
        with self.assertRaises(OSError): build_app.verify_mobile_delivery(self.resources, self.source)
        with mock.patch.object(ios_host, 'load', side_effect=ValueError('corrupt')):
            with self.assertRaises(ValueError): build_app.verify_mobile_delivery(self.resources, self.source)


if __name__ == '__main__': unittest.main()
