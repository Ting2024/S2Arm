# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""No game, network or device access: resolve actual frontend build inputs."""
from pathlib import Path
import ast
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[3]

class MacLanWiringTests(unittest.TestCase):
    def test_frontend_links_discovery_and_mac_permission_adapter(self):
        script = 'S2A_MAC_FRONTEND=1\ninclude launchers/macos/build.mk\nprobe:\n\t@echo $(HOST_SRCS)\n'
        result = subprocess.run(['make', '-s', '-f', '-', 'probe'], cwd=ROOT,
                                input=script, text=True, capture_output=True, check=True)
        sources = result.stdout.split()
        self.assertIn('ios/ldn_lan.m', sources)
        self.assertIn('macos/lan_permission.m', sources)
        self.assertNotIn('ios/lan_permission.m', sources)

    def test_non_frontend_does_not_start_bonjour_without_run_loop(self):
        script = 'include launchers/macos/build.mk\nprobe:\n\t@echo $(HOST_SRCS)\n'
        result = subprocess.run(['make', '-s', '-f', '-', 'probe'], cwd=ROOT,
                                input=script, text=True, capture_output=True, check=True)
        self.assertNotIn('ios/ldn_lan.m', result.stdout.split())

    def test_responsible_launcher_declares_same_bonjour_service(self):
        tree = ast.parse((ROOT / 'launchers/macos/build_app.py').read_text())
        info = {}
        for node in ast.walk(tree):
            if not isinstance(node, ast.Assign):
                continue
            for target in node.targets:
                if (isinstance(target, ast.Subscript) and isinstance(target.value, ast.Name)
                        and target.value.id == 'info' and isinstance(target.slice, ast.Constant)
                        and target.slice.value in ('NSLocalNetworkUsageDescription', 'NSBonjourServices')):
                    info[target.slice.value] = ast.literal_eval(node.value)
        self.assertTrue(info.get('NSLocalNetworkUsageDescription'))
        self.assertEqual(info.get('NSBonjourServices'), ['_s2arm-ldn._tcp'])
