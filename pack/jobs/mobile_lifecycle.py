"""Device-bound install receipts. A local IPA or Documents receipt is not proof.

Only an exact live CFBundleVersion match admits a receipt. Unknown installed
apps fail closed rather than being overwritten by a potentially older host.
Resource retries never renew signing timestamps.
"""
from __future__ import annotations
import hashlib
import json
import math
import plistlib
from xml.parsers.expat import ExpatError
import re
import secrets
import subprocess
import time
from pathlib import Path
from core import Failure, atomic


def input_identity(root, shell_id):
    """Conservative executable/table closure, independent of resource payloads."""
    root = Path(root)
    entries = {}
    for p in sorted(root.rglob('*')):
        if not (p.name.endswith(('.patched.bin', '.tsv', '.npdm', '.nacp')) or
                p.name in ('icon.jpg', 'save-identity.json')):
            continue
        if p.is_symlink() or any((root / x).is_symlink() for x in p.relative_to(root).parents):
            raise Failure('游戏模块输入含链接，无法确认安装身份。', code='container_stale')
        if p.is_file():
            h = hashlib.sha256()
            with p.open('rb') as f:
                for b in iter(lambda: f.read(4 << 20), b''): h.update(b)
            entries[p.relative_to(root).as_posix()] = h.hexdigest()
    if 'main.npdm' not in entries or not any(n.endswith('.patched.bin') for n in entries):
        raise Failure('游戏模块输入不完整，不能跳过安装。', code='container_stale')
    return hashlib.sha256(json.dumps([shell_id, entries], sort_keys=True).encode()).hexdigest()


def receipt_path(c, device, bid):
    key = hashlib.sha256((device + '\0' + bid).encode()).hexdigest()
    return c.private / 'ios-installations' / (key + '.json')


def read_receipt(c, device, bid, live):
    if live.get('installed') is False: return None
    if live.get('installed') is not True:
        raise Failure('无法确认手机 App 是否已安装，本次未改动。', code='ios_host_unknown')
    try:
        r = json.loads(receipt_path(c, device, bid).read_text())
        if (r['schema'] == 1 and r['version'] == live['CFBundleVersion'] and
                isinstance(live['Path'], str) and live['Path'] == r['installationPath'] and
                isinstance(r['games'], dict) and
                all(isinstance(k, str) and isinstance(v, str) for k, v in r['games'].items()) and
                type(r.get('expires')) in (int, float) and math.isfinite(r['expires']) and
                re.fullmatch('[0-9a-f]{64}', r['host'])):
            return r
    except (OSError, ValueError, KeyError, TypeError): pass
    raise Failure('手机上的 S2Arm 安装版本尚未核实；为避免旧宿主覆盖新版，本次没有安装或传输。请先同步宿主更新。', code='ios_host_unknown')


def require_host(receipt, host):
    if receipt and receipt['host'] != host['id'] and receipt['host'] not in host.get('replaces', []):
        raise Failure('手机宿主不在此更新的升级链中，已阻止覆盖安装；不会把新版降回旧版。', code='ios_host_downgrade')


def can_push(receipt, gid, identity, now=None):
    return bool(receipt and receipt['games'].get(gid) == identity and
                receipt.get('expires', 0) > (time.time() if now is None else now) + 300)


def require_query_tool(exe, env):
    """Offline capability check; a stale tool is not a locked/disconnected phone."""
    try:
        p = subprocess.run([str(exe), '--capabilities'], capture_output=True,
                           timeout=10, env=env)
        d = plistlib.loads(p.stdout) if p.returncode == 0 else None
        if (isinstance(d, dict) and type(d.get('schema')) is int and d['schema'] == 1
                and isinstance(d.get('operations'), list) and 'app-info' in d['operations']):
            return
    except (OSError, ValueError, ExpatError, subprocess.TimeoutExpired):
        pass
    raise Failure('Mac 随包手机工具缺少版本查询能力或无法运行，请更新完整的 S2Arm；本次没有覆盖安装，不需要卸载手机 App。', code='ios_host_unknown')


def live_info(c, udid, bid):
    import install
    import tempfile
    from urllib.parse import unquote, urlparse
    with tempfile.TemporaryDirectory(dir=c.private) as work:
        client = install.devpush_client(c, udid, bid, work)
        require_query_tool(client.exe, c.env())
        try:
            p = subprocess.run([str(client.exe), udid, bid, 'app-info', '-'],
                               capture_output=True, timeout=60, env=c.env())
            d = plistlib.loads(p.stdout) if not p.returncode else None
            if isinstance(d, dict) and type(d.get('installed')) is bool:
                if d['installed'] is False:
                    return d
                version, path = d.get('CFBundleVersion'), d.get('Path')
                if (isinstance(version, str) and version.strip() and
                        not any(ord(ch) < 32 for ch in version) and
                        isinstance(path, str) and path.startswith('/') and
                        not any(ord(ch) < 32 for ch in path)):
                    return d
        except (OSError, ValueError, ExpatError, subprocess.TimeoutExpired): pass
    try:
        import diag
        rc, data, _ = diag.devicectl(c, 'device', 'info', 'apps', '--device', udid, '--bundle-id', bid, timeout=60)
        apps = data.get('result', {}).get('apps') if rc == 0 and isinstance(data, dict) else None
        if isinstance(apps, list):
            matched = [a for a in apps if isinstance(a, dict) and a.get('bundleIdentifier') == bid]
            if not matched:
                return {'installed': False}
            if len(matched) == 1:
                info = matched[0]
                version = info.get('bundleVersion')
                url = info.get('url')
                path = unquote(urlparse(url).path).rstrip('/') if isinstance(url, str) and url.startswith('file://') else None
                if (isinstance(version, str) and version.strip() and
                        not any(ord(ch) < 32 for ch in version) and
                        isinstance(path, str) and path.startswith('/') and
                        not any(ord(ch) < 32 for ch in path)):
                    out = {'installed': True, 'CFBundleVersion': version, 'Path': path}
                    short = info.get('version')
                    if isinstance(short, str) and short.strip() and not any(ord(ch) < 32 for ch in short):
                        out['CFBundleShortVersionString'] = short
                    return out
    except Exception:
        pass
    raise Failure('无法核实手机上的 App 版本，本次没有覆盖安装。请解锁手机并检查连接。', code='ios_host_unknown')


def new_version():
    # Valid CFBundleVersion grammar; exact identity, not an ordering clock.
    return f'{1000 + secrets.randbelow(9000)}.{secrets.randbelow(100)}.{secrets.randbelow(100)}'


def save_receipt(c, device, bid, version, host, games, expires, installationPath):
    p = receipt_path(c, device, bid); p.parent.mkdir(parents=True, exist_ok=True)
    atomic(p, dict(schema=1, version=version, host=host, games=games, expires=expires, installationPath=installationPath))


def host_directory(c):
    return Path(c.r.get('resources') or c.private) / 'IOSHost'


def verified_host(c, app=None, shell_id=None):
    # Run the same verifier used by the engine assembler, without importing a
    # second copy of pack into the worker's module search path.
    try:
        args = ['verify', str(host_directory(c))] if app is None else ['verify-app', str(host_directory(c)), str(app), shell_id]
        p = subprocess.run([__import__('sys').executable,
                            '-B', str(c.engine/'pack/ios_host.py'), *args],
                           capture_output=True, timeout=60, env=c.env())
        if p.returncode == 0: return json.loads(p.stdout)
    except (OSError, ValueError, ExpatError, subprocess.TimeoutExpired): pass
    raise Failure('缺少经过校验的 iOS 宿主更新组件，本次没有覆盖安装。', code='ios_host_unknown')


def plan(c, gid, udid, bid):
    import ipa
    live = live_info(c, udid, bid)
    receipt = read_receipt(c, udid, bid, live)
    # Resource delivery may bootstrap an absent app, never replace an installed
    # one. Expiry, new modules and unknown inputs require a separate host action.
    if receipt is None:
        verified_host(c)
        return None
    sid = ipa.current_shell_id(c)
    root = ipa.current_root(c, gid, sid)
    if root is None:
        raise Failure('无法核对游戏模块；本次没有重装 App 或传输资源。请先准备游戏，再单独安装／更新手机 App。', code='ios_host_action_required')
    identity = input_identity(root, sid)
    if can_push(receipt, gid, identity):
        return dict(games=list(receipt['games']), fresh=[gid])
    raise Failure('手机 App 需要加入此游戏模块或续签。推送资源不会覆盖安装；请先单独执行安装／更新／续签 App，再推送游戏。', code='ios_host_action_required')



def host_plan(c, gid, udid, bid, now=None, *, preview_unknown=False):
    """Read-only explicit host action: no assembly, signing or resource transfer.

    A valid unchanged installation is a no-op. A newer local host is offered
    only here, never in resource plan(). Unknown predecessors still fail closed.
    """
    import ipa
    live = live_info(c, udid, bid)
    unknown = False
    try:
        receipt = read_receipt(c, udid, bid, live)
    except Failure:
        if not preview_unknown or live.get('installed') is not True or not live.get('CFBundleVersion') or not live.get('Path'):
            raise
        receipt = None
        unknown = True

    host = verified_host(c)
    require_host(receipt, host)
    sid = ipa.current_shell_id(c)
    root = ipa.current_root(c, gid, sid)
    if root is None:
        raise Failure('本次未安装：缺少可核对的游戏模块，请先准备 iPhone 版。', code='container_stale')
    identity = input_identity(root, sid)
    reasons = []
    if receipt is None:
        reasons.append('unknownInstallation' if unknown else 'notInstalled')
    else:
        if receipt['host'] != host['id']: reasons.append('hostChanged')
        if receipt['games'].get(gid) != identity: reasons.append('moduleChanged')
        # A deliberate host action can renew before expiry; pushes never do so.
        if receipt['expires'] <= (time.time() if now is None else now) + 6 * 24 * 3600:
            reasons.append('signingDue')
    return dict(required=bool(reasons), reasons=reasons, unknownInstallation=unknown, expectedInstallation=live,
                expectedGames=receipt['games'] if receipt else {}, host=host['id'],
                gameIdentity=identity)


def stamp_install(c, app, udid, bid):
    """Validate candidate and live state BEFORE profile preparation/signing."""
    live = live_info(c, udid, bid)
    # A resource task can bootstrap only an absent App. Recheck here as assembly
    # may take minutes: another installer could have installed one since plan().
    if getattr(c, 'operation', None) == 'install' and live.get('installed') is not False:
        raise Failure('准备资源期间手机 App 安装状态改变，已停止自动安装；请重新推送，或单独执行宿主更新。', code='ios_host_action_required')
    try:
        receipt = read_receipt(c, udid, bid, live)
    except Failure:
        approved = getattr(c, '_host_replacement_admission', None)
        if (getattr(c, 'operation', None) != 'installHost' or not approved or
                any(live.get(k) != approved['expectedInstallation'].get(k) for k in ('installed', 'CFBundleVersion', 'Path'))):
            raise
        receipt = None

    try:
        host = json.loads((app/'s2a_host.json').read_text())
        games = json.loads((app/'s2a_game_inputs.json').read_text())
        catalogue = json.loads((app/'s2a_catalogue.json').read_text())
        trusted = verified_host(c, app, catalogue['shell_id'])
        if host != trusted: raise ValueError('unverified host')
        approved = getattr(c, '_host_replacement_admission', None)
        if approved and host['id'] != approved['host']: raise ValueError('confirmation host changed')
        require_host(receipt, host)
        members = {g['title_id'] for g in catalogue['games']}
        if not isinstance(games, dict) or not set(games).issubset(members):
            raise ValueError('stale module identities')
        if not games or not all(re.fullmatch('[0-9A-F]{16}', g) and
                                re.fullmatch('[0-9a-f]{64}', v) for g, v in games.items()):
            raise ValueError('invalid games')
    except (OSError, ValueError, TypeError, KeyError):
        raise Failure('安装包缺少可核对的宿主或游戏模块身份，已阻止覆盖安装。', code='ios_host_unknown')
    version = new_version()
    info = plistlib.loads((app/'Info.plist').read_bytes()); info['CFBundleVersion'] = version
    (app/'Info.plist').write_bytes(plistlib.dumps(info))
    return dict(version=version, host=host['id'], games=games, expectedInstallation=live)


def finish_install(c, app, udid, bid, stamp):
    live = live_info(c, udid, bid)
    if (live.get('installed') is not True or live.get('CFBundleVersion') != stamp['version'] or
            not isinstance(live.get('Path'), str) or not live['Path']):
        raise Failure('安装后版本核对失败，尚未开始传输资源。', code='ios_host_unknown')
    # Read actual embedded profile expiry, never infer another seven days from
    # a transfer retry or even from a successful re-sign with an older profile.
    p = subprocess.run(['security', 'cms', '-D', '-i', str(app/'embedded.mobileprovision')], capture_output=True)
    try:
        import datetime
        expiry = plistlib.loads(p.stdout)['ExpirationDate'].replace(tzinfo=datetime.timezone.utc).timestamp()
    except (ValueError, KeyError, AttributeError): expiry = 0
    save_receipt(c, udid, bid, expires=expiry, installationPath=live["Path"],
                 **{k: stamp[k] for k in ("version", "host", "games")})
    if expiry > 0:
        c._installed_expiry = expiry


def before_install(c, udid, bid, device, expected):
    """Recheck immediately before overwrite, after slow signing/backups."""
    current = live_info(c, udid, bid)
    keys = ('installed', 'CFBundleVersion', 'Path')
    if any(current.get(k) != expected.get(k) for k in keys):
        raise Failure('签名期间手机上的 App 安装状态改变，本次没有覆盖安装。', code='ios_host_unknown')
    # A fresh local process inventory is required even for device-only updates.
    ps = subprocess.run(['ps', '-axo', 'comm='], capture_output=True, timeout=15)
    if ps.returncode:
        raise Failure('无法完成安装前进程检查，本次未安装。', code='ios_host_unknown')
    import diag
    rc, data, _ = diag.devicectl(c, 'device', 'info', 'processes', '--device', device, timeout=60)
    processes = data.get('result', {}).get('runningProcesses')
    if rc == 0 and isinstance(processes, list):
        path = current.get('Path', '')
        for p in processes:
            if 'S2Arm.app/' in str(p) or (path and path in str(p)):
                pid = p.get('processIdentifier') if isinstance(p, dict) else None
                if type(pid) is int and pid > 0:
                    diag.devicectl(c, 'device', 'process', 'terminate', '--device', device, '--pid', str(pid), '--kill', timeout=30)
    c.check()
