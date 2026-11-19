"""Host overlay admission and closure integrity; synthetic files only."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
from pack import ios_host


class HostOverlay(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.host = self.root/'host'; (self.host/'root').mkdir(parents=True)
        (self.host/'root/S2Arm').write_bytes(b'new-host')
        self.doc = dict(schema=1, files={'S2Arm': [8, hashlib.sha256(b'new-host').hexdigest()]},
                        compatibleShellIds=['legacy-shell'], replaces=[])
        self.seal()
        self.app = self.root/'App'; self.app.mkdir()
        (self.app/'S2Arm').write_bytes(b'old-host')
        (self.app/'Games').mkdir(); (self.app/'Games/module').write_bytes(b'game')

    def seal(self):
        body = {k:v for k,v in self.doc.items() if k != 'id'}
        self.doc['id'] = hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()
        (self.host/'host.json').write_text(json.dumps(self.doc))

    def test_compatible_host_only_update(self):
        ios_host.apply(self.host, self.app, 'legacy-shell')
        self.assertEqual((self.app/'S2Arm').read_bytes(), b'new-host')
        self.assertEqual((self.app/'Games/module').read_bytes(), b'game')
        self.assertFalse((self.app/'Documents').exists())

    def test_incompatible_host_leaves_app_untouched(self):
        with self.assertRaises(ValueError): ios_host.apply(self.host, self.app, 'unknown-shell')
        self.assertEqual((self.app/'S2Arm').read_bytes(), b'old-host')

    def test_corruption_rejected_before_copy(self):
        (self.host/'root/S2Arm').write_bytes(b'bad-host')
        with self.assertRaises(ValueError): ios_host.apply(self.host, self.app, 'legacy-shell')
        self.assertEqual((self.app/'S2Arm').read_bytes(), b'old-host')

    def test_game_module_overlay_forbidden(self):
        self.doc['files']['Frameworks/S2AImages-test.dylib'] = [0, '0'*64]; self.seal()
        with self.assertRaises(ValueError): ios_host.load(self.host)

    def test_path_escape_rejected(self):
        self.doc['files']['../outside'] = [0, '0'*64]; self.seal()
        with self.assertRaises(ValueError): ios_host.load(self.host)

    def test_symlink_source_rejected(self):
        (self.host/'root/S2Arm').unlink()
        (self.host/'root/S2Arm').symlink_to(self.app/'S2Arm')
        with self.assertRaises(ValueError): ios_host.load(self.host)

    def test_candidate_bytes_checked_not_just_host_metadata(self):
        ios_host.apply(self.host, self.app, 'legacy-shell')
        ios_host.verify_app(self.host, self.app, 'legacy-shell')
        (self.app/'S2Arm').write_bytes(b'old-host')
        with self.assertRaises(ValueError):
            ios_host.verify_app(self.host, self.app, 'legacy-shell')

    def test_destination_link_rejected_before_copy(self):
        (self.app/'S2Arm').unlink()
        target = self.root/'outside'; target.write_bytes(b'untouched')
        (self.app/'S2Arm').symlink_to(target)
        with self.assertRaises(ValueError): ios_host.apply(self.host, self.app, 'legacy-shell')
        self.assertEqual(target.read_bytes(), b'untouched')

    def test_modified_compatibility_declaration_rejected(self):
        self.doc['compatibleShellIds'].append('unknown-shell')
        (self.host/'host.json').write_text(json.dumps(self.doc))
        with self.assertRaises(ValueError): ios_host.load(self.host)


if __name__ == '__main__': unittest.main()
