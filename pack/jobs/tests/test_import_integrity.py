"""Import integrity errors through the real worker; synthetic content only."""
import json
from jobcase import JobCase


class ImportIntegrityTests(JobCase):
    def test_hash_failure_preserves_specific_diagnostic_and_private_data(self):
        self.import_keys()
        self.install_reader_fixture()
        keys = self.c.keys.read_bytes()
        source = self.root / "source.nsp"
        source.write_bytes(b"hash mismatch fixture")
        save = self.c.library / "saves/keep"
        save.parent.mkdir()
        save.write_bytes(b"independent synthetic progress")
        result, failed = self.worker("import", paths=[str(source)])
        self.assertEqual(result.returncode, 1)
        diagnostic = self.assert_failure(failed, "hash_mismatch")
        self.assertEqual(diagnostic["exitCode"], 3)
        self.assertEqual([d["code"] for d in failed["diagnostics"]], ["hash_mismatch"])
        self.assertIn("哈希", diagnostic["summary"])
        self.assertNotIn("玩家密钥", diagnostic["suggestion"])
        self.assertNotIn("synthetic-bearer", json.dumps(failed))
        self.assertEqual(self.c.keys.read_bytes(), keys)
        self.assertEqual(save.read_bytes(), b"independent synthetic progress")
        self.assertEqual(source.read_bytes(), b"hash mismatch fixture")
        source.write_bytes(b"corrected fixture")
        result, fixed = self.worker("import", paths=[str(source)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(fixed["diagnostics"], [])
