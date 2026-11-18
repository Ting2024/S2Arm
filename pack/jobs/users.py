# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Device-wide launcher users, separate from game-owned account/save identities.

01 is the legacy profile: it never assigns a new runtime UID to existing saves.
Other users have stable UIDs, but launching them requires explicit host support.
This module never opens, migrates or deletes saves.
"""
from __future__ import annotations

import contextlib
import copy
import json
import os
from pathlib import Path
import re
import stat
import uuid

from core import Failure, atomic, contained
import filelock

MAX_USERS = 100
MAX_BYTES = 128 << 10
LEGACY_UID = "00000000000000010000000000000000"


def user_id(value):
    if not isinstance(value, str) or not re.fullmatch(r"(?:0[1-9]|[1-9][0-9]{1,5})", value):
        raise Failure("用户编号无效。")
    return value


def user_name(value):
    # Horizon profile names have a 32-byte UTF-8 field. Never truncate mid-codepoint.
    try:
        encoded_size = len(value.encode('utf-8')) if isinstance(value, str) else MAX_BYTES
    except UnicodeError:
        encoded_size = MAX_BYTES
    if (not isinstance(value, str) or not value.strip() or value != value.strip()
            or encoded_size > 32
            or any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in value)):
        raise Failure("用户名须为非空文字，不能含控制字符或首尾空格，UTF-8 长度不能超过 32 字节。")
    return value


def default_registry():
    return dict(schema=1, revision=0, nextId=2,
                users=[dict(id='01', name='用户1', accountUid=None)])


def validate(document):
    if not isinstance(document, dict) or set(document) != {'schema', 'revision', 'nextId', 'users'}:
        raise ValueError('invalid registry')
    if type(document['schema']) is not int or document['schema'] != 1:
        raise ValueError('unsupported registry schema')
    if type(document['revision']) is not int or document['revision'] < 0:
        raise ValueError('invalid revision')
    rows, next_id = document['users'], document['nextId']
    if not isinstance(rows, list) or not 1 <= len(rows) <= MAX_USERS:
        raise ValueError('invalid users')
    if type(next_id) is not int or not 2 <= next_id <= 1000000:
        raise ValueError('invalid next id')
    ids, uids = set(), set()
    for row in rows:
        if not isinstance(row, dict) or set(row) != {'id', 'name', 'accountUid'}:
            raise ValueError('invalid user')
        ident = user_id(row['id'])
        user_name(row['name'])
        if ident in ids or int(ident) >= next_id:
            raise ValueError('duplicate/out-of-range user id')
        ids.add(ident)
        uid = row['accountUid']
        if ident == '01':
            if uid is not None:
                raise ValueError('legacy user must preserve game identity')
        elif (not isinstance(uid, str) or not re.fullmatch('[0-9a-f]{32}', uid)
              or int(uid, 16) == 0 or uid == LEGACY_UID or uid in uids):
            raise ValueError('invalid account identity')
        else:
            uids.add(uid)
    if '01' not in ids:
        raise ValueError('missing legacy user')
    return document


def safe_path(root, path):
    """Allow OS ancestor aliases, reject links anywhere within the managed root."""
    root, path = Path(root), Path(path)
    current = root
    if current.is_symlink():
        raise Failure("用户数据目录包含链接，已停止操作。")
    for part in path.relative_to(root).parts:
        current /= part
        if current.is_symlink():
            raise Failure("用户数据目录包含链接，已停止操作。")
    return contained(root, path)


def _path(c):
    return safe_path(c.private, c.private / 'users.json')


def _unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate registry key')
        result[key] = value
    return result


def load(c):
    path = _path(c)
    try:
        # One open, no symlink-following and bounded input; missing is the only
        # default case. Corruption must not silently reset IDs or overwrite data.
        fd = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0))
    except FileNotFoundError:
        return default_registry()
    try:
        with os.fdopen(fd, 'rb') as handle:
            info = os.fstat(handle.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_BYTES:
                raise ValueError('invalid registry file')
            data = handle.read(MAX_BYTES + 1)
            if len(data) > MAX_BYTES:
                raise ValueError('oversized registry')
            return validate(json.loads(data, object_pairs_hook=_unique))
    except (ValueError, UnicodeError, Failure):
        raise Failure("用户资料损坏或版本不受支持，已停止操作；没有重置用户或存档。") from None


@contextlib.contextmanager
def registry_lock(c):
    c.check()
    path = safe_path(c.private, c.private / '.users.lock')
    fd = os.open(path, os.O_RDWR | os.O_CREAT | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0), 0o600)
    with os.fdopen(fd, 'r+b') as handle:
        if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
            raise Failure("用户资料锁文件无效。")
        try:
            filelock.try_lock(handle)
        except BlockingIOError:
            raise Failure("另一项操作正在修改用户，请稍后重试。") from None
        try:
            yield
        finally:
            filelock.unlock(handle)


def listing(c):
    # No library/engine required. Merely viewing users creates no registry or saves.
    return copy.deepcopy(load(c))


def update(c):
    """Create/rename with optimistic revision checking; no deletion operation."""
    action = c.r.get('action')
    if action not in ('create', 'rename'):
        raise Failure("不支持的用户管理操作。")
    name = user_name(c.r.get('name'))
    revision = c.r.get('revision')
    if type(revision) is not int or revision < 0:
        raise Failure("请先刷新用户列表，再修改用户。")
    with registry_lock(c):
        document = load(c)
        if document['revision'] != revision:
            raise Failure("用户列表已变化，请刷新后重试。")
        if action == 'create':
            if len(document['users']) >= MAX_USERS or document['nextId'] >= 1000000:
                raise Failure("用户数量已达到上限。")
            ident = f"{document['nextId']:02d}"
            document['nextId'] += 1
            uid = uuid.uuid4().hex
            while uid == LEGACY_UID or any(row['accountUid'] == uid for row in document['users']):
                uid = uuid.uuid4().hex
            document['users'].append(dict(id=ident, name=name, accountUid=uid))
        else:
            ident = user_id(c.r.get('userId'))
            row = next((u for u in document['users'] if u['id'] == ident), None)
            if row is None:
                raise Failure("所选用户不存在，请刷新用户列表。")
            row['name'] = name
        document['revision'] += 1
        validate(document)
        c.check()
        atomic(_path(c), document)
        return copy.deepcopy(document)


def selected(c):
    """Capture once per request; later rename/selection must not retarget a job."""
    captured = getattr(c, '_selected_launcher_user', None)
    if captured is None:
        ident = user_id(c.r.get('userId', '01'))
        captured = next((u for u in load(c)['users'] if u['id'] == ident), None)
        if captured is None:
            raise Failure("所选用户不存在，请刷新用户列表。")
        c._selected_launcher_user = copy.deepcopy(captured)
    return copy.deepcopy(c._selected_launcher_user)


def _player_suffix(c, ident):
    suffix = () if ident == '01' else ('users', ident)
    if ident == '01' and hasattr(c, 'r') and isinstance(c.r, dict) and isinstance(c.r.get('player'), dict):
        p_user = c.r['player'].get('user')
        if isinstance(p_user, str) and re.fullmatch(r'[0-9a-f]{32}', p_user) and p_user != '0' * 32:
            return ('players', p_user)
    return suffix


def paths(c, gid):
    """Pure path plan, no mkdir/migration. All mutable per-game state is isolated."""
    if not isinstance(gid, str) or not re.fullmatch('[0-9a-fA-F]{16}', gid):
        raise Failure("游戏标识无效，无法选择用户数据目录。")
    ident = selected(c)['id']
    suffix = () if ident == '01' else ('users', ident)
    player_suffix = _player_suffix(c, ident)
    return {name: safe_path(c.library, c.library.joinpath(folder, *(player_suffix if name in ('docs', 'cache') else suffix), gid))
            for name, folder in [('save', 'saves'), ('cache', 'runtime-cache'),
                                 ('docs', 'temp'), ('backups', 'save-backups'),
                                 ('imports', 'save-imports')]} | {
        'transactions': safe_path(c.library, c.library.joinpath('save-transactions', *suffix))}


def input_path(c, gid):
    """Per-game mapping for the captured user; user01 keeps its original file."""
    if not isinstance(gid, str) or not re.fullmatch('[0-9a-fA-F]{16}', gid):
        raise Failure("游戏标识无效，无法选择用户输入配置。")
    ident = selected(c)['id']
    suffix = () if ident == '01' else ('users', ident)
    return safe_path(c.library, c.library.joinpath('mappings', *suffix, gid + '.json'))


MNG_INPUT_FILES = (
    'controls.txt',
    'controller-type.txt',
    'mouse.txt',
    'controller-slots.plist',
    'controller-devices.plist',
    'input-sources.plist',
    'keyboard-slots.plist',
    'physical-keyboards.plist',
    'stick-bindings.plist',
)


def mng_input_root(c, gid):
    """Per-game native MNG input directory for the captured user.

    User 01 uses mappings/mng/<gid>; other users use mappings/users/<id>/mng/<gid>.
    Validates that neither the directory nor any of the 9 MNG config leaves are
    symlinks, hardlinks, or non-regular files before the host runs.
    """
    if not isinstance(gid, str) or not re.fullmatch('[0-9a-fA-F]{16}', gid):
        raise Failure("游戏标识无效，无法选择用户输入配置。")
    ident = selected(c)['id']
    suffix = _player_suffix(c, ident)
    root = safe_path(c.library, c.library.joinpath('mappings', *suffix, 'mng', gid))
    try:
        root_info = root.lstat()
    except FileNotFoundError:
        root_info = None
    if root_info is not None and not stat.S_ISDIR(root_info.st_mode):
        raise Failure("用户输入配置目录不是普通目录，已停止启动。", code="runtime_invalid")
    for name in MNG_INPUT_FILES:
        leaf = root / name
        try:
            info = leaf.lstat()
        except FileNotFoundError:
            continue
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise Failure("用户输入配置文件包含链接或不是普通文件，已停止启动。", code="runtime_invalid")
    return root


def runtime_paths(c, gid):
    """Pure plan for writable runtime outputs, including relative-file cwd.

    Game resources stay shared/read-only. S2A_RUN_ROOT is deliberately not
    overridden: host/Metal scheduling locks must still coordinate all sessions.
    No HOME replacement, migration, cache clearing, or directory creation.
    """
    planned = paths(c, gid)
    save, cache, docs = (planned[key] for key in ('save', 'cache', 'docs'))
    outputs = dict(S2A_RYU_DATA=save, S2A_DOCS=docs,
                   NXGAL_SHADER_CACHE_DIR=cache / 'shaders',
                   NXGAL_PSO_DEV_DIR=cache / 'pso',
                   S2A_MACRO_DUMP=cache / 'macros',
                   DM_PSO_USER=cache / 'direct' / 'pso_user.tsv',
                   S2A_WIDEN_FLAT_CACHE=cache / 'direct' / 'widen_flat3.tsv',
                   S2A_SHCOLLECT=cache / 'shcollect', GAL_AIR_CACHE=cache / 'air',
                   GAL_PSO_CACHE=cache / 'pipeline', S2A_SCHED_DIR=cache / 'observations',
                   TMPDIR=docs / '.tmp')
    outputs = {key: safe_path(c.library, value) for key, value in outputs.items()}
    for key in ('DM_PSO_USER', 'S2A_WIDEN_FLAT_CACHE'):
        try:
            info = outputs[key].lstat()
        except FileNotFoundError:
            continue
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise Failure("用户缓存文件包含链接或不是普通文件，已停止启动。", code="runtime_invalid")
    return outputs


def session_descriptor(c, gid):
    """Pure immutable host descriptor. Caller must first admit a capable host.

    No environment inheritance, seed import, directory creation or account
    migration. The launch caller passes it only after exact-host admission.
    """
    user = selected(c)
    return dict(schema=1, id=user['id'], name=user['name'],
                accountUid=user['accountUid'], stateRoot=str(paths(c, gid)['save']))


def admitted_session_descriptor(c, gid, executable):
    """Bind the captured user to an exact, already-validated native host.

    Called after runtime/host integrity and signature admission, before any
    selected profile recovery or directory creation.
    """
    import toolchain
    descriptor = session_descriptor(c, gid)
    supported, reason = toolchain.launcher_account_interface(c, executable)
    if not supported:
        raise Failure(reason, code='runtime_invalid')
    return descriptor


@contextlib.contextmanager
def session_lock(c, gid):
    """Play/save ownership: shared resources, exclusive game+user state.

    All callers must follow execution -> game ->
    session order; builds retain the exclusive game lock, library mutations
    retain exclusive execution. A per-session lock covers launch recovery too.
    """
    paths(c, gid)  # Validate game ID, capture user, reject redirected state paths.
    ident = selected(c)['id']
    if ident == '01':
        import saves
        player = saves.requested_player(getattr(c, 'r', {}))
        if player and player.get('user') not in ('', 'first'):
            ident = f"{ident}-{player['user']}"
    with c.lock('execution', shared=True), c.lock('game-' + gid, shared=True), \
            c.lock('session-' + gid.lower() + '-' + ident):
        yield


