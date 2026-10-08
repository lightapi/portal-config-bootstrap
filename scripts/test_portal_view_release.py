# Provenance: portal-config-loc commit 2c511911d2f2ca20448b552e9a5f96b6a10ac799
# Portable WP11 bodies verbatim; local dispatch/Compose and Runner wiring tested separately.
"""WP11: signed temp fixtures; lifecycle, network and container effects are fakes."""
import contextlib
import fcntl
import importlib.util
import io
import json
import multiprocessing
import os
from pathlib import Path
import shutil
import ssl
import stat
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import Mock, patch
import warnings
import zipfile

import portal_view_release as r


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


cli = load('release_cli', 'portal-view-release.py')
ORIGINAL_RUN = subprocess.run
A, B, C = ('20261008-' + character * 12 for character in 'abc')


class Crash(BaseException):
    """A process interruption, deliberately bypassing ordinary failure recovery."""


def hold_lock(path, ready, done):
    with open(path, 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        ready.set()
        done.wait(10)


class Fake:
    def __init__(self):
        self.calls = []
        self.serving = None
        self.root = None
        self.failures = []
        self.readbacks = []
        self.offline_error = False
        self.healthy = True

    def validate_offline(self, path, runtime, keys, mount, handler):
        self.calls.append(('offline', path.name))
        if self.offline_error:
            return dict(status='error', error='schema rejected')
        return dict(status='ok', version=path.name, capability=1,
                    manifestDigest=r.digest((path / 'release-manifest.json').read_bytes()), runtimeConfigDigest='d' * 64)

    def recreate_gateways(self):
        self.calls.append(('recreate',))
        if self.failures:
            error = self.failures.pop(0)
            if error:
                raise error
        state = r.target(self.root)
        if state:
            self.serving = r.digest((self.root / state / 'release-manifest.json').read_bytes())

    def read_release_digest(self, timeout=10):
        self.calls.append(('head',))
        if self.readbacks:
            value = self.readbacks.pop(0)
            if isinstance(value, Exception):
                raise value
            return value
        return self.serving

    def gateway_healthy(self, timeout=10):
        self.calls.append(('get',))
        return self.healthy


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='wp11-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / 'lightapi'
        self.root.mkdir()
        self.keys = self.base / 'portal-view-release-keys'
        self.keys.mkdir()
        self.private = self.base / 'throwaway.pem'
        self.openssl(['genpkey', '-algorithm', 'ed25519', '-out', str(self.private)])
        self.openssl(['pkey', '-in', str(self.private), '-pubout', '-out', str(self.keys / 'test.pem')])
        self.fake = Fake()
        self.fake.root = self.root
        self.delay = Mock()
        self.ctx = r.Context(r.Runner(self.fake.validate_offline, self.fake.recreate_gateways,
                                     self.fake.read_release_digest, self.fake.gateway_healthy),
                             self.base / 'runtime.json', self.keys, sleep=self.delay)
        self.ctx.runtime_config.write_text('{}')
        self.guard = patch.object(subprocess, 'run', side_effect=self.guarded_run)
        self.guard.start()
        self.addCleanup(self.guard.stop)
        self.network_guard = patch.object(r.urllib.request, 'urlopen', side_effect=AssertionError('real download forbidden'))
        self.network_guard.start()
        self.addCleanup(self.network_guard.stop)
        self.addCleanup(self.make_writable)

    def make_writable(self):
        for parent, dirs, files in os.walk(self.base):
            os.chmod(parent, 0o700)

    def openssl(self, args):
        result = ORIGINAL_RUN(['openssl', *args], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def guarded_run(self, args, **kwargs):
        # No lifecycle or download executable can accidentally escape a mock.
        if args[0] == 'openssl':
            for arg in args[1:]:
                if arg.startswith('/'):
                    self.assertTrue(Path(arg).is_relative_to(self.base), args)
            return ORIGINAL_RUN(args, **kwargs)
        raise AssertionError('unguarded subprocess: ' + repr(args))

    def fixture(self, version=A, payload=b'portable', changes=None, extra=None):
        folder = self.base / ('source-' + version + '-' + str(len(list(self.base.iterdir()))))
        folder.mkdir()
        data = {'index.html': payload, 'portal-config.schema.json': b'{}', 'assets/app-12345678.js': b'export {}'}
        archive = folder / ('portal-view-' + version + '.zip')
        with warnings.catch_warnings():
            warnings.simplefilter('ignore', UserWarning)
            with zipfile.ZipFile(archive, 'w') as zipout:
                for name, value in data.items():
                    zipout.writestr(name, value)
                if extra:
                    for name, value, mode in extra:
                        info = zipfile.ZipInfo(name)
                        info.external_attr = mode << 16
                        zipout.writestr(info, value)
        manifest = dict(artifact='portal-view', manifestVersion=1, version=version,
                        minimumGatewayCapability=1, runtimeConfigSchemaVersions=[1],
                        signature=dict(algorithm='Ed25519', keyId='test'),
                        archive=dict(name=archive.name, sha256=r.digest(archive.read_bytes())),
                        members=[dict(path=name, size=len(value), sha256=r.digest(value),
                                      cacheClass='immutable' if name.startswith('assets/') else 'revalidate') for name, value in data.items()])
        if changes:
            changes(manifest)
        (folder / 'release-manifest.json').write_text(json.dumps(manifest) + '\n')
        self.sign(folder)
        return folder

    def sign(self, folder):
        self.openssl(['pkeyutl', '-sign', '-rawin', '-inkey', str(self.private),
                      '-in', str(folder / 'release-manifest.json'), '-out', str(folder / 'release-manifest.sig')])

    def stage(self, version=A):
        return r.stage(self.fixture(version), version, self.root, self.keys)

    def first(self):
        self.stage(A)
        r.activate(A, self.root, self.ctx, True)
        self.fake.calls.clear()
        return r.snapshot(self.root)[1]

    def active_pair(self):
        self.first()
        self.stage(B)
        r.activate(B, self.root, self.ctx)
        self.fake.calls.clear()
        return r.snapshot(self.root)[1]

    def assert_state(self, active, rollback):
        state = r.snapshot(self.root)[1]
        self.assertEqual(state, dict(active=active, rollback=rollback,
                                    activeDigest=r.digest((self.root / 'releases' / active / 'release-manifest.json').read_bytes())))
        self.assertEqual(r.target(self.root), 'releases/' + active)

    def capture_cli(self, args, factory=None):
        output, errors = io.StringIO(), io.StringIO()
        context = r.Context
        def fast_context(*values):
            return context(*values, sleep=self.delay)
        with patch.object(r, 'Context', side_effect=fast_context), patch.object(cli, 'ROOT', self.root), patch.object(cli, 'CONFIG', self.base), contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            result = cli.main(args, runner_factory=factory or (lambda url: self.fake))
        return result, output.getvalue(), errors.getvalue()

    def test_stage_idempotent_readonly_and_content_conflict(self):
        (self.root / 'dist').mkdir()
        (self.root / 'dist/index.html').write_bytes(b'legacy')
        source = self.fixture()
        path = r.stage(source, A, self.root, self.keys)
        inode = path.stat().st_ino
        self.assertEqual(r.stage(source, A, self.root, self.keys).stat().st_ino, inode)
        for item in [path, *path.rglob('*')]:
            self.assertEqual(item.stat().st_mode & 0o222, 0)
        with self.assertRaisesRegex(r.ActivationError, 'different content'):
            r.stage(self.fixture(payload=b'different'), A, self.root, self.keys)
        self.assertEqual((self.root / 'dist/index.html').read_bytes(), b'legacy')
        self.assertIsNone(r.target(self.root))
        self.assertFalse((self.root / 'state.json').exists())
        self.assertEqual(list((self.root / '.downloads').iterdir()), [])

    def test_signature_archive_member_and_path_rejections(self):
        changes = [lambda m: m['signature'].update(keyId='missing'),
                   lambda m: m['signature'].update(keyId='../test'),
                   lambda m: m['signature'].update(algorithm='RSA'),
                   lambda m: m['archive'].update(sha256='0' * 64),
                   lambda m: m['archive'].update(name='../bad.zip'),
                   lambda m: m['members'][0].update(sha256='0' * 64),
                   lambda m: m['members'][0].update(size=123),
                   lambda m: m['members'].append(m['members'][0]),
                   lambda m: m['members'][0].update(path='../bad'),
                   lambda m: m['members'][0].update(path='/absolute'),
                   lambda m: m['members'][0].update(path='a\\b'),
                   lambda m: m['members'].pop()]
        for change in changes:
            with self.subTest(change=change):
                with self.assertRaises((r.ActivationError, OSError)):
                    r.stage(self.fixture(changes=change), A, self.root, self.keys)
                self.assertFalse((self.root / 'releases' / A).exists())
                self.assertFalse((self.root / 'releases' / (A + '.staging')).exists())
        for name, mode in [('extra', stat.S_IFREG), ('index.html', stat.S_IFREG),
                           ('link', stat.S_IFLNK), ('/bad', stat.S_IFREG), ('../bad', stat.S_IFREG),
                           ('a\\b', stat.S_IFREG), ('fifo', stat.S_IFIFO)]:
            with self.subTest(name=name, mode=mode):
                with self.assertRaises(r.ActivationError):
                    r.stage(self.fixture(extra=[(name, b'x', mode)]), A, self.root, self.keys)
                self.assertFalse((self.root / 'releases' / A).exists())
        source = self.fixture()
        (source / 'release-manifest.sig').write_bytes(b'bad')
        with self.assertRaisesRegex(r.ActivationError, 'signature'):
            r.stage(source, A, self.root, self.keys)

    def test_bad_archive_bytes_and_missing_member(self):
        source = self.fixture()
        with zipfile.ZipFile(source / ('portal-view-' + A + '.zip'), 'w') as archive:
            archive.writestr('index.html', b'bad')
        manifest = r.read_json(source / 'release-manifest.json')
        manifest['archive']['sha256'] = r.digest((source / manifest['archive']['name']).read_bytes())
        (source / 'release-manifest.json').write_text(json.dumps(manifest))
        self.sign(source)
        with self.assertRaises(r.ActivationError):
            r.stage(source, A, self.root, self.keys)
        manifest['members'] = manifest['members'][1:]
        (source / 'release-manifest.json').write_text(json.dumps(manifest))
        self.sign(source)
        with self.assertRaises(r.ActivationError):
            r.stage(source, A, self.root, self.keys)

    def test_unsafe_local_content_and_owned_cleanup(self):
        source = self.fixture()
        sig = source / 'release-manifest.sig'
        outside = self.base / 'outside'
        sig.rename(outside)
        sig.symlink_to(outside)
        with self.assertRaises(r.ActivationError):
            r.stage(source, A, self.root, self.keys)
        self.assertTrue(outside.exists())
        unknown = self.root / 'releases' / (A + '.staging')
        unknown.mkdir()
        (unknown / 'retained').write_text('keep')
        with self.assertRaises(r.ActivationError):
            r.stage(self.fixture(), A, self.root, self.keys)
        self.assertEqual((unknown / 'retained').read_text(), 'keep')

    def test_first_pointer_only_and_replacement_refusal(self):
        self.first()
        self.assert_state(A, None)
        self.assertFalse(any(c[0] in ('recreate', 'head') for c in self.fake.calls))
        self.stage(B)
        with self.assertRaisesRegex(r.ActivationError, 'pointer-only replacement'):
            r.activate(B, self.root, self.ctx, True)
        self.assert_state(A, None)
        self.assertFalse((self.root / 'transition.json').exists())

    def test_same_pointer_only_before_cutover_requires_digest(self):
        self.first()
        prior = (self.root / 'state.json').read_bytes()
        inode = (self.root / 'current').lstat().st_ino
        with self.assertRaisesRegex(r.ActivationError, 'not serving'):
            r.activate(A, self.root, self.ctx, True)
        self.assertEqual(self.fake.calls, [('offline', A), ('head',)])
        self.assertEqual((self.root / 'state.json').read_bytes(), prior)
        self.assertEqual((self.root / 'current').lstat().st_ino, inode)
        self.fake.serving = r.snapshot(self.root)[1]['activeDigest']
        r.activate(A, self.root, self.ctx, True)
        self.assert_state(A, None)

    def test_first_normal_activation_refused(self):
        self.stage(A)
        with self.assertRaisesRegex(r.ActivationError, '--pointer-only'):
            r.activate(A, self.root, self.ctx)
        self.assertIsNone(r.target(self.root))
        self.assertFalse((self.root / 'state.json').exists())

    def test_offline_rejection_before_mutation(self):
        self.first()
        self.stage(B)
        before = (self.root / 'state.json').read_bytes()
        self.fake.offline_error = True
        with self.assertRaisesRegex(r.ActivationError, 'schema rejected'):
            r.activate(B, self.root, self.ctx)
        self.assertEqual(self.fake.calls, [('offline', B)])
        self.assertEqual((self.root / 'state.json').read_bytes(), before)
        self.assert_state(A, None)

    def test_success_and_same_version_preserves_rollback_and_inode(self):
        self.first()
        self.stage(B)
        r.activate(B, self.root, self.ctx)
        self.assertEqual(self.fake.calls, [('offline', B), ('recreate',), ('head',)])
        self.fake.calls.clear()
        self.assert_state(B, A)
        before = (self.root / 'state.json').read_bytes()
        inode = (self.root / 'current').lstat().st_ino
        r.activate(B, self.root, self.ctx)
        self.assertEqual(self.fake.calls, [('offline', B), ('head',)])
        self.assertEqual((self.root / 'state.json').read_bytes(), before)
        self.assertEqual((self.root / 'current').lstat().st_ino, inode)
        self.assertFalse((self.root / 'transition.json').exists())

    def test_failed_startup_restores_a(self):
        self.first()
        self.stage(B)
        self.fake.failures = [RuntimeError('startup')]
        code, _, errors = self.capture_cli(['activate', '--version', B])
        self.assertEqual(code, 2)
        self.assertIn('PORTAL_VIEW_ACTIVATION_REFUSED:', errors)
        self.assert_state(A, None)
        self.assertEqual(self.fake.calls, [('offline', B), ('recreate',), ('offline', A), ('recreate',), ('head',)])
        self.assertFalse((self.root / 'transition.json').exists())

    def test_readiness_timeout_restores_a(self):
        self.first()
        self.stage(B)
        self.fake.failures = [TimeoutError('readiness')]
        with self.assertRaises(r.ActivationError):
            r.activate(B, self.root, self.ctx)
        self.assert_state(A, None)
        self.assertEqual(sum(c[0] == 'recreate' for c in self.fake.calls), 2)

    def test_readback_limit_and_restore(self):
        self.first()
        self.stage(B)
        self.fake.readbacks = [None] * 15
        with self.assertRaises(r.ActivationError):
            r.activate(B, self.root, self.ctx)
        self.assert_state(A, None)
        self.assertEqual(sum(c[0] == 'head' for c in self.fake.calls), 16)
        self.assertEqual(self.delay.call_args_list, [unittest.mock.call(2)] * 14)

    def test_failed_restore_retains_evidence_and_later_recovery(self):
        prior = self.active_pair()
        self.stage(C)
        self.fake.failures = [RuntimeError('startup'), RuntimeError('restore')]
        code, _, errors = self.capture_cli(['activate', '--version', C])
        self.assertEqual(code, 3)
        self.assertIn('PORTAL_VIEW_RECOVERY_FAILED:', errors)
        self.assertIn('docker compose --project-name all-in-lt', errors)
        self.assertIn('restore current to releases/' + B, errors)
        journal = r.read_json(self.root / 'transition.json')
        self.assertEqual(journal['priorState'], prior)
        self.assertTrue(journal['priorStateExists'])
        self.assertEqual(r.target(self.root), 'releases/' + B)
        self.fake.calls.clear()
        code, _, _ = self.capture_cli(['recover'])
        self.assertEqual(code, 0)
        self.assert_state(B, A)
        self.assertEqual(self.fake.calls, [('offline', B), ('recreate',), ('head',)])
        self.assertFalse((self.root / 'transition.json').exists())

    def test_rollback_swaps_and_null_guidance(self):
        self.first()
        code, _, errors = self.capture_cli(['rollback'])
        self.assertEqual(code, 2)
        self.assertIn('UI rollback', errors)
        self.stage(B)
        r.activate(B, self.root, self.ctx)
        r.rollback(self.root, self.ctx)
        self.assert_state(A, B)
        r.rollback(self.root, self.ctx)
        self.assert_state(B, A)

    def test_inconsistent_state_and_transition_refused(self):
        self.first()
        r.pointer(self.root, B)
        code, _, _ = self.capture_cli(['activate', '--version', A])
        self.assertEqual(code, 2)
        self.assertEqual(self.fake.calls, [])
        r.pointer(self.root, A)
        r.atomic_json(self.root / 'transition.json', {'unknown': True})
        for command in (['activate', '--version', A], ['rollback'], ['recreate']):
            self.assertEqual(self.capture_cli(command)[0], 2)
        self.assertEqual(self.fake.calls, [])
        self.assertEqual(r.read_json(self.root / 'transition.json'), {'unknown': True})

    def test_other_process_lock_covers_all_mutating_commands(self):
        self.first()
        context = multiprocessing.get_context('fork')
        ready, done = context.Event(), context.Event()
        child = context.Process(target=hold_lock, args=(self.root / '.activation.lock', ready, done))
        child.start()
        try:
            self.assertTrue(ready.wait(5))
            for args in (['activate', '--version', A], ['rollback'], ['recover'], ['recreate', '--expect-legacy']):
                code, _, errors = self.capture_cli(args)
                self.assertEqual(code, 2)
                self.assertIn('another activation', errors)
            self.assertEqual(self.fake.calls, [])
        finally:
            done.set()
            child.join(5)
            if child.is_alive():
                child.terminate()
                child.join()
        self.assertEqual(child.exitcode, 0)

    def test_first_cutover_failure_and_legacy_checks(self):
        self.first()
        self.fake.failures = [RuntimeError('start')]
        code, _, errors = self.capture_cli(['recreate'])
        self.assertEqual(code, 2)
        self.assertIn('publish its snapshot', errors)
        self.assertIn('--expect-legacy', errors)
        self.assert_state(A, None)
        self.fake.recreate_gateways = lambda: self.fake.calls.append(('recreate',))
        self.ctx.runner.recreate_gateways = self.fake.recreate_gateways
        self.fake.calls.clear()
        r.recreate(self.root, self.ctx, True)
        self.assertEqual(self.fake.calls, [('recreate',), ('get',), ('head',)])
        self.fake.serving = 'a' * 64
        with self.assertRaisesRegex(r.ActivationError, 'legacy'):
            r.recreate(self.root, self.ctx, True)

    def test_recreate_with_rollback_guidance(self):
        self.active_pair()
        self.fake.failures = [RuntimeError('start')]
        code, _, errors = self.capture_cli(['recreate'])
        self.assertEqual(code, 2)
        self.assertIn('portal-view rollback is available', errors)
        self.assert_state(B, A)

    def interrupt(self, boundary, version, first=False):
        original_write, original_pointer = r.atomic_json, r.pointer
        def writing(path, value):
            original_write(path, value)
            if path.name == boundary:
                raise Crash(boundary)
        def pointing(root, selected):
            original_pointer(root, selected)
            if boundary == 'pointer':
                raise Crash(boundary)
        with patch.object(r, 'atomic_json', side_effect=writing), patch.object(r, 'pointer', side_effect=pointing):
            with self.assertRaises(Crash):
                r.activate(version, self.root, self.ctx, first)
        self.assertTrue((self.root / 'transition.json').exists())

    def test_interruption_after_journal_creation(self):
        prior = self.active_pair()
        self.stage(C)
        self.interrupt('transition.json', C)
        self.assertEqual(r.snapshot(self.root)[1], prior)
        self.assertEqual(r.target(self.root), 'releases/' + B)
        r.recover(self.root, self.ctx)
        self.assert_state(B, A)

    def test_interruption_after_pointer_change(self):
        prior = self.active_pair()
        self.stage(C)
        self.interrupt('pointer', C)
        self.assertEqual(r.snapshot(self.root)[1], prior)
        self.assertEqual(r.target(self.root), 'releases/' + C)
        r.recover(self.root, self.ctx)
        self.assert_state(B, A)

    def test_interruption_after_state_publication_and_during_recovery(self):
        prior = self.active_pair()
        self.stage(C)
        self.interrupt('state.json', C)
        self.assert_state(C, B)
        write = r.atomic_json
        def crash_after_restore(path, value):
            write(path, value)
            if path.name == 'state.json':
                raise Crash('recovery state published')
        with patch.object(r, 'atomic_json', side_effect=crash_after_restore):
            with self.assertRaises(Crash):
                r.recover(self.root, self.ctx)
        self.assertEqual(r.snapshot(self.root)[1], prior)
        self.assertTrue((self.root / 'transition.json').exists())
        r.recover(self.root, self.ctx)
        self.assert_state(B, A)
        self.assertFalse((self.root / 'transition.json').exists())

    def test_interrupted_recovery_pointer_and_readback_failure_retriable(self):
        self.first()
        self.stage(B)
        self.interrupt('pointer', B)
        pointing = r.pointer
        def crash_after_pointer(root, version):
            pointing(root, version)
            raise Crash('restore pointer')
        with patch.object(r, 'pointer', side_effect=crash_after_pointer):
            with self.assertRaises(Crash):
                r.recover(self.root, self.ctx)
        self.assertTrue((self.root / 'transition.json').exists())
        self.fake.readbacks = [None] * 15
        self.assertEqual(self.capture_cli(['recover'])[0], 3)
        self.assertTrue((self.root / 'transition.json').exists())
        self.assertEqual(self.capture_cli(['recover'])[0], 0)
        self.assert_state(A, None)

    def test_first_pointer_interruption_boundaries_and_no_io_recovery(self):
        self.stage(A)
        for boundary in ('transition.json', 'pointer', 'state.json'):
            with self.subTest(boundary=boundary):
                self.interrupt(boundary, A, True)
                self.fake.calls.clear()
                r.recover(self.root, self.ctx)
                self.assertEqual(self.fake.calls, [])
                self.assertIsNone(r.target(self.root))
                self.assertFalse((self.root / 'state.json').exists())
                self.assertFalse((self.root / 'transition.json').exists())
        r.atomic_json(self.root / 'state.json', r.EMPTY)
        self.interrupt('state.json', A, True)
        r.recover(self.root, self.ctx)
        self.assertTrue((self.root / 'state.json').exists())
        self.assertEqual(r.snapshot(self.root)[1], r.EMPTY)

    def test_first_recovery_interrupted_after_pointer_removal(self):
        self.stage(A)
        self.interrupt('state.json', A, True)
        unlink = r.unlink_durable
        def crash_after_unlink(path):
            unlink(path)
            if path.name == 'current':
                raise Crash('removed candidate pointer')
        self.fake.calls.clear()
        with patch.object(r, 'unlink_durable', side_effect=crash_after_unlink):
            with self.assertRaises(Crash):
                r.recover(self.root, self.ctx)
        r.recover(self.root, self.ctx)
        self.assertEqual(self.fake.calls, [])
        self.assertFalse((self.root / 'state.json').exists())

    def test_journal_cleanup_failure_retains_retriable_evidence(self):
        self.first()
        self.stage(B)
        self.interrupt('state.json', B)
        unlink = r.unlink_durable
        def fail_after_cleanup(path):
            unlink(path)
            if path.name == 'transition.json':
                raise OSError('directory fsync failed')
        with patch.object(r, 'unlink_durable', side_effect=fail_after_cleanup):
            with self.assertRaises(r.RecoveryFailed):
                r.recover(self.root, self.ctx)
        self.assertTrue((self.root / 'transition.json').exists())
        self.assert_state(A, None)
        r.recover(self.root, self.ctx)
        self.assertFalse((self.root / 'transition.json').exists())

    def test_journal_and_state_atomic_write_failure_and_fsyncs(self):
        self.stage(A)
        replace = os.replace
        def fail_state(src, dest):
            if Path(dest).name == 'state.json':
                raise OSError('state write failed')
            return replace(src, dest)
        with patch.object(os, 'replace', side_effect=fail_state), patch.object(os, 'fsync', wraps=os.fsync) as sync:
            with self.assertRaises(r.ActivationError):
                r.activate(A, self.root, self.ctx, True)
        self.assertGreaterEqual(sync.call_count, 5)
        self.assertIsNone(r.target(self.root))
        self.assertFalse((self.root / 'state.json').exists())
        self.assertFalse((self.root / 'transition.json').exists())
        self.assertFalse(any(p.name.startswith('.state.json.') for p in self.root.iterdir()))
        def fail_journal(src, dest):
            if Path(dest).name == 'transition.json':
                raise OSError('journal write failed')
            return replace(src, dest)
        with patch.object(os, 'replace', side_effect=fail_journal):
            with self.assertRaises(OSError):
                r.activate(A, self.root, self.ctx, True)
        self.assertIsNone(r.target(self.root))
        self.assertFalse((self.root / 'state.json').exists())

    def test_recovery_refuses_unexpected_pointer_or_state(self):
        self.stage(A)
        self.interrupt('pointer', A, True)
        r.pointer(self.root, B)
        before = (self.root / 'transition.json').read_bytes()
        self.assertEqual(self.capture_cli(['recover'])[0], 2)
        self.assertEqual(r.target(self.root), 'releases/' + B)
        r.pointer(self.root, A)
        r.atomic_json(self.root / 'state.json', dict(active=B, rollback=None, activeDigest='a' * 64))
        self.assertEqual(self.capture_cli(['recover'])[0], 2)
        self.assertEqual((self.root / 'transition.json').read_bytes(), before)
        self.assertEqual(self.fake.calls, [('offline', A)])

    def test_staged_tree_tampering_rejected_before_offline(self):
        path = self.stage()
        item = path / 'dist/index.html'
        item.chmod(0o600)
        item.write_bytes(b'tampered')
        with self.assertRaises(r.ActivationError):
            r.activate(A, self.root, self.ctx, True)
        self.assertEqual(self.fake.calls, [])
        item.parent.chmod(0o700)
        item.unlink()
        item.symlink_to(self.ctx.runtime_config)
        with self.assertRaises(r.ActivationError):
            r.activate(A, self.root, self.ctx, True)
        self.assertEqual(self.fake.calls, [])

    def test_remote_selection_explicit_versions_and_mock_download(self):
        args = types.SimpleNamespace(from_dir=None)
        with self.assertRaisesRegex(r.ActivationError, 'LIGHT_PORTAL_VERSION'):
            cli.source_for(args, {})
        for version in ('../x', '..', '.', 'x/y', 'x\\y', 'x%2fy', 'x?y', 'x y'):
            with self.assertRaises(r.ActivationError):
                cli.source_for(args, {'LIGHT_PORTAL_VERSION': version})
        source = self.fixture()
        urls = []
        def download(url, dest):
            urls.append(url)
            shutil.copyfile(source / url.rsplit('/', 1)[1], dest)
        remote = cli.source_for(args, {'LIGHT_PORTAL_VERSION': '2.6.0', 'LIGHT_PORTAL_ASSET_BASE_URL': 'https://example.test'})
        self.assertIn('/.rc-1/', cli.source_for(args, {'LIGHT_PORTAL_VERSION': '.rc-1'}))
        r.stage(remote, A, self.root, self.keys, downloader=download)
        self.assertEqual(urls, [remote + '/' + name for name in ('portal-view-' + A + '.zip', 'release-manifest.json', 'release-manifest.sig')])
        self.assertNotIn(A, remote)
        for version in ('../x', '/x', 'x\\y', 'x%2fy'):
            with self.assertRaises(r.ActivationError):
                r.stage(remote, version, self.root, self.keys, downloader=download)

    def test_download_failure_owned_paths_only(self):
        retained = self.root / 'retained'
        retained.write_text('keep')
        def fail(url, dest):
            dest.write_bytes(b'partial')
            raise OSError('download failed')
        with self.assertRaises(r.ActivationError):
            r.stage('https://example.test/release', A, self.root, self.keys, downloader=fail)
        self.assertFalse((self.root / '.downloads' / A).exists())
        self.assertEqual(retained.read_text(), 'keep')
        stale = self.root / '.downloads' / A
        stale.mkdir()
        (stale / 'keep').write_text('old')
        with self.assertRaises(r.ActivationError):
            r.stage('https://example.test', A, self.root, self.keys, downloader=fail)
        self.assertEqual((stale / 'keep').read_text(), 'old')

    def test_status_usage_and_stage_do_not_construct_real_runner(self):
        factory = Mock(side_effect=AssertionError('runner construction forbidden'))
        code, output, _ = self.capture_cli(['status'], factory)
        self.assertEqual(code, 0)
        self.assertIn('"active": null', output)
        self.assertEqual(self.capture_cli(['activate'], factory)[0], 1)
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(self.capture_cli(['stage', '--version', A], factory)[0], 2)
        self.assertEqual(self.capture_cli(['stage', '--version', A, '--from-dir', str(self.fixture())], factory)[0], 0)
        factory.assert_not_called()


    def test_imports_have_no_subprocess_or_network_effects(self):
        with patch.object(subprocess, 'run', side_effect=AssertionError('import subprocess')), patch.object(r.urllib.request, 'build_opener', side_effect=AssertionError('import network')):
            load('import_release_cli', 'portal-view-release.py')
            # Execute the library afresh, registering for dataclass introspection.
            spec = importlib.util.spec_from_file_location('import_release_lib', Path(r.__file__))
            module = importlib.util.module_from_spec(spec)
            with patch.dict(sys.modules, {'import_release_lib': module}):
                spec.loader.exec_module(module)

    def test_interrupted_download_or_staging_is_preserved_with_recovery_hint(self):
        source = self.fixture()
        for leftover in (self.root / '.downloads' / A, self.root / 'releases' / (A + '.staging')):
            leftover.parent.mkdir(parents=True, exist_ok=True)
            leftover.mkdir()
            (leftover / 'unknown').write_bytes(b'operator data')
            with self.assertRaisesRegex(r.ActivationError, 'interrupted staging run.*remove it, then retry'):
                r.stage(source, A, self.root, self.keys)
            self.assertEqual((leftover / 'unknown').read_bytes(), b'operator data')
            self.assertFalse((self.root / 'releases' / A).exists())
            (leftover / 'unknown').unlink()
            leftover.rmdir()
        self.assertEqual(r.stage(source, A, self.root, self.keys), self.root / 'releases' / A)

    def test_readback_path_follows_canonical_mount(self):
        for mount, path in (('/', '/'), ('/portal', '/portal/'), ('/ai/portal', '/ai/portal/')):
            self.assertEqual(r.readback_path(mount), path)
        for mount in ('', 'portal', '//', '/portal/', '/a//b', '/a/../b', '/./a', '/a?b', '/a#b', '/a b', None):
            with self.assertRaisesRegex(r.ActivationError, 'invalid mount path'):
                r.readback_path(mount)

    def test_library_prepare_never_reads_back(self):
        self.stage(A)
        self.assertEqual(r.prepare(A, self.root, self.ctx), ('prepared', None))
        self.assertNotIn(('head',), self.fake.calls)
        state = r.snapshot(self.root)[1]
        self.fake.calls.clear()
        self.assertEqual(r.prepare(A, self.root, self.ctx), ('unchanged', A))
        self.stage(B)
        self.assertEqual(r.prepare(B, self.root, self.ctx), ('staged', A))
        self.assertEqual(self.fake.calls, [('offline', A), ('offline', B)])
        self.assertEqual(r.snapshot(self.root)[1], state)
        self.assertEqual(r.target(self.root), 'releases/' + A)


if __name__ == '__main__':
    unittest.main()
