# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁手动：要预构建的 build/devpush/release/s2a-devpush（cargo --release 产物），门禁默认不跑 Rust release 编译；推包续传协议层已由 tests/push_pack_test.sh 覆盖
"""Exercise the real local resume transport; never access a device."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class ResumeArchive(unittest.TestCase):
    def setUp(self):
        self.exe = Path(os.environ.get('S2A_TEST_DEVPUSH', 'build/devpush/release/s2a-devpush')).resolve()
        if not self.exe.is_file(): self.skipTest('build s2a-devpush first')
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name, data in [('empty', b''), ('中文 name', b'abcdefgh' * 200001)]:
            (self.root/name).write_bytes(data)
        self.lst = self.root/'files'; self.lst.write_text('empty\n中文 name\n')
        self.complete = self.root/'complete.tar'
        self.run_op('tar-local', self.complete)
        self.expected = self.complete.read_bytes()
        self.partial = self.root/'partial.tar'

    def run_op(self, op, path, check=True):
        return subprocess.run([self.exe, '-', '-', op, self.lst, self.root, path],
                              capture_output=True, check=check, timeout=30)

    def test_resume_at_headers_payload_padding_and_tail(self):
        for size in [0, 1, 511, 512, 1537, 1048593, len(self.expected)-1, len(self.expected)]:
            with self.subTest(size=size):
                self.partial.write_bytes(self.expected[:size])
                inode = self.partial.stat().st_ino
                result = self.run_op('resume-tar-local', self.partial)
                self.assertEqual(self.partial.read_bytes(), self.expected)
                self.assertEqual(self.partial.stat().st_ino, inode)
                self.assertIn(f'S2A_RESUME_BYTES {size}'.encode(), result.stderr)

    def test_same_length_corruption_is_not_overwritten(self):
        for size in [512, len(self.expected)]:
            bad = b'X' + self.expected[1:size]
            self.partial.write_bytes(bad)
            result = self.run_op('resume-tar-local', self.partial, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.partial.read_bytes(), bad)

    def test_excess_bytes_rejected_without_truncation(self):
        bad = self.expected + b'extra'
        self.partial.write_bytes(bad)
        result = self.run_op('resume-tar-local', self.partial, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.partial.read_bytes(), bad)

    def test_repeated_resume_does_not_grow_archive(self):
        self.partial.write_bytes(self.expected[:781])
        for _ in range(3): self.run_op('resume-tar-local', self.partial)
        self.assertEqual(self.partial.read_bytes(), self.expected)
        self.assertEqual(sorted(p.name for p in self.root.glob('partial*')), ['partial.tar'])


if __name__ == '__main__': unittest.main()
