# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Synthetic launch checks vs explicit complete resource verification."""
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build
from core import Failure, digest


class RuntimeVerification(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.library = Path(self.tmp.name)
        self.runtime = self.library / 'games/fixture/releases/one'
        for name in ['romfs/large.bin', 'main.patched.bin', 'addr_need.tsv',
                     'S2ArmGame.app/Contents/MacOS/s2arm-host']:
            p = self.runtime / name; p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(b'synthetic'); p.chmod(0o755)
        self.c = SimpleNamespace(library=self.library, check=lambda: None, progress=lambda *args: None)
        self.manifest = dict(schema=1, engine='S2Arm', target='macos-arm64',
                             memoryRequirementsVersion=2,
                             memoryRequirementsSha256=digest(self.runtime / 'addr_need.tsv'),
                             files=build.snapshot(self.c, self.runtime))
        (self.runtime / 'manifest.json').write_text(json.dumps(self.manifest))

    def test_launch_does_not_hash_or_stat_resource_payload(self):
        real = build.validate_files
        checked = []
        def recording(c, root, files, full=True):
            checked.extend(files); return real(c, root, files, full)
        with patch.object(build, 'validate_files', side_effect=recording):
            build.validate_runtime(self.c, self.runtime, full='launch')
        self.assertNotIn('romfs/large.bin', checked)
        self.assertIn('main.patched.bin', checked)
        self.assertIn('S2ArmGame.app/Contents/MacOS/s2arm-host', checked)

    def test_full_check_detects_resource_corruption_launch_defers_it(self):
        (self.runtime / 'romfs/large.bin').write_bytes(b'corrupted')
        build.validate_runtime(self.c, self.runtime, full='launch')
        with self.assertRaises(Failure): build.validate_runtime(self.c, self.runtime)

    def test_launch_still_rejects_modified_program(self):
        (self.runtime / 'main.patched.bin').write_bytes(b'corrupted')
        with self.assertRaises(Failure): build.validate_runtime(self.c, self.runtime, full='launch')

    def test_launch_rejects_missing_manifest(self):
        self.manifest['files'] = {}
        (self.runtime / 'manifest.json').write_text(json.dumps(self.manifest))
        with self.assertRaises(Failure): build.validate_runtime(self.c, self.runtime, full='launch')

    def test_launch_rejects_escaping_resource_entry(self):
        self.manifest['files']['romfs/../../outside'] = [9, '0' * 64]
        (self.runtime / 'manifest.json').write_text(json.dumps(self.manifest))
        with self.assertRaises(Failure): build.validate_runtime(self.c, self.runtime, full='launch')

    def test_invalid_manifest_shapes_rejected_in_all_modes(self):
        for name, entry in [(7, [0, '0' * 64]), ('romfs/C:escape', [0, '0' * 64]),
                            ('romfs/a', None), ('romfs/a', [True, '0' * 64]),
                            ('romfs/a', [0, 'not-a-digest']), ('romfs/../a', [0, '0' * 64])]:
            for mode in [True, False, 'launch']:
                with self.subTest(name=name, entry=entry, mode=mode):
                    with self.assertRaises(Failure):
                        build.validate_files(self.c, self.runtime, {name: entry}, full=mode)
