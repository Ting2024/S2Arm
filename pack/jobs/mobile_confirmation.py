"""Short-lived, one-use host replacement previews. Never an installation receipt."""
import hashlib
import json
import os
import re
import stat
import time
import secrets
from pathlib import Path
from core import Failure, atomic


def reject():
    raise Failure('安装确认已失效或与当前设备／宿主不符，请重新检测并确认。', code='ios_host_unknown')


def issue(c, binding):
    token = secrets.token_hex(24)
    folder = c.private / 'ios-host-confirmations'
    if folder.is_symlink(): reject()
    folder.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = folder / (token + '.json')
    atomic(path, dict(schema=1, created=time.time(), binding=binding))
    os.chmod(path, 0o600)
    return token


def consume(c, token, binding):
    if not isinstance(token, str) or not re.fullmatch('[0-9a-f]{48}', token): reject()
    folder = c.private / 'ios-host-confirmations'
    if folder.is_symlink(): reject()
    path = folder / (token + '.json')
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as f:
            st = os.fstat(f.fileno())
            if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1 or st.st_size > 128 * 1024: reject()
            data = json.loads(f.read(128 * 1024 + 1))
        if data.get('schema') != 1 or not 0 <= time.time() - data['created'] <= 600 or data.get('binding') != binding: reject()
        # Only one contender can unlink successfully. Consume before signing;
        # failure/cancellation requires a new visible confirmation, not replay.
        path.unlink()
    except (OSError, ValueError, TypeError, KeyError): reject()


def local_modules(c):
    """Fingerprint the existing local container without regenerating parked games."""
    base = c.library / 'iPhone/container/S2Arm.app'
    if base.is_symlink(): reject()
    if base.is_dir():
        catalogue = json.loads((base/'s2a_catalogue.json').read_text())
        ids = [g['title_id'] for g in catalogue['games']]
        if not ids or len(set(ids)) != len(ids) or any(not re.fullmatch('[0-9A-F]{16}', g) for g in ids): reject()
        hashes = {}
        for gid in sorted(ids):
            paths = [base/'Frameworks'/('S2AImages-'+gid+'.dylib'), *sorted((base/'Games'/gid).rglob('*'))]
            if not (base/'Games'/gid).is_dir(): reject()
            for p in paths:
                if p.is_symlink() or any(x.is_symlink() for x in p.parents if x != base.parent): reject()
                if p.is_file(): hashes[p.relative_to(base).as_posix()] = hashlib.sha256(p.read_bytes()).hexdigest()
        if any('Frameworks/S2AImages-'+g+'.dylib' not in hashes for g in ids): reject()
        return dict(games=sorted(ids), fingerprint=hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest())
    import layout, zipfile
    ipa = layout.phone_ipa(c)
    if ipa.is_symlink(): reject()
    if ipa.is_file():
        try:
            with zipfile.ZipFile(ipa) as z:
                cat_name = next(n for n in z.namelist() if re.fullmatch(r'Payload/[^/]+\.app/s2a_catalogue\.json', n))
                prefix = cat_name[:-len('s2a_catalogue.json')]
                catalogue = json.loads(z.read(cat_name).decode('utf-8'))
                ids = [g['title_id'] for g in catalogue['games']]
                if not ids or len(set(ids)) != len(ids) or any(not re.fullmatch('[0-9A-F]{16}', g) for g in ids): reject()
                hashes = {}
                names = set(z.namelist())
                for gid in sorted(ids):
                    fw = f'{prefix}Frameworks/S2AImages-{gid}.dylib'
                    if fw not in names: reject()
                    hashes[f'Frameworks/S2AImages-{gid}.dylib'] = hashlib.sha256(z.read(fw)).hexdigest()
                    gprefix = f'{prefix}Games/{gid}/'
                    gfiles = sorted(n for n in names if n.startswith(gprefix) and not n.endswith('/'))
                    if not gfiles: reject()
                    for n in gfiles:
                        hashes[n[len(prefix):]] = hashlib.sha256(z.read(n)).hexdigest()
                return dict(games=sorted(ids), fingerprint=hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest())
        except (OSError, StopIteration, ValueError, KeyError, zipfile.BadZipFile):
            reject()
    gid = (getattr(c, 'r', None) or {}).get('gameId') or ''
    gid = gid.upper()
    if re.fullmatch('[0-9A-F]{16}', gid):
        import ipa as packer, mobile_lifecycle as lifecycle
        sid = packer.current_shell_id(c)
        root = packer.current_root(c, gid, sid)
        if root is not None:
            return dict(games=[gid], fingerprint=lifecycle.input_identity(root, sid))
    reject()
