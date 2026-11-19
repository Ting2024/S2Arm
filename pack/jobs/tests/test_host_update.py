# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Host-only publication uses synthetic files; no game/profile inputs."""
import json
import sys
from pathlib import Path
from types import SimpleNamespace
from unittest import TestCase, mock
import tempfile
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from core import Failure, digest
import host_update


class HostUpdateTests(TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.c = SimpleNamespace(engine=self.root/'engine', private=self.root/'private',
                                 r={'engineBundle': 'fixture'}, check=lambda: None, emit=lambda *a, **k: None)
        self.host = self.c.engine/'Binaries/S2ArmGame.app'
        for name in ['Contents/MacOS/s2arm-host', 'Contents/MacOS/libs2a_vaguard.dylib', 'Contents/Info.plist']:
            p = self.host/name; p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes(b'synthetic')
        self.manifest = {'memoryRequirementsVersion': 2, 'runtimeHostABI': 1}
        self.write_engine(1)
        self.sig = mock.patch.object(host_update, 'verify_signature'); self.sig.start(); self.addCleanup(self.sig.stop)

    def write_engine(self, abi):
        files = {str(p.relative_to(self.c.engine)): [p.stat().st_size, digest(p)] for p in self.host.rglob('*') if p.is_file()}
        (self.c.engine/'engine.json').write_text(json.dumps(dict(runtimeHostABI=abi, files=files)))

    def test_new_host_published_and_reused_without_game_data(self):
        first = host_update.current_host(self.c, self.manifest)
        self.assertNotEqual(first, self.host)
        self.assertEqual((first/'Contents/MacOS/s2arm-host').read_bytes(), b'synthetic')
        self.assertEqual(host_update.current_host(self.c, self.manifest), first)
        self.assertFalse((self.root/'games').exists())

    def test_incompatible_host_rejected(self):
        self.write_engine(2)
        with self.assertRaises(Failure): host_update.current_host(self.c, self.manifest)

    def test_corrupt_candidate_rejected(self):
        (self.host/'Contents/MacOS/s2arm-host').write_bytes(b'corrupted')
        with self.assertRaises(Failure): host_update.current_host(self.c, self.manifest)

    def test_no_declared_contract_keeps_old_runtime(self):
        self.write_engine(None)
        self.assertIsNone(host_update.current_host(self.c, self.manifest))

    def test_development_checkout_keeps_explicit_host(self):
        self.c.r = {}
        self.assertIsNone(host_update.current_host(self.c, self.manifest))

    def test_cached_host_corruption_is_rejected(self):
        host = host_update.current_host(self.c, self.manifest)
        (host/'Contents/MacOS/s2arm-host').write_bytes(b'corrupted')
        with self.assertRaises(Failure): host_update.current_host(self.c, self.manifest)

    def test_manifest_escape_rejected_before_publication(self):
        path = self.c.engine/'engine.json'
        engine = json.loads(path.read_text())
        engine['files']['Binaries/S2ArmGame.app/../escape'] = [0, '0' * 64]
        path.write_text(json.dumps(engine))
        with self.assertRaises(Failure): host_update.current_host(self.c, self.manifest)
        self.assertFalse((self.c.private/'runtime-hosts').exists())

    def test_symlink_cache_rejected(self):
        self.c.private.mkdir()
        outside = self.root/'outside'; outside.mkdir()
        (self.c.private/'runtime-hosts').symlink_to(outside, target_is_directory=True)
        with self.assertRaises(Failure): host_update.current_host(self.c, self.manifest)
        self.assertEqual(list(outside.iterdir()), [])

    def test_directory_symlink_inside_host_is_rejected(self):
        directory = self.host/'Contents/MacOS'
        real = self.host/'Contents/real'; directory.rename(real)
        directory.symlink_to('real', target_is_directory=True)
        with self.assertRaises(Failure): host_update.current_host(self.c, self.manifest)
        self.assertFalse((self.c.private/'runtime-hosts').exists())
