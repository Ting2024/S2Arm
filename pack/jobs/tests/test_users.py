"""User registry contracts: only synthetic private directories, no profiles/hardware."""
import copy
import json
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from jobcase import JobCase
from core import Context, Failure, atomic
import users
import build
import saves

GID = '0100000000000000'


class UsersTests(JobCase):
    def context(self, **extra):
        return SimpleNamespace(private=self.c.private, library=self.c.library,
                               r=extra, check=lambda: None)

    def create(self, name='用户2', revision=0):
        return users.update(self.context(action='create', name=name, revision=revision))

    def test_default_is_read_only_and_preserves_all_legacy_paths(self):
        c = self.context()
        value = users.listing(c)
        self.assertEqual(value, dict(schema=1, revision=0, nextId=2,
                                    users=[dict(id='01', name='用户1', accountUid=None)]))
        self.assertFalse((c.private / 'users.json').exists())
        paths = users.paths(c, GID)
        for key, folder in [('save', 'saves'), ('cache', 'runtime-cache'), ('docs', 'temp'),
                            ('backups', 'save-backups'), ('imports', 'save-imports')]:
            self.assertEqual(paths[key], c.library / folder / GID)
            self.assertFalse(paths[key].exists())
        self.assertEqual(paths['transactions'], c.library / 'save-transactions')

    def test_incremental_ids_stable_uids_and_shared_across_libraries(self):
        document = self.create()
        uid = document['users'][1]['accountUid']
        self.assertRegex(uid, '^[a-f0-9]{32}$')
        self.assertNotEqual(uid, users.LEGACY_UID)
        second = self.context(action='create', name='用户3', revision=1)
        second.library = self.root / 'other-library'
        document = users.update(second)
        self.assertEqual([u['id'] for u in document['users']], ['01', '02', '03'])
        self.assertEqual(document['nextId'], 4)
        self.assertEqual(document['users'][1]['accountUid'], uid)
        self.assertNotEqual(document['users'][2]['accountUid'], uid)
        self.assertFalse(second.library.exists())

    def test_rename_preserves_identity_and_captured_job_selection(self):
        self.create()
        c = self.context(userId='02')
        selected = users.selected(c)
        result = users.update(self.context(action='rename', userId='02', name='Second', revision=1))
        self.assertEqual(result['users'][1]['accountUid'], selected['accountUid'])
        self.assertEqual(users.selected(c), selected)
        c.r['userId'] = '01'
        self.assertEqual(users.selected(c)['id'], '02')
        selected['name'] = 'mutated-copy'
        self.assertEqual(users.selected(c)['name'], '用户2')
        self.assertEqual(users.selected(self.context(userId='02'))['name'], 'Second')

    def test_each_user_has_disjoint_mutable_paths(self):
        self.create()
        a, b = users.paths(self.context(), GID), users.paths(self.context(userId='02'), GID)
        self.assertEqual(set(a), {'save', 'cache', 'docs', 'backups', 'imports', 'transactions'})
        self.assertTrue(set(a.values()).isdisjoint(b.values()))
        for key, path in b.items():
            self.assertIn('users/02', path.as_posix())
            self.assertFalse(path.exists())
        other_game = users.paths(self.context(userId='02'), '0200000000000000')
        self.assertNotEqual(b['save'], other_game['save'])
        self.assertEqual(b['transactions'], other_game['transactions'])

    def test_runtime_output_plans_are_disjoint_and_read_only(self):
        self.create()
        first = self.context(userId='01')
        second = self.context(userId='02')
        one, two = users.runtime_paths(first, GID), users.runtime_paths(second, GID)
        expected = {'S2A_RYU_DATA', 'S2A_DOCS', 'NXGAL_SHADER_CACHE_DIR', 'NXGAL_PSO_DEV_DIR',
                    'S2A_MACRO_DUMP', 'DM_PSO_USER', 'S2A_SHCOLLECT', 'GAL_AIR_CACHE',
                    'GAL_PSO_CACHE', 'S2A_SCHED_DIR', 'TMPDIR', 'S2A_WIDEN_FLAT_CACHE'}
        self.assertEqual(set(one), expected)
        self.assertEqual(set(two), expected)
        self.assertTrue(set(one.values()).isdisjoint(two.values()))
        for values in (one, two):
            for path in values.values():
                self.assertTrue(path.is_relative_to(self.c.library))
                self.assertFalse(path.exists())
        self.assertEqual(one['S2A_RYU_DATA'], self.c.library / 'saves' / GID)
        self.assertEqual(one['S2A_DOCS'], self.c.library / 'temp' / GID)
        self.assertEqual(two['DM_PSO_USER'], self.c.library / 'runtime-cache/users/02' / GID / 'direct/pso_user.tsv')
        self.assertNotIn('S2A_RUN_ROOT', two)  # Shared GPU scheduling must not be bypassed.
        self.assertNotIn('HOME', two)
        self.assertEqual(two['S2A_WIDEN_FLAT_CACHE'], two['DM_PSO_USER'].with_name('widen_flat3.tsv'))
        second.r['userId'] = '01'
        self.assertEqual(users.runtime_paths(second, GID), two)

    def test_runtime_nested_output_links_rejected_without_writing_outside(self):
        self.create()
        c = self.context(userId='02')
        cache = users.paths(c, GID)['cache']
        cache.mkdir(parents=True)
        outside = self.root / 'outside'; outside.mkdir()
        (cache / 'direct').symlink_to(outside, target_is_directory=True)
        with self.assertRaises(Failure):
            users.runtime_paths(c, GID)
        self.assertEqual(list(outside.iterdir()), [])

    def test_runtime_cache_file_leaves_reject_links_and_directories(self):
        self.create()
        c = self.context(userId='02')
        outputs = users.runtime_paths(c, GID)
        outside = self.root / 'independent-cache'
        outside.write_bytes(b'unchanged')
        for key in ('DM_PSO_USER', 'S2A_WIDEN_FLAT_CACHE'):
            leaf = outputs[key]
            leaf.parent.mkdir(parents=True, exist_ok=True)
            for kind in ('symlink', 'hardlink', 'directory'):
                with self.subTest(key=key, kind=kind):
                    if kind == 'symlink':
                        leaf.symlink_to(outside)
                    elif kind == 'hardlink':
                        leaf.hardlink_to(outside)
                    else:
                        leaf.mkdir()
                    with self.assertRaises(Failure):
                        users.runtime_paths(c, GID)
                    self.assertEqual(outside.read_bytes(), b'unchanged')
                    leaf.rmdir() if kind == 'directory' else leaf.unlink()
            leaf.write_bytes(b'private')
            self.assertEqual(users.runtime_paths(c, GID)[key], leaf)

    def test_input_mapping_paths_capture_user_and_preserve_legacy(self):
        self.create()
        first, second = self.context(userId='01'), self.context(userId='02')
        legacy = users.input_path(first, GID)
        scoped = users.input_path(second, GID)
        self.assertEqual(legacy, self.c.library / 'mappings' / (GID + '.json'))
        self.assertEqual(scoped, self.c.library / 'mappings/users/02' / (GID + '.json'))
        self.assertFalse(legacy.exists())
        self.assertFalse(scoped.exists())
        second.r['userId'] = '01'
        self.assertEqual(users.input_path(second, GID), scoped)
        first.private = second.private = self.c.private
        atomic(legacy, {'marker': 'legacy'})
        self.assertIsNone(build.launch_input(second, {'id': GID}))
        atomic(scoped, {'marker': 'second'})
        self.assertEqual(build.launch_input(second, {'id': GID}), {'marker': 'second'})
        self.assertEqual(build.launch_input(first, {'id': GID}), {'marker': 'legacy'})
        scoped.unlink()
        scoped.symlink_to(legacy)
        with self.assertRaises(Failure):
            build.launch_input(second, {'id': GID})
        with self.assertRaises(Failure):
            users.input_path(self.context(userId='03'), GID)

    def test_mng_input_roots_are_scoped_per_user_and_reject_unsafe_leaves(self):
        self.create()
        first, second = self.context(userId='01'), self.context(userId='02')
        one, two = users.mng_input_root(first, GID), users.mng_input_root(second, GID)
        self.assertEqual(one, self.c.library / 'mappings/mng' / GID)
        self.assertEqual(two, self.c.library / 'mappings/users/02/mng' / GID)
        self.assertFalse(one.exists())
        self.assertFalse(two.exists())
        second.r['userId'] = '01'
        self.assertEqual(users.mng_input_root(second, GID), two)
        two.mkdir(parents=True)
        outside = self.root / 'outside-input.txt'
        outside.write_bytes(b'unchanged')
        leaf = two / 'controls.txt'
        for kind in ('symlink', 'hardlink', 'directory'):
            with self.subTest(kind=kind):
                if kind == 'symlink':
                    leaf.symlink_to(outside)
                elif kind == 'hardlink':
                    leaf.hardlink_to(outside)
                else:
                    leaf.mkdir()
                with self.assertRaises(Failure):
                    users.mng_input_root(second, GID)
                leaf.rmdir() if kind == 'directory' else leaf.unlink()
        leaf.write_bytes(b'ok')
        self.assertEqual(users.mng_input_root(second, GID), two)

    def test_stale_write_and_unsupported_delete_preserve_registry(self):
        self.create()
        path = self.c.private / 'users.json'
        before = path.read_bytes()
        for request in [dict(action='create', name='Third', revision=0),
                        dict(action='delete', userId='02', name='Second', revision=1),
                        dict(action='rename', userId='03', name='Missing', revision=1),
                        dict(action='create', name='Third', revision=True)]:
            with self.subTest(request=request), self.assertRaises(Failure):
                users.update(self.context(**request))
            self.assertEqual(path.read_bytes(), before)

    def test_corruption_never_resets_registry(self):
        path = self.c.private / 'users.json'
        malformed = [b'{', b'{"schema":1,"schema":1}', b'null', b'x' * (users.MAX_BYTES + 1)]
        for content in malformed:
            path.write_bytes(content)
            with self.assertRaises(Failure):
                self.create()
            self.assertEqual(path.read_bytes(), content)
        document = users.default_registry()
        for change in [dict(nextId=True), dict(nextId=1), dict(revision=True), dict(schema=True),
                       dict(users=[]), dict(extra='unexpected')]:
            atomic(path, document | change)
            with self.assertRaises(Failure):
                users.load(self.context())

    def test_duplicate_ids_uids_and_legacy_uid_assignment_rejected(self):
        document = self.create()
        mutations = []
        value = copy.deepcopy(document); value['users'].append(value['users'][1].copy()); mutations.append(value)
        value = copy.deepcopy(document); value['users'][0]['accountUid'] = 'f' * 32; mutations.append(value)
        value = copy.deepcopy(document); value['users'][1]['accountUid'] = users.LEGACY_UID; mutations.append(value)
        value = copy.deepcopy(document); value['users'][1]['id'] = '../02'; mutations.append(value)
        value = copy.deepcopy(document); value['users'][1]['accountUid'] = '0' * 32; mutations.append(value)
        for value in mutations:
            atomic(self.c.private / 'users.json', value)
            with self.assertRaises(Failure):
                users.load(self.context())

    def test_names_validate_utf8_bytes_and_controls(self):
        for value in ['', ' x', 'x ', '\n', 'a\x00b', '\x7f', '\x85', '你' * 11, '\ud800', 2, None]:
            with self.subTest(value=value), self.assertRaises(Failure):
                users.user_name(value)
        self.assertEqual(users.user_name('你' * 10), '你' * 10)
        self.assertEqual(users.user_name('x' * 32), 'x' * 32)

    def test_invalid_or_missing_selection_fails_closed(self):
        for ident in ['00', '1', 1, None, '../01', '001', '02', '1000000']:
            with self.subTest(ident=ident), self.assertRaises(Failure):
                users.selected(self.context(userId=ident))
        for gid in ['', '../game', 'g' * 16, None]:
            with self.assertRaises(Failure):
                users.paths(self.context(), gid)

    def test_links_cannot_redirect_registry_or_mutable_game_paths(self):
        outside = self.root / 'outside'; outside.mkdir()
        (self.c.private / 'users.json').symlink_to(outside / 'registry')
        with self.assertRaises(Failure):
            self.create()
        (self.c.private / 'users.json').unlink()
        (self.c.private / '.users.lock').unlink(missing_ok=True)
        (self.c.private / '.users.lock').symlink_to(outside / 'lock')
        with self.assertRaises(Failure):
            self.create()
        (self.c.private / '.users.lock').unlink()
        (self.c.library / 'saves').mkdir(exist_ok=True)
        (self.c.library / 'saves' / GID).symlink_to(outside, target_is_directory=True)
        with self.assertRaises(Failure):
            users.paths(self.context(), GID)
        self.assertEqual(list(outside.iterdir()), [])

    def test_lock_blocks_second_writer_and_releases_on_error(self):
        with users.registry_lock(self.context()):
            with self.assertRaises(Failure):
                self.create()
        self.assertEqual(self.create()['revision'], 1)

    def test_new_user_launch_and_save_calls_do_not_fall_back_to_legacy(self):
        self.create()
        c = self.context(userId='02')
        with self.assertRaises(Failure):
            build.runtime_env(c, dict(id=GID), self.root / 'runtime')
        root, _, _ = saves.locations(c, dict(id=GID))
        self.assertEqual(root, self.c.library / 'saves/users/02' / GID)
        self.assertFalse((self.c.library / 'saves' / 'users').exists())

    def test_real_worker_users_needs_no_library_or_engine(self):
        for operation, extra in [('users', {}), ('userUpdate', dict(action='create', name='用户2', revision=0))]:
            process, event = self.worker(operation, library='', libraryId='', engineDir=str(self.root / 'absent-engine'), **extra)
            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertEqual(event['state'], 'succeeded')
            self.assertEqual(event['result']['users'][0]['id'], '01')
        self.assertEqual(users.listing(self.context())['users'][1]['id'], '02')
        self.assertFalse((self.c.private / 'unconfigured').exists())

    def test_session_descriptor_binds_identity_to_exact_save_root(self):
        document = self.create()
        c = self.context(userId='02')
        descriptor = users.session_descriptor(c, GID)
        self.assertEqual(descriptor, dict(schema=1, id='02', name='用户2',
            accountUid=document['users'][1]['accountUid'],
            stateRoot=str(c.library / 'saves/users/02' / GID)))
        self.assertFalse(Path(descriptor['stateRoot']).exists())
        users.update(self.context(action='rename', userId='02', name='Changed', revision=1))
        self.assertEqual(users.session_descriptor(c, GID), descriptor)
        legacy = users.session_descriptor(self.context(), GID)
        self.assertIsNone(legacy['accountUid'])
        self.assertEqual(legacy['stateRoot'], str(c.library / 'saves' / GID))
