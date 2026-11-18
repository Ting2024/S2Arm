# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Opt-in installed bundle smoke test; no games, user profiles or UI launch.

S2A_TEST_INSTALLED_APP selects the candidate/installed bundle. Test the real
isolated Python entry point, not source imports, to catch partial Jobs updates.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


@unittest.skipUnless(os.environ.get('S2A_TEST_INSTALLED_APP'), 'explicit candidate app required')
class InstalledWorker(unittest.TestCase):
    def test_packaged_worker_completes_read_only_probe(self):
        resources = Path(os.environ['S2A_TEST_INSTALLED_APP'])/'Contents/Resources'
        with tempfile.TemporaryDirectory(prefix='s2arm-worker-smoke-') as td:
            root = Path(td)
            request = root/'request.json'
            request.write_text(json.dumps(dict(schema=1, taskId='packaged-smoke', operation='preflight',
                privateRoot=str(root/'private'), resources=str(resources), engineBundle=str(resources/'Engine'))))
            request.chmod(0o600)
            run = subprocess.run([resources/'Runtime/python/bin/python3', '-B', '-I', resources/'Jobs/main.py',
                                  'run', '--request', request], capture_output=True, text=True, timeout=180)
            self.assertEqual(run.returncode, 0, 'Packaged worker failed (inspect locally; do not print private logs)')
            events = [json.loads(line) for line in run.stdout.splitlines() if line.startswith('{')]
            self.assertTrue(events)
            self.assertEqual(events[-1].get('state'), 'succeeded')
            self.assertNotIn('AttributeError', run.stderr)
            self.assertTrue(any('check' in event for event in events))

    def test_packaged_user_registry_without_game_library(self):
        resources = Path(os.environ['S2A_TEST_INSTALLED_APP'])/'Contents/Resources'
        with tempfile.TemporaryDirectory(prefix='s2arm-worker-users-') as td:
            root = Path(td)
            for index, (operation, extra) in enumerate([
                    ('users', {}),
                    ('userUpdate', dict(action='create', name='Fixture 2', revision=0)),
                    ('users', {})]):
                request = root/'request.json'
                request.write_text(json.dumps(dict(schema=1, taskId=f'users-{index}', operation=operation,
                    privateRoot=str(root/'private'), resources=str(resources), **extra)))
                request.chmod(0o600)
                run = subprocess.run([resources/'Runtime/python/bin/python3', '-B', '-I', resources/'Jobs/main.py',
                    'run', '--request', request], capture_output=True, text=True, timeout=30)
                self.assertEqual(run.returncode, 0, 'Packaged user worker failed; inspect private log locally')
                events = [json.loads(line) for line in run.stdout.splitlines() if line.startswith('{')]
                self.assertEqual(events[-1].get('state'), 'succeeded')
                result = events[-1]['result']
                self.assertEqual(result['users'][0]['id'], '01')
                self.assertIsNone(result['users'][0]['accountUid'])
                if index:
                    self.assertEqual(result['users'][1]['id'], '02')
                    self.assertEqual(result['revision'], 1)
            self.assertFalse((root/'private/unconfigured').exists())
