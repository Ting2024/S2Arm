# 门禁手动：要预构建的 build/devpush/release/s2a-devpush（cargo --release 产物），门禁默认不跑 Rust release 编译；手机查询与生命周期逻辑已由 pack/jobs/tests/test_mobile_lifecycle.py 覆盖
"""Offline executable contract checks: no device, installation, or Git fixtures."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT/'pack/jobs'), str(ROOT/'launchers/macos')]
import mobile_lifecycle as M
import build_app
import install
from core import Failure


class QueryTool(unittest.TestCase):
    def test_real_executable_offline_contract(self):
        exe = Path(os.environ.get('S2A_TEST_DEVPUSH', ROOT/'build/devpush/release/s2a-devpush'))
        self.assertTrue(exe.is_file(), 'build the device tool first')
        env = dict(os.environ, USBMUXD_SOCKET_ADDRESS='127.0.0.1:1')
        # An unreachable mux address proves the handshake needs no phone service.
        M.require_query_tool(exe, env)

    def test_real_tool_in_packaged_location(self):
        exe = Path(os.environ.get('S2A_TEST_DEVPUSH', ROOT/'build/devpush/release/s2a-devpush'))
        with tempfile.TemporaryDirectory() as work:
            target = Path(work)/'Engine/Binaries/Prepare/devpush/s2a-devpush'
            target.parent.mkdir(parents=True)
            shutil.copy2(exe, target)
            with mock.patch.dict(os.environ, USBMUXD_SOCKET_ADDRESS='127.0.0.1:1'):
                build_app.verify_mobile_query_tool(work)

    def test_packaging_and_worker_reject_bad_contracts(self):
        good = dict(schema=1, operations=['app-info'])
        cases = [(0, plistlib.dumps(good)), (2, b''), (0, b'bad'),
                 (0, b'<?xml version="1.0"?><plist><dict>'),
                 (0, plistlib.dumps(dict(schema=1, operations=[]))),
                 (0, plistlib.dumps(dict(schema=True, operations=['app-info']))),
                 (0, plistlib.dumps(dict(schema=1, operations='app-info')))]
        for i, (rc, data) in enumerate(cases):
            with self.subTest(case=i), mock.patch.object(subprocess, 'run', return_value=SimpleNamespace(returncode=rc, stdout=data)):
                if i == 0:
                    M.require_query_tool('/synthetic/tool', {})
                    build_app.verify_mobile_query_tool('/synthetic/resources')
                else:
                    with self.assertRaises(Failure): M.require_query_tool('/synthetic/tool', {})
                    with self.assertRaises(ValueError): build_app.verify_mobile_query_tool('/synthetic/resources')

    def test_old_tool_stops_before_device_query(self):
        with tempfile.TemporaryDirectory() as work:
            c = SimpleNamespace(private=Path(work), env=lambda: {})
            with mock.patch.object(install, 'devpush_client', return_value=SimpleNamespace(exe='/synthetic/tool')), mock.patch.object(subprocess, 'run', return_value=SimpleNamespace(returncode=2, stdout=b'')) as run:
                with self.assertRaises(Failure) as caught: M.live_info(c, 'device', 'bundle')
                self.assertIn('Mac 随包手机工具', str(caught.exception))
                self.assertEqual(run.call_count, 1)
                self.assertEqual(run.call_args.args[0][-1], '--capabilities')

    def query(self, result, *, rc=0):
        with tempfile.TemporaryDirectory() as work:
            c = SimpleNamespace(private=Path(work), env=lambda: {})
            replies = [SimpleNamespace(returncode=0, stdout=plistlib.dumps(dict(schema=1, operations=['app-info']))),
                       SimpleNamespace(returncode=rc, stdout=plistlib.dumps(result, fmt=plistlib.FMT_BINARY))]
            with mock.patch.object(install, 'devpush_client', return_value=SimpleNamespace(exe='/synthetic/tool')), mock.patch.object(subprocess, 'run', side_effect=replies) as run:
                answer = M.live_info(c, 'device', 'bundle')
                self.assertEqual(run.call_args.args[0], ['/synthetic/tool', 'device', 'bundle', 'app-info', '-'])
                return answer

    def test_complete_live_identity_and_confirmed_absence(self):
        live = dict(installed=True, CFBundleVersion='1234.5.6', Path='/synthetic/App.app')
        self.assertEqual(self.query(live), live)
        self.assertEqual(self.query(dict(installed=False)), dict(installed=False))

    def test_incomplete_or_malformed_live_identity_is_not_admitted(self):
        for live in [dict(installed=True), dict(installed=True, CFBundleVersion='1'),
                     dict(installed=True, CFBundleVersion='', Path='/App'),
                     dict(installed=True, CFBundleVersion=123, Path='/App'),
                     dict(installed=True, CFBundleVersion='1', Path=[]),
                     dict(installed=True, CFBundleVersion='1', Path=''),
                     dict(installed=True, CFBundleVersion='1', Path='relative/App'),
                     dict(installed=True, CFBundleVersion='1', Path='/App\x00bad'),
                     dict(installed=1), dict(installed='false'), {}]:
            with self.subTest(live=live), self.assertRaises(Failure): self.query(live)

    def test_truncated_live_plist_is_controlled_failure(self):
        with tempfile.TemporaryDirectory() as work:
            c = SimpleNamespace(private=Path(work), env=lambda: {})
            with mock.patch.object(install, 'devpush_client', return_value=SimpleNamespace(exe='/synthetic/tool')), mock.patch.object(M, 'require_query_tool'), mock.patch.object(subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=b'<?xml version="1.0"?><plist><dict>')):
                with self.assertRaises(Failure): M.live_info(c, 'device', 'bundle')

    def test_nonzero_exit_never_admits_even_valid_plist(self):
        with self.assertRaises(Failure): self.query(dict(installed=False), rc=1)

    def test_timeouts_and_missing_tool_fail_closed(self):
        for error in [FileNotFoundError(), subprocess.TimeoutExpired('tool', 10)]:
            with mock.patch.object(subprocess, 'run', side_effect=error):
                with self.assertRaises(Failure): M.require_query_tool('/synthetic/tool', {})
                with self.assertRaises(ValueError): build_app.verify_mobile_query_tool('/synthetic/resources')


if __name__ == '__main__': unittest.main()
