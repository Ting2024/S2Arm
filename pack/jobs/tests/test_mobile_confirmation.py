"""Replacement authorization is private, short lived, one-use and exact."""
from pathlib import Path
from types import SimpleNamespace
from unittest import TestCase, mock
import json, os, sys, tempfile
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import mobile_confirmation as C
import mobile_lifecycle as M
from core import Failure

class Confirmation(TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.c = SimpleNamespace(private=Path(self.tmp.name), operation='installHost')
        self.binding = dict(device='synthetic', bundle='bundle', host='h', expectedInstallation={'Path':'/synthetic/App'}, games=['GAME'])
    def test_exact_one_use(self):
        token = C.issue(self.c, self.binding)
        p = self.c.private/'ios-host-confirmations'/(token+'.json')
        self.assertEqual(p.stat().st_mode & 0o777, 0o600)
        C.consume(self.c, token, self.binding)
        with self.assertRaises(Failure): C.consume(self.c, token, self.binding)
    def test_changes_reject_without_consuming(self):
        token = C.issue(self.c, self.binding)
        for key in self.binding:
            with self.subTest(key=key), self.assertRaises(Failure):
                C.consume(self.c, token, dict(self.binding, **{key:'changed'}))
        C.consume(self.c, token, self.binding)
    def test_expired_and_invalid_token(self):
        with mock.patch.object(C.time,'time',return_value=100): token=C.issue(self.c,self.binding)
        with mock.patch.object(C.time,'time',return_value=701), self.assertRaises(Failure): C.consume(self.c,token,self.binding)
        for bad in ('../outside','',None,'A'*48):
            with self.assertRaises(Failure): C.consume(self.c,bad,self.binding)
    def test_links_and_special_files_rejected(self):
        token=C.issue(self.c,self.binding);p=self.c.private/'ios-host-confirmations'/(token+'.json')
        original=self.c.private/'original';p.rename(original);p.symlink_to(original)
        with self.assertRaises(Failure):C.consume(self.c,token,self.binding)
        p.unlink();os.link(original,p)
        with self.assertRaises(Failure):C.consume(self.c,token,self.binding)
        p.unlink();os.mkfifo(p)
        with self.assertRaises(Failure):C.consume(self.c,token,self.binding)
    def test_request_fields_cannot_bypass_unknown_admission(self):
        self.c.r={'hostConfirmation':'a'*48,'force':True}
        with mock.patch.object(M,'live_info',return_value={'installed':True}), mock.patch.object(M,'read_receipt',side_effect=Failure('unknown')):
            with self.assertRaises(Failure):M.stamp_install(self.c,Path('/not-opened'),'device','bundle')
    def test_bound_admission_rejects_changed_phone(self):
        self.c._host_replacement_admission={'expectedInstallation':dict(installed=True,CFBundleVersion='1',Path='/original'),'host':'h'}
        with mock.patch.object(M,'live_info',return_value=dict(installed=True,CFBundleVersion='1',Path='/changed')), mock.patch.object(M,'read_receipt',side_effect=Failure('unknown')):
            with self.assertRaises(Failure):M.stamp_install(self.c,Path('/not-opened'),'device','bundle')
    def test_local_modules_reads_v3_phone_ipa_when_legacy_container_dir_absent(self):
        import zipfile
        lib = self.c.private / 'lib'; lib.mkdir()
        self.c.library = lib
        gid = '01001B300B9BE000'
        with zipfile.ZipFile(lib / 'S2Arm.ipa', 'w') as z:
            z.writestr('Payload/S2Arm.app/s2a_catalogue.json', json.dumps({'games': [{'title_id': gid}]}))
            z.writestr(f'Payload/S2Arm.app/Frameworks/S2AImages-{gid}.dylib', b'dylib-bytes')
            z.writestr(f'Payload/S2Arm.app/Games/{gid}/launch.ctx', b'ctx-bytes')
        res = C.local_modules(self.c)
        self.assertEqual(res['games'], [gid])
        self.assertEqual(len(res['fingerprint']), 64)

