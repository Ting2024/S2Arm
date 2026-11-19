"""Explicit compatible host overlay; does not relabel or weaken shell manifests.

Updates carry exact files, compatible legacy shell IDs, and predecessor host
IDs. No ordering is inferred from a source commit or a marketing version.
"""
import hashlib
import json
import shutil
from pathlib import Path


def load(directory):
    directory = Path(directory)
    if (directory/'host.json').is_symlink(): raise ValueError('Symlink manifest')
    d = json.loads((directory / 'host.json').read_text())
    body = {k: d[k] for k in ('schema', 'files', 'compatibleShellIds', 'replaces')}
    if d['schema'] != 1 or hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest() != d['id']:
        raise ValueError('iOS host identity mismatch')
    if not isinstance(d['files'], dict) or not d['files']: raise ValueError('Missing host closure')
    for name, entry in d['files'].items():
        rel = Path(name)
        if (not name or rel.is_absolute() or '\\' in name or ':' in name or
                any(x in ('', '.', '..') for x in name.split('/')) or
                name.split('/')[0] not in ('S2Arm', 'Frameworks', 'S2ArmShellUI_ShellUI.bundle', 'Settings.bundle',
                                           'en.lproj', 'es.lproj', 'fr.lproj', 'ja.lproj', 'zh-Hans.lproj', 'zh-Hant.lproj') or
                name.startswith('Frameworks/S2AImages')):
            raise ValueError('Invalid iOS host closure')
        p = directory / 'root' / rel
        if any(x.is_symlink() for x in [directory, directory/'root', p,
                                      *(directory/'root'/parent for parent in rel.parents)]):
            raise ValueError('Symlink in iOS host closure')
        if [p.stat().st_size, hashlib.sha256(p.read_bytes()).hexdigest()] != entry:
            raise ValueError('iOS host file mismatch')
    if 'S2Arm' not in d['files']: raise ValueError('Missing iOS host executable')
    return d


def verify_app(directory, app, shell_id):
    """Before signing: verify actual host bytes, not just copied metadata."""
    d = load(directory)
    if shell_id not in d["compatibleShellIds"]: raise ValueError("Unapproved module ABI")
    app = Path(app)
    if json.loads((app / "s2a_host.json").read_text()) != d: raise ValueError("Host metadata mismatch")
    for name, expected in d["files"].items():
        if any(x.is_symlink() for x in [app, app/name, *(app/p for p in Path(name).parents)]):
            raise ValueError("Symlink installed host")
        p = app/name
        if [p.stat().st_size, hashlib.sha256(p.read_bytes()).hexdigest()] != expected:
            raise ValueError("Candidate host bytes differ from verified update")
    return d


def apply(directory, app, shell_id):
    d = load(directory)
    if shell_id not in d['compatibleShellIds']: raise ValueError('iOS host/module ABI not approved')
    app = Path(app)
    for name in d['files']:
        if any(x.is_symlink() for x in [app, app/name, *(app/p for p in Path(name).parents)]):
            raise ValueError('Symlink host destination')
    for name in d['files']:
        dst = app / name; dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(Path(directory) / 'root' / name, dst)
    (Path(app) / 's2a_host.json').write_text(json.dumps(d, sort_keys=True) + '\n')
    return d


if __name__ == '__main__':
    import sys
    try:
        if sys.argv[1] == 'verify': print(json.dumps(load(sys.argv[2]), sort_keys=True))
        elif sys.argv[1] == 'verify-app': print(json.dumps(verify_app(sys.argv[2], sys.argv[3], sys.argv[4]), sort_keys=True))
        elif sys.argv[1] == 'apply': apply(sys.argv[2], sys.argv[3], sys.argv[4])
        else: raise ValueError('Unknown operation')
    except (OSError, ValueError, KeyError, TypeError):
        sys.exit('iOS host verification failed')
