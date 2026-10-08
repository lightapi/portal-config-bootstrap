# Provenance: portal-config-loc commit 2c511911d2f2ca20448b552e9a5f96b6a10ac799
"""Verified immutable releases and journalled owner-run activation (no import I/O)."""
import contextlib
from dataclasses import dataclass
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile
import time
import urllib.request
import zipfile


class ActivationError(Exception):
    """Refused candidate or failed activation with verified restoration."""


class RecoveryFailed(Exception):
    """Unverified outcome: retain the journal and recover explicitly."""


@dataclass
class Runner:
    validate_offline: object
    recreate_gateways: object
    read_release_digest: object
    gateway_healthy: object


@dataclass
class Context:
    runner: Runner
    runtime_config: Path
    key_dir: Path
    mount_path: str = '/'
    handler_config: Path = None
    sleep: object = time.sleep
    recreate_command: str = 'docker compose --project-name all-in-lt -f all-in-lt/docker-compose.yml up -d --no-deps --force-recreate light-gateway workflow-mcp-test-gateway'


EMPTY = dict(active=None, rollback=None, activeDigest=None)


def require(ok, message):
    if not ok:
        raise ActivationError(message)


def component(value):
    require(isinstance(value, str) and value not in ('.', '..')
            and re.fullmatch(r'[A-Za-z0-9_.-]+', value),
            'unsafe version or filename')
    return value


def member_path(value):
    require(isinstance(value, str) and value and not value.startswith(('/', '-'))
            and not any(c in value for c in '\\:*?[]')
            and not any(ord(c) < 32 or ord(c) == 127 for c in value)
            and all(p and not p.startswith('.') for p in value.split('/')), 'unsafe member path')
    return value


def regular(path):
    require(stat.S_ISREG(Path(path).lstat().st_mode), 'expected regular file: ' + str(path))
    return Path(path)


def directory(path):
    require(stat.S_ISDIR(Path(path).lstat().st_mode), 'expected real directory: ' + str(path))
    return Path(path)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_json(path):
    try:
        def pairs(items):
            result = {}
            for k, v in items:
                require(k not in result, 'duplicate JSON key')
                result[k] = v
            return result
        return json.loads(regular(path).read_bytes(), object_pairs_hook=pairs)
    except (OSError, ValueError) as error:
        raise ActivationError('cannot read JSON: ' + str(path)) from error


def manifest_at(path):
    manifest = read_json(path / 'release-manifest.json')
    require(isinstance(manifest, dict) and manifest.get('artifact') == 'portal-view'
            and manifest.get('manifestVersion') == 1, 'invalid release manifest')
    component(manifest.get('version'))
    archive = manifest.get('archive', {})
    require(isinstance(archive, dict), 'invalid archive')
    require(archive.get('name') == 'portal-view-' + manifest['version'] + '.zip', 'archive name mismatch')
    require(isinstance(archive.get('sha256'), str) and re.fullmatch('[0-9a-f]{64}', archive['sha256']), 'invalid archive digest')
    members(manifest)
    return manifest


def members(manifest):
    entries = manifest.get('members')
    require(isinstance(entries, list) and entries, 'invalid members')
    result = {}
    for entry in entries:
        require(isinstance(entry, dict), 'invalid member')
        name = member_path(entry.get('path'))
        require(name not in result, 'duplicate manifest member')
        require(type(entry.get('size')) is int and entry['size'] >= 0
                and isinstance(entry.get('sha256'), str)
                and re.fullmatch('[0-9a-f]{64}', entry['sha256']), 'invalid member size/digest')
        result[name] = entry
    require(not any('/'.join(name.split('/')[:i]) in result
                    for name in result for i in range(1, len(name.split('/')))),
            'member path conflicts with a parent file')
    return result


def verify_signature(release_dir, key_dir):
    release_dir, key_dir = directory(release_dir), directory(key_dir)
    manifest = manifest_at(release_dir)
    signature = manifest.get('signature', {})
    require(isinstance(signature, dict) and signature.get('algorithm') == 'Ed25519', 'signature algorithm must be Ed25519')
    key_id = signature.get('keyId')
    require(isinstance(key_id, str) and re.fullmatch(r'[a-z0-9][a-z0-9._-]{0,63}', key_id), 'invalid keyId')
    key = regular(key_dir / (key_id + '.pem'))
    sig = regular(release_dir / 'release-manifest.sig')
    # The SPKI algorithm OID 1.3.101.112 identifies Ed25519, without accepting
    # a private-key PEM or relying on a manifest algorithm claim.
    result = subprocess.run(['openssl', 'pkey', '-pubin', '-in', str(key), '-outform', 'DER'],
                            capture_output=True, timeout=60)
    require(result.returncode == 0 and result.stdout.startswith(bytes.fromhex('302a300506032b6570032100'))
            and len(result.stdout) == 44, 'trusted key must be Ed25519')
    result = subprocess.run(['openssl', 'pkeyutl', '-verify', '-pubin', '-inkey', str(key),
                             '-rawin', '-in', str(release_dir / 'release-manifest.json'), '-sigfile', str(sig)],
                            capture_output=True, timeout=60)
    require(result.returncode == 0, 'manifest signature verification failed')
    return manifest


def check_bytes(data, entry):
    require(len(data) == entry['size'] and digest(data) == entry['sha256'], 'member hash/size mismatch')


def verify_archive(manifest, archive_path):
    require(digest(regular(archive_path).read_bytes()) == manifest['archive']['sha256'], 'archive digest mismatch')
    expected, seen = members(manifest), set()
    with zipfile.ZipFile(archive_path) as archive:
        for info in archive.infolist():
            name = member_path(info.filename)
            mode = stat.S_IFMT(info.external_attr >> 16)
            require(mode in (0, stat.S_IFREG) and not info.is_dir(), 'non-regular archive member')
            require(name not in seen, 'duplicate archive member')
            require(name in expected, 'extra archive member')
            seen.add(name)
            check_bytes(archive.read(info), expected[name])
    require(seen == set(expected), 'missing archive member')


def verify_tree(manifest, dist_dir):
    root = directory(dist_dir)
    expected, seen = members(manifest), set()
    allowed_dirs = {'/'.join(name.split('/')[:i]) for name in expected
                    for i in range(1, len(name.split('/')))}
    def walk(path):
        for item in path.iterdir():
            name = item.relative_to(root).as_posix()
            member_path(name)
            mode = item.lstat().st_mode
            if stat.S_ISDIR(mode):
                require(name in allowed_dirs, 'extra tree directory')
                walk(item)
            else:
                require(stat.S_ISREG(mode) and name in expected, 'unsafe or extra tree member')
                check_bytes(item.read_bytes(), expected[name])
                seen.add(name)
    walk(root)
    require(seen == set(expected), 'missing tree member')


def fsync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_json(path, value):
    path = Path(path)
    fd, name = tempfile.mkstemp(prefix='.' + path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as file:
            json.dump(value, file, sort_keys=True)
            file.write('\n')
            file.flush()
            os.fsync(file.fileno())
        os.replace(name, path)
        fsync_dir(path.parent)
    finally:
        if os.path.lexists(name):
            os.unlink(name)


def unlink_durable(path):
    path.unlink()
    fsync_dir(path.parent)


def pointer(root, version):
    # Reserve a unique same-directory path before creating the symlink.
    fd, reserved = tempfile.mkstemp(prefix='.current.', dir=root)
    os.close(fd)
    os.unlink(reserved)
    name = Path(reserved)
    try:
        name.symlink_to('releases/' + component(version))
        os.replace(name, root / 'current')
        fsync_dir(root)
    finally:
        if name.is_symlink():
            name.unlink()


def fetch(url, destination):
    with urllib.request.urlopen(url, timeout=60) as response, destination.open('xb') as out:
        shutil.copyfileobj(response, out)


def remove_owned(path):
    # Only called for directories created exclusively by this invocation.
    for parent, dirs, files in os.walk(path):
        os.chmod(parent, 0o700)
    shutil.rmtree(path)


def stage(source, version, root, key_dir, downloader=fetch):
    version, root = component(version), Path(root)
    root.mkdir(parents=True, exist_ok=True)
    directory(root)
    for part in ('releases', '.downloads'):
        (root / part).mkdir(exist_ok=True)
        directory(root / part)
    downloaded = root / '.downloads' / version
    staging = root / 'releases' / (version + '.staging')
    owned_download = owned_stage = False
    try:
        downloaded.mkdir()  # Never reuse/remove an unknown earlier download.
        owned_download = True
        for name in ('portal-view-' + version + '.zip', 'release-manifest.json', 'release-manifest.sig'):
            if isinstance(source, Path):
                directory(source)
                shutil.copyfile(regular(source / name), downloaded / name)
            else:
                downloader(source.rstrip('/') + '/' + name, downloaded / name)
        manifest = verify_signature(downloaded, key_dir)
        require(manifest['version'] == version, 'manifest version mismatch')
        archive = downloaded / manifest['archive']['name']
        verify_archive(manifest, archive)
        target = root / 'releases' / version
        if os.path.lexists(target):
            verify_signature(target, key_dir)
            existing = manifest_at(target)
            verify_tree(existing, target / 'dist')
            require(digest((target / 'release-manifest.json').read_bytes()) == digest((downloaded / 'release-manifest.json').read_bytes()),
                    'release ' + version + ' already staged with different content')
            return target
        staging.mkdir()
        owned_stage = True
        (staging / 'dist').mkdir()
        with zipfile.ZipFile(archive) as zipped:
            for info in zipped.infolist():
                dest = staging / 'dist' / info.filename
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(zipped.read(info))
        verify_tree(manifest, staging / 'dist')
        for name in ('release-manifest.json', 'release-manifest.sig'):
            shutil.copyfile(downloaded / name, staging / name)
        for parent, dirs, files in os.walk(staging, topdown=False):
            for name in files:
                item = Path(parent) / name
                with item.open('rb') as file:
                    os.fsync(file.fileno())
                item.chmod(item.stat().st_mode & ~0o222)
            fsync_dir(parent)
            Path(parent).chmod(Path(parent).stat().st_mode & ~0o222)
        os.replace(staging, target)
        owned_stage = False
        fsync_dir(target.parent)
        return target
    except ActivationError:
        raise
    except (OSError, ValueError, RuntimeError, zipfile.BadZipFile, subprocess.SubprocessError) as error:
        raise ActivationError('staging failed: ' + str(error)) from error
    finally:
        if owned_stage:
            remove_owned(staging)
        if owned_download:
            remove_owned(downloaded)


@contextlib.contextmanager
def locked(root):
    root = directory(root)
    fd = os.open(root / '.activation.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ActivationError('another activation is running') from error
        yield
    finally:
        os.close(fd)


def state_value(value):
    require(isinstance(value, dict) and set(value) == set(EMPTY), 'invalid release state')
    for name in ('active', 'rollback'):
        if value[name] is not None:
            component(value[name])
    if value['active'] is None:
        require(value == EMPTY, 'invalid empty state')
    else:
        require(isinstance(value['activeDigest'], str) and re.fullmatch('[0-9a-f]{64}', value['activeDigest']), 'invalid active digest')
        require(value['rollback'] != value['active'], 'invalid rollback state')
    return value


def snapshot(root):
    exists = os.path.lexists(root / 'state.json')
    return exists, state_value(read_json(root / 'state.json')) if exists else EMPTY.copy()


def target(root):
    path = root / 'current'
    if not os.path.lexists(path):
        return None
    require(path.is_symlink(), 'current must be a symlink')
    return os.readlink(path)


def consistent(root):
    require(not os.path.lexists(root / 'transition.json'), "previous activation was interrupted; run 'portal-view recover'")
    exists, state = snapshot(root)
    expected = 'releases/' + state['active'] if state['active'] else None
    require(target(root) == expected, 'inconsistent state/current; inspect before recovery')
    return exists, state


def status(root):
    root = directory(root)
    exists, state = snapshot(root)
    return dict(state=state, stateExists=exists, current=target(root),
                transition=read_json(root / 'transition.json') if os.path.lexists(root / 'transition.json') else None)


def poll(ctx, expected):
    for attempt in range(15):
        if ctx.runner.read_release_digest() == expected:
            return
        if attempt < 14:
            ctx.sleep(2)
    raise ActivationError('gateway release digest did not match after 15 readbacks')


def candidate(root, version, ctx):
    path = directory(directory(root / 'releases') / component(version))
    manifest = verify_signature(path, ctx.key_dir)
    require(manifest['version'] == version, 'staged version mismatch')
    verify_tree(manifest, path / 'dist')
    result = ctx.runner.validate_offline(path, ctx.runtime_config, ctx.key_dir, ctx.mount_path, ctx.handler_config)
    expected = digest((path / 'release-manifest.json').read_bytes())
    require(isinstance(result, dict) and result.get('status') == 'ok',
            'offline validation rejected release: ' + str(result.get('error', 'invalid result') if isinstance(result, dict) else 'invalid result'))
    require(result.get('version') == version and result.get('manifestDigest') == expected
            and type(result.get('capability')) is int and result['capability'] >= manifest.get('minimumGatewayCapability', 1), 'offline validation result mismatch')
    return expected


def journal_value(journal):
    require(isinstance(journal, dict) and set(journal) == {'format', 'priorStateExists', 'priorState', 'candidate', 'candidateDigest', 'pointerOnly'}
            and journal['format'] == 1 and type(journal['priorStateExists']) is bool
            and type(journal['pointerOnly']) is bool, 'invalid transition journal')
    prior = state_value(journal['priorState'])
    component(journal['candidate'])
    require(isinstance(journal['candidateDigest'], str) and re.fullmatch('[0-9a-f]{64}', journal['candidateDigest']), 'invalid journal digest')
    require(journal['priorStateExists'] or prior == EMPTY, 'invalid prior-state existence')
    require((prior['active'] is None) == journal['pointerOnly'], 'invalid transition mode')
    require(prior['active'] != journal['candidate'], 'invalid same-version transition')
    return journal


def restored_state(root, journal):
    if journal['priorStateExists']:
        atomic_json(root / 'state.json', journal['priorState'])
    elif os.path.lexists(root / 'state.json'):
        unlink_durable(root / 'state.json')


def restore(root, ctx, journal):
    journal_value(journal)
    prior = journal['priorState']
    published = dict(active=journal['candidate'], rollback=prior['active'], activeDigest=journal['candidateDigest'])
    exists, current_state = snapshot(root)
    require((exists == journal['priorStateExists'] and current_state == prior)
            or (exists and current_state == published), 'unexpected state; journal recovery refused')
    prior_pointer = 'releases/' + prior['active'] if prior['active'] else None
    candidate_pointer = 'releases/' + journal['candidate']
    require(target(root) in (prior_pointer, candidate_pointer), 'unexpected current; journal recovery refused')
    try:
        if journal['pointerOnly']:
            if target(root) == candidate_pointer:
                unlink_durable(root / 'current')
        else:
            # Verify the trusted retained A before recreating it, even after a
            # previous recovery attempt already restored the pointer.
            actual = candidate(root, prior['active'], ctx)
            require(actual == prior['activeDigest'], 'prior release digest mismatch')
            pointer(root, prior['active'])
            ctx.runner.recreate_gateways()
            poll(ctx, prior['activeDigest'])
        restored_state(root, journal)
        unlink_durable(root / 'transition.json')
    except Exception as error:
        if not os.path.lexists(root / 'transition.json'):
            atomic_json(root / 'transition.json', journal)
        destination = prior_pointer or '(remove only current -> ' + candidate_pointer + ')'
        raise RecoveryFailed('recovery failed; journal retained; restore current to ' + destination
                             + '; retry lt portal-view recover; manual Compose command after restoring pointer: '
                             + ctx.recreate_command + '; verify the prior digest and restore journal.priorState before removing the journal: ' + str(error)) from error


def _activate(version, root, ctx, pointer_only):
    version = component(version)
    exists, state = consistent(root)
    new_digest = candidate(root, version, ctx)
    if version == state['active']:
        require(new_digest == state['activeDigest'], 'active manifest digest mismatch')
        require(ctx.runner.read_release_digest() == state['activeDigest'],
                "gateway is not serving the active release; run 'portal-view recreate'")
        return
    if pointer_only:
        require(state['active'] is None, 'pointer-only replacement of an active release is refused')
    else:
        require(state['active'] is not None, 'first activation requires --pointer-only, then the UI cutover and recreate')
    journal = dict(format=1, priorStateExists=exists, priorState=state,
                   candidate=version, candidateDigest=new_digest, pointerOnly=pointer_only)
    atomic_json(root / 'transition.json', journal)
    try:
        pointer(root, version)
        if not pointer_only:
            ctx.runner.recreate_gateways()
            poll(ctx, new_digest)
        atomic_json(root / 'state.json', dict(active=version, rollback=state['active'], activeDigest=new_digest))
        unlink_durable(root / 'transition.json')
    except Exception as error:
        # If cleanup failed after unlink, re-create evidence before restoration.
        if not os.path.lexists(root / 'transition.json'):
            atomic_json(root / 'transition.json', journal)
        restore(root, ctx, journal)
        raise ActivationError('activation failed; prior release restored: ' + str(error)) from error


def activate(version, root, ctx, pointer_only=False):
    root = Path(root)
    with locked(root):
        _activate(version, root, ctx, pointer_only)


def rollback(root, ctx):
    root = Path(root)
    with locked(root):
        _, state = consistent(root)
        require(state['rollback'] is not None, 'no rollback release; for the first cutover use the UI rollback steps')
        _activate(state['rollback'], root, ctx, False)


def recover(root, ctx):
    root = Path(root)
    with locked(root):
        require(os.path.lexists(root / 'transition.json'), 'no transition to recover')
        restore(root, ctx, journal_value(read_json(root / 'transition.json')))


def recreate(root, ctx, expect_legacy=False):
    root = Path(root)
    with locked(root):
        _, state = consistent(root)
        require(expect_legacy or state['active'] is not None, 'no active release; use --expect-legacy for mount migration')
        try:
            ctx.runner.recreate_gateways()
            if expect_legacy:
                require(ctx.runner.gateway_healthy() and ctx.runner.read_release_digest() is None,
                        'legacy page health or absent digest check failed')
            else:
                poll(ctx, state['activeDigest'])
        except Exception as error:
            guidance = ('portal-view rollback is available' if state['rollback'] else
                        'first-cutover rollback: revert the Portal UI virtual-host change, publish its snapshot, then portal-view recreate --expect-legacy')
            raise ActivationError('recreate failed; ' + guidance + ': ' + str(error)) from error
