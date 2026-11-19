"""Exact-host account admission; synthetic binaries and private roots only."""
import shutil
import subprocess
import sys
from unittest.mock import patch
import unittest

from jobcase import JobCase
from core import Failure
import toolchain
import users

GID = '0100000000000000'


class LauncherAccountHostTests(JobCase):
    def setUp(self):
        super().setUp()
        self.exe = self.root / 'selected-host'
        self.exe.write_bytes(b'fixture')

    def probe(self, stdout, returncode=0):
        result = subprocess.CompletedProcess([], returncode, stdout=stdout)
        return patch.object(toolchain.subprocess, 'run', return_value=result)

    def test_only_defined_exact_version_is_admitted(self):
        for output in ('', ' U _S2A_LauncherAccount_v1\n',
                       '00000001 (__TEXT,__text) external _S2A_LauncherAccount_v10\n',
                       '00000001 (__TEXT,__text) external _S2A_LauncherAccount_v1_extra\n',
                       '00000001 (__DATA,__data) external _S2A_LauncherAccount_v1\n'):
            with self.subTest(output=output), self.probe(output):
                self.assertFalse(toolchain.launcher_account_interface(self.c, self.exe)[0])
        with self.probe('00000001 (__TEXT,__text) external _S2A_LauncherAccount_v1\n') as run:
            self.assertTrue(toolchain.launcher_account_interface(self.c, self.exe)[0])
            self.assertEqual(run.call_args.args[0], ['nm', '-gmU', str(self.exe)])

    def test_managed_code_export_is_admitted_but_other_sections_are_not(self):
        for section, qualifier, expected in (
                ('__TEXT,__managedcode', '[no dead strip] ', True),
                ('__TEXT,__managedcode', '', True),
                ('__TEXT,__const', '', False),
                ('__DATA,__data', '', False),
                ('__TEXT,__managedcode', 'weak ', False)):
            output = f'00000001 ({section}) external {qualifier}_S2A_LauncherAccount_v1\n'
            with self.subTest(section=section, qualifier=qualifier), self.probe(output):
                self.assertEqual(toolchain.launcher_account_interface(self.c, self.exe)[0], expected)

    def test_failure_missing_link_and_timeout_never_fall_back(self):
        with self.probe('00000001 (__TEXT,__text) external _S2A_LauncherAccount_v1\n', 1):
            self.assertFalse(toolchain.launcher_account_interface(self.c, self.exe)[0])
        for error in (OSError('fixture'), subprocess.TimeoutExpired('nm', 60)):
            with patch.object(toolchain.subprocess, 'run', side_effect=error):
                self.assertFalse(toolchain.launcher_account_interface(self.c, self.exe)[0])
        alias = self.root / 'alias'
        alias.symlink_to(self.exe)
        with patch.object(toolchain.subprocess, 'run') as run:
            self.assertFalse(toolchain.launcher_account_interface(self.c, alias)[0])
            self.assertFalse(toolchain.launcher_account_interface(self.c, self.root / 'absent')[0])
            run.assert_not_called()

    def test_no_stamp_cache_or_engine_manifest_can_grant_support(self):
        with self.probe('00000001 (__TEXT,__text) external _S2A_LauncherAccount_v1\n'):
            self.assertTrue(toolchain.launcher_account_interface(self.c, self.exe)[0])
        # Same path/size/mtime, but a fresh probe reports no implementation.
        with self.probe('00000001 (__TEXT,__text) external _main\n') as run:
            self.assertFalse(toolchain.launcher_account_interface(self.c, self.exe)[0])
            run.assert_called_once()

    def test_descriptor_admission_preserves_capture_and_creates_no_user_state(self):
        self.c.r.update(action='create', name='Fixture Second', revision=0)
        users.update(self.c)
        self.c.r['userId'] = '02'
        with patch.object(toolchain, 'launcher_account_interface', return_value=(False, 'unsupported')):
            with self.assertRaises(Failure):
                users.admitted_session_descriptor(self.c, GID, self.exe)
        self.c.r['userId'] = '01'  # UI changes cannot retarget this captured job.
        with patch.object(toolchain, 'launcher_account_interface', return_value=(True, 'v1')) as probe:
            descriptor = users.admitted_session_descriptor(self.c, GID, self.exe)
            probe.assert_called_once_with(self.c, self.exe)
        self.assertEqual(descriptor['id'], '02')
        self.assertEqual(descriptor['stateRoot'], str(self.c.library / 'saves/users/02' / GID))
        self.assertFalse((self.c.library / 'saves').exists())

    @unittest.skipUnless(sys.platform == 'darwin' and shutil.which('cc'), 'needs macOS compiler/nm')
    def test_real_native_symbol_positive_and_negative_controls(self):
        for name, declaration, expected in (
                ('current', 'int S2A_LauncherAccount_v1(void) { return 1; }', True),
                ('managed', '__attribute__((section("__TEXT,__managedcode"))) int S2A_LauncherAccount_v1(void) { return 1; }', True),
                ('data', 'int S2A_LauncherAccount_v1 = 1;', False),
                ('legacy', 'int S2A_InitSession(void) { return 1; }', False),
                ('future', 'int S2A_LauncherAccount_v10(void) { return 1; }', False)):
            source = self.root / (name + '.c')
            executable = self.root / name
            source.write_text(declaration + '\nint main(void) { return 0; }\n')
            result = subprocess.run(['cc', str(source), '-o', str(executable)],
                                    env=self.c.env(), capture_output=True)
            self.assertEqual(result.returncode, 0, 'synthetic host compilation failed')
            self.assertEqual(toolchain.launcher_account_interface(self.c, executable)[0], expected)
