"""Cross-game host updates must retain identities from the installed receipt."""
from pathlib import Path
from types import SimpleNamespace
from unittest import TestCase, mock
import json, sys, tempfile
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ipa
import mobile_lifecycle as lifecycle
from core import Failure

A = '01001B300B9BE000'
B = '0400486024DEC000'
PARKED = '01006F8002326000'

class RetainedInputs(TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.base = self.root/'base'; self.base.mkdir()
        self.inputs = self.root/'inputs'; self.inputs.mkdir()
        (self.inputs/'main.npdm').write_bytes(b'meta')
        (self.inputs/'main.patched.bin').write_bytes(b'code')
        self.identity = lifecycle.input_identity(self.inputs, 'sid')
        self.c = SimpleNamespace()

    def test_switch_game_after_private_install_recovers_only_receipt_known_input(self):
        with mock.patch.object(ipa, 'current_root', return_value=self.inputs) as current:
            roots = ipa.retained_input_roots(self.c, B, 'sid', self.base, {A:self.identity})
        self.assertEqual(roots, {A:self.inputs})
        current.assert_called_once_with(self.c, A, 'sid')
        self.assertNotIn(PARKED, roots)
        self.assertFalse((self.base/'s2a_game_inputs.json').exists())

    def test_changed_or_missing_inputs_never_receive_receipt_label(self):
        for root in (None, self.inputs):
            with mock.patch.object(ipa, 'current_root', return_value=root), self.assertRaises(Failure):
                ipa.retained_input_roots(self.c, B, 'sid', self.base, {A:'0'*64})
        self.assertFalse((self.base/'s2a_game_inputs.json').exists())

    def test_known_local_identity_needs_no_reembedding(self):
        (self.base/'s2a_game_inputs.json').write_text(json.dumps({A:self.identity}))
        with mock.patch.object(ipa, 'current_root') as current:
            self.assertEqual(ipa.retained_input_roots(self.c, B, 'sid', self.base, {A:self.identity}), {})
        current.assert_not_called()

    def test_selected_module_can_change_without_claiming_old_identity(self):
        with mock.patch.object(ipa, 'current_root') as current:
            self.assertEqual(ipa.retained_input_roots(self.c, A, 'sid', self.base, {A:self.identity}), {})
        current.assert_not_called()

    def test_corrupt_or_linked_local_manifest_rejects(self):
        p=self.base/'s2a_game_inputs.json'
        for text in ('invalid', '[]'):
            p.write_text(text)
            with self.assertRaises(Failure):ipa.retained_input_roots(self.c, B, 'sid', self.base, {A:self.identity})
        p.unlink();p.symlink_to(self.inputs/'main.npdm')
        with self.assertRaises(Failure):ipa.retained_input_roots(self.c, B, 'sid', self.base, {A:self.identity})

    def test_assembly_receives_recovered_roots_and_writes_both_identities(self):
        # Execute the real assemble orchestration. Stub only external packaging
        # and use synthetic game bytes; no phone or formal library access.
        lib=self.root/'library';base=lib/'iPhone/container/S2Arm.app';base.mkdir(parents=True)
        (base/'s2a_catalogue.json').write_text(json.dumps({'shell_id':'sid','games':[{'title_id':g} for g in (A,B,PARKED)]}))
        engine=self.root/'engine';icon=engine/'launchers/macos/Branding/AppIcon-1024.png'
        icon.parent.mkdir(parents=True);icon.write_bytes(b'icon')
        private=self.root/'private';private.mkdir()
        dest=self.root/'candidate'; host=self.root/'IOSHost';host.mkdir()
        calls=[]
        def run(args, log, env=None):
            args=[str(a) for a in args];calls.append(args)
            if any(a.endswith('/ship_ext.py') for a in args):
                app=Path(args[args.index('--out')+1]);app.mkdir()
                (app/'s2a_catalogue.json').write_bytes((base/'s2a_catalogue.json').read_bytes())
        c=SimpleNamespace(library=lib,engine=engine,private=private,task='test',run=run,env=lambda:{})
        def write_ipa(c,app,ipa_path,log):ipa_path.write_bytes(b'fixture')
        with mock.patch.object(ipa,'current_shell_id',return_value='sid'), \
             mock.patch.object(ipa,'current_root',return_value=self.inputs) as current, \
             mock.patch.object(ipa,'container_shell',return_value=self.root/'shell'), \
             mock.patch.object(ipa,'container_custom',return_value={}), \
             mock.patch.object(ipa,'write_container_ipa',side_effect=write_ipa), \
             mock.patch.object(lifecycle,'host_directory',return_value=host):
            _,games,fresh=ipa.assemble(c,B,dest=dest,expected_games={A:self.identity})
        ids=json.loads((dest/'S2Arm.app/s2a_game_inputs.json').read_text())
        self.assertEqual(ids,{A:self.identity,B:self.identity})
        self.assertEqual(set(games),{A,B,PARKED})
        self.assertEqual(set(fresh),{A,B})
        self.assertEqual([x.args[1] for x in current.call_args_list],[B,A])
        self.assertFalse((base/'s2a_game_inputs.json').exists())
        command=next(a for a in calls if any(x.endswith('/ship_ext.py') for x in a))
        self.assertEqual(command.count('--game'),2)
        self.assertEqual(command[command.index('--base')+1],str(base.resolve()))
