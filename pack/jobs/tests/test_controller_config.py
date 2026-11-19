# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
import copy
import unittest
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from library import validate_input
from core import Failure


class ControllerConfigTests(unittest.TestCase):
    def config(self):
        return dict(schema=1, keyboard={}, mouse={}, gamepad={}, axes={}, deadzone=.15,
                    mouseOptions=dict(mode="camera", sensitivityX=1, sensitivityY=1))

    def test_legacy_and_backends(self):
        c = self.config()
        self.assertEqual(validate_input(c), c)
        for backend in ("system", "nspro-hid", "disabled"):
            c["controller"] = dict(backend=backend, device="hid:123")
            self.assertEqual(validate_input(copy.deepcopy(c)), c)

    def test_invalid_selection(self):
        for selection in (None, [], {}, dict(backend="auto", device=""),
                          dict(backend="system", device=1), dict(backend="system", device="x" * 256),
                          dict(backend="system", device="北" * 86), dict(backend="system", device="a\0b")):
            with self.subTest(selection=selection):
                c = self.config()
                c["controller"] = selection
                with self.assertRaises(Failure):
                    validate_input(c)

    def test_four_players_and_explicit_legacy_preservation(self):
        c = self.config()
        c['players'] = {str(i): dict(backend='auto', device='') for i in range(1, 5)}
        self.assertEqual(validate_input(copy.deepcopy(c)), c)
        for backend in ('auto', 'system', 'nspro-hid', 'disabled'):
            c['players']['4'] = dict(backend=backend, device='device:four')
            self.assertEqual(validate_input(copy.deepcopy(c)), c)
        c['controller'] = dict(backend='system', device='')
        with self.assertRaises(Failure):
            validate_input(c)  # Never silently choose between two conflicting layouts.

    def test_native_type_choices_and_validation(self):
        for kind in range(5):
            selection = dict(backend='nspro-hid' if kind == 4 else 'system',device='',type=kind)
            c = self.config() | dict(players={str(i): dict(selection) for i in range(1,5)})
            self.assertEqual(validate_input(c), c)
        for kind in (-1, 5, True, '4', 1.5):
            c['players']['2']['type'] = kind
            with self.subTest(kind=kind), self.assertRaises(Failure): validate_input(c)
        c['players']['2'] = dict(backend='system', device='', type=4)
        with self.assertRaises(Failure): validate_input(c)

    def test_mac_sources_match_native_supported_slots(self):
        for slot in range(1, 5):
            for source in (-1, 0, 1, 2, 3, 4, 5, 6, True, '1'):
                c = self.config() | dict(players={str(i): dict(backend='system', device='') for i in range(1,5)})
                c['players'][str(slot)]['source'] = source
                with self.subTest(slot=slot, source=source):
                    if type(source) is int and source in ((0, 1, 2, 3, 5) if slot == 1 else (0, 1, 2, 5)):
                        self.assertEqual(validate_input(c), c)
                    else:
                        with self.assertRaises(Failure): validate_input(c)

    def test_invalid_player_tables(self):
        valid = {str(i): dict(backend='auto', device='') for i in range(1, 5)}
        invalid = [None, [], {}, {str(i): valid['1'] for i in range(1, 4)},
                   valid | {'5': valid['1']}, valid | {'01': valid['1']}]
        for slot in (None, [], {}, dict(backend='unknown', device=''),
                     dict(backend='auto', device=1), dict(backend='auto', device='a\0b'),
                     dict(backend='auto', device='北' * 86),
                     dict(backend='auto', device='', surprise=True)):
            invalid.append(valid | {'3': slot})
        for players in invalid:
            with self.subTest(players=players), self.assertRaises(Failure):
                validate_input(self.config() | dict(players=players))

from jobcase import JobCase
import plistlib
from library import _sync_mng_players
from library import _mng_input_root as mng_input_root


class ControllerPersistenceTests(JobCase):
    def test_hid_type_roundtrip_preserves_each_existing_layout(self):
        gid = '0100000000000000'
        root = mng_input_root(self.c, gid)
        root.mkdir(parents=True)
        ports = [dict(type=i, layout=f'south = a # player {i+1}\n') for i in range(4)]
        (root/'controller-slots.plist').write_bytes(plistlib.dumps(dict(version=1, ports=ports)))
        config = dict(players={str(i): dict(backend='nspro-hid' if i > 1 else 'system', device='') for i in range(1,5)})
        _sync_mng_players(self.c, gid, config)
        saved = plistlib.loads((root/'controller-slots.plist').read_bytes())['ports']
        self.assertEqual([p['type'] for p in saved], [0,4,4,4])
        self.assertEqual([p['layout'] for p in saved], [p['layout'] for p in ports])
        config['players']['3']['backend'] = 'system'
        _sync_mng_players(self.c, gid, config)
        self.assertEqual([p['type'] for p in plistlib.loads((root/'controller-slots.plist').read_bytes())['ports']], [0,4,0,4])

    def test_first_hid_save_creates_native_slot_file(self):
        gid = '0100000000000000'
        config = dict(players={str(i):dict(backend='nspro-hid',device='') for i in range(1,5)})
        _sync_mng_players(self.c,gid,config)
        root=mng_input_root(self.c,gid)
        self.assertEqual([p['type'] for p in plistlib.loads((root/'controller-slots.plist').read_bytes())['ports']],[4]*4)

    def test_invalid_slots_do_not_destroy_layout_or_sources(self):
        gid='0100000000000000';root=mng_input_root(self.c,gid);root.mkdir(parents=True)
        path=root/'controller-slots.plist';path.write_bytes(b'broken preferences')
        config=dict(players={str(i):dict(backend='nspro-hid',device='') for i in range(1,5)})
        with self.assertRaises(Failure): _sync_mng_players(self.c,gid,config)
        self.assertEqual(path.read_bytes(),b'broken preferences')
        self.assertFalse((root/'input-sources.plist').exists())

    def test_type_only_edit_preserves_sources_and_disabled_binding(self):
        gid = '0100000000000000'; root = mng_input_root(self.c, gid); root.mkdir(parents=True)
        sources = [3, 2, 0, 5]
        (root/'input-sources.plist').write_bytes(plistlib.dumps(dict(version=1, sources=sources)))
        config = dict(players={str(i):dict(backend='system', device='', type=2) for i in range(1,5)})
        _sync_mng_players(self.c, gid, config)
        self.assertEqual(plistlib.loads((root/'input-sources.plist').read_bytes())['sources'], sources)

    def test_explicit_source_and_binding_are_independent(self):
        gid = '0100000000000000'
        token = 'session:12345678-1234-1234-1234-123456789ABC'
        sources = [3, 2, 1, 5]
        config = dict(players={str(i):dict(backend='system', device=token if i == 4 else '', source=sources[i-1], type=2) for i in range(1,5)})
        _sync_mng_players(self.c, gid, config)
        root = mng_input_root(self.c, gid)
        self.assertEqual(plistlib.loads((root/'input-sources.plist').read_bytes())['sources'], sources)
        self.assertEqual(plistlib.loads((root/'controller-devices.plist').read_bytes())['ports'][3]['id'], token)

    def test_incompatible_and_duplicate_devices_fail_before_any_write(self):
        gid = '0100000000000000'
        for device in ('gc:Pro:Vendor', 'hid:123', 'session:bad', 'session:12345678-1234-1234-1234-123456789ABC'):
            config = dict(players={str(i):dict(backend='system', device=device) for i in range(1,5)})
            with self.subTest(device=device), self.assertRaises(Failure): _sync_mng_players(self.c, gid, config)
            self.assertFalse((mng_input_root(self.c, gid)/'controller-slots.plist').exists())

    def test_malformed_source_or_device_file_is_not_overwritten(self):
        gid = '0100000000000000'; root = mng_input_root(self.c, gid); root.mkdir(parents=True)
        config = dict(players={str(i):dict(backend='system', device='') for i in range(1,5)})
        for name in ('input-sources.plist', 'controller-devices.plist'):
            path = root/name; path.write_bytes(b'broken preferences')
            with self.subTest(name=name), self.assertRaises(Failure): _sync_mng_players(self.c, gid, config)
            self.assertEqual(path.read_bytes(), b'broken preferences')
            self.assertFalse((root/'controller-slots.plist').exists())
            path.unlink()

    def test_native_owner_lock_blocks_save_without_writes(self):
        from library import _mng_input_lock
        gid = '0100000000000000'
        config = dict(players={str(i):dict(backend='system', device='') for i in range(1,5)})
        with _mng_input_lock(self.c, gid) as root:
            with self.assertRaises(Failure): _sync_mng_players(self.c, gid, config)
            self.assertFalse((root/'controller-slots.plist').exists())
        _sync_mng_players(self.c, gid, config)
        self.assertTrue((root/'controller-slots.plist').exists())

    def test_save_input_persists_json_and_native_sources_under_same_lock(self):
        from library import save_input, _mng_input_lock
        import layout as _layout
        def input_path(c, gid): return _layout.path(c, gid, 'input.json')
        from unittest.mock import patch
        import json
        gid = '0100000000000000'
        sources = [3, 2, 1, 5]
        config = ControllerConfigTests().config() | dict(players={str(i):dict(
            backend='system', device='', type=i-1, source=sources[i-1]) for i in range(1,5)})
        self.c.r.update(gameId=gid, config=config)
        with patch.object(self.c, 'game'):
            save_input(self.c)
            path = input_path(self.c, gid)
            self.assertEqual(json.loads(path.read_text()), config)
            root = mng_input_root(self.c, gid)
            self.assertEqual(plistlib.loads((root/'input-sources.plist').read_bytes())['sources'], sources)
            before = path.read_bytes()
            with _mng_input_lock(self.c, gid):
                self.c.r['config']['players']['2']['type'] = 3
                with self.assertRaises(Failure): save_input(self.c)
            self.assertEqual(path.read_bytes(), before)

    def test_stale_panel_revision_rejects_all_changes_before_write(self):
        from library import save_input, _input_revision
        import layout as _layout
        def input_path(c, gid): return _layout.path(c, gid, 'input.json')
        from unittest.mock import patch
        gid = '0100000000000000'
        config = ControllerConfigTests().config() | dict(players={str(i):dict(
            backend='system', device='', type=0, source=1) for i in range(1,5)})
        self.c.r.update(gameId=gid, config=config)
        with patch.object(self.c, 'game'):
            save_input(self.c)
            target = input_path(self.c, gid); root = mng_input_root(self.c, gid)
            revision = _input_revision(self.c, target, root)
            self.c.r['inputRevision'] = revision
            # A fresh save is allowed; capture the new snapshot afterwards.
            save_input(self.c)
            revision = _input_revision(self.c, target, root)
            for changed in (root/'controller-slots.plist', root/'input-sources.plist',
                            root/'keyboard-slots.plist', target, self.c.private/'default-input.json'):
                original = changed.read_bytes() if changed.exists() else None
                changed.write_bytes((original or b'') + b'\n')
                before = {p: p.read_bytes() for p in (target, *root.glob('*.plist'))}
                self.c.r['inputRevision'] = revision
                with self.subTest(changed=changed.name), self.assertRaisesRegex(Failure, '重新打开'):
                    save_input(self.c)
                self.assertEqual({p: p.read_bytes() for p in before}, before)
                if original is None: changed.unlink()
                else: changed.write_bytes(original)
            self.c.r['inputRevision'] = dict(revision, **{'../escape': 'missing'})
            with self.assertRaises(Failure): save_input(self.c)

    def test_save_input_from_secondary_player_tab_syncs_mng_players(self):
        from library import save_input
        import layout as _layout
        def input_path(c, gid): return _layout.path(c, gid, 'input.json')
        import layout
        from unittest.mock import patch
        import json
        gid = '0100000000000000'
        legacy_p1 = ControllerConfigTests().config() | dict(controller=dict(backend='nspro-hid', device=''))
        self.c.r.update(gameId=gid, player=1, config=legacy_p1)
        with patch.object(self.c, 'game'):
            save_input(self.c)
            p2_config = ControllerConfigTests().config() | dict(players={str(i): dict(
                backend='nspro-hid' if i <= 2 else 'disabled',
                device='' if i <= 2 else 'none',
                type=4 if i <= 2 else 0,
                source=1 if i <= 2 else 5) for i in range(1, 5)})
            self.c.r.update(gameId=gid, player=2, config=p2_config)
            save_input(self.c)
            root = mng_input_root(self.c, gid)
            self.assertEqual([p['type'] for p in plistlib.loads((root/'controller-slots.plist').read_bytes())['ports']], [4, 4, 0, 0])
            self.assertEqual(plistlib.loads((root/'input-sources.plist').read_bytes())['sources'], [1, 1, 5, 5])
            for p1_path in (layout.path(self.c, gid, 'input.json'),):
                saved_p1 = json.loads(p1_path.read_text())
                self.assertNotIn('controller', saved_p1)
                self.assertEqual(saved_p1['players'], p2_config['players'])

