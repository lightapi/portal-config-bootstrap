"""WP12 adapters: temporary signed fixtures, injected effects and blocked tools."""
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import types
import unittest
from unittest.mock import Mock, patch
import urllib.error
import zipfile

import test_portal_view_release as portable

cli = portable.cli
r = portable.r
REPO = Path(__file__).resolve().parents[1]
ORIGINAL_RUN = subprocess.run


def response(data, status=200, headers=None):
    result = Mock(status=status, headers=headers or {})
    result.read.side_effect = io.BytesIO(data).read
    result.__enter__ = Mock(return_value=result)
    result.__exit__ = Mock(return_value=False)
    return result


def snapshot(parent):
    result = {}
    for item in parent.rglob('*'):
        if item.is_symlink():
            result[str(item.relative_to(parent))] = ('link', os.readlink(item))
        elif item.is_file():
            result[str(item.relative_to(parent))] = ('file', item.read_bytes())
    return result


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.fixture = portable.ReleaseTests('runTest')
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.base = self.fixture.base
        self.root = self.fixture.root
        self.fake = self.fixture.fake
        self.fake.ensure_image = Mock()
        self.fake.recreate_command = 'docker compose up -d --no-deps --force-recreate light-gateway'
        self.config = self.base / 'config'
        self.config.mkdir()
        self.fixture.ctx.runtime_config = self.config / 'portal-config.json'
        self.fixture.ctx.runtime_config.write_text('{}')
        (self.config / 'portal-view-release-keys').symlink_to(self.fixture.keys, target_is_directory=True)
        # The library requires a real trust directory, not a symlink.
        (self.config / 'portal-view-release-keys').unlink()
        shutil.copytree(self.fixture.keys, self.config / 'portal-view-release-keys')
        for name, value in [('BASE', self.base), ('ROOT', self.root), ('CONFIG', self.config)]:
            guard = patch.object(cli, name, value)
            guard.start()
            self.addCleanup(guard.stop)
        self.transport = Mock()
        self.factory = Mock(return_value=self.fake)

    def serve(self, version=portable.A, tampered=False):
        folder = self.fixture.fixture(version)
        if tampered:
            (folder / 'release-manifest.sig').write_bytes(b'invalid')
        def fetch(url, timeout):
            if url.endswith('portal-view-release.env'):
                return response(('PORTAL_VIEW_VERSION=' + version + '\n').encode())
            return response((folder / url.rsplit('/', 1)[1]).read_bytes())
        self.transport.open.side_effect = fetch
        return folder

    def prepare(self):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            cli.prepare('2.6.0', 'https://cdn.example/releases', self.factory, self.transport)

    def test_real_runner_acquisition_precedes_offline_preparation(self):
        self.serve()
        if cli.MODE == 'bootstrap':
            (self.base / '.env.bootstrap').write_text('COMPOSE_PROJECT_NAME=fixture-project\n')
        calls = []
        def execute(args, **kwargs):
            calls.append(args)
            if args[:2] == ['docker', 'compose']:
                return subprocess.CompletedProcess(args, 0, json.dumps({'services': {'light-gateway': {'image': 'exact@sha256:' + 'a' * 64}}}), '')
            if args[:3] == ['docker', 'image', 'inspect']:
                count = sum(c[:3] == ['docker', 'image', 'inspect'] for c in calls)
                return subprocess.CompletedProcess(args, 1 if count == 1 else 0, '', 'No such image' if count == 1 else '')
            if args[:2] == ['docker', 'pull']:
                return subprocess.CompletedProcess(args, 0, '', '')
            if args[:2] == ['docker', 'run']:
                manifest = self.root / 'releases' / portable.A / 'release-manifest.json'
                return subprocess.CompletedProcess(args, 0, json.dumps(dict(status='ok', capability=1, version=portable.A, manifestDigest=r.digest(manifest.read_bytes()), runtimeConfigDigest='d' * 64)), '')
            raise AssertionError('unexpected effect: ' + repr(args))
        factory = lambda url: cli.RealRunner('https://fixture.example/', execute=execute, opener_factory=Mock(side_effect=AssertionError('first preparation must not read back')))
        with patch.dict(os.environ, {'LIGHT_PORTAL_ENV_FILE': str(self.base / 'none'), 'BOOTSTRAP_ENV_FILE': str(self.base / '.env.bootstrap')}, clear=True), contextlib.redirect_stdout(io.StringIO()):
            cli.prepare('2.6.0', 'https://cdn.example/releases', factory, self.transport)
        self.assertEqual([c[:3] for c in calls], [['docker', 'compose', *calls[0][2:3]], ['docker', 'image', 'inspect'], ['docker', 'pull', 'exact@sha256:' + 'a' * 64], ['docker', 'image', 'inspect'], ['docker', 'run', '--rm']])
        self.assertEqual(r.target(self.root), 'releases/' + portable.A)
        self.assertFalse((self.root / 'transition.json').exists())

    def test_same_active_pull_failure_preserves_existing_release_and_state(self):
        self.serve()
        self.prepare()
        before = snapshot(self.root)
        self.fake.calls.clear()
        self.fake.ensure_image.side_effect = r.ActivationError('pull failed')
        with self.assertRaises(r.ActivationError):
            self.prepare()
        self.assertEqual(snapshot(self.root), before)
        self.assertEqual(self.fake.calls, [])

    def test_default_readback_uses_effective_compose_published_port(self):
        if cli.MODE == 'bootstrap':
            (self.base / '.env.bootstrap').write_text('COMPOSE_PROJECT_NAME=fixture-project\n')
        execute = Mock(return_value=subprocess.CompletedProcess([], 0, json.dumps({'services': {'light-gateway': {'image': 'configured:test', 'ports': [{'target': 8443, 'published': '9443'}]}}}), ''))
        with patch.dict(os.environ, {'LIGHT_PORTAL_ENV_FILE': str(self.base / 'none'), 'BOOTSTRAP_ENV_FILE': str(self.base / '.env.bootstrap')}, clear=True):
            runner = cli.RealRunner(execute=execute)
        expected = 'https://dev.lightapi.net:9443/' if cli.MODE == 'dev' else 'https://local.localhost:9443/'
        self.assertEqual(runner.url, expected)

    def test_absent_signed_release_has_no_pointer_runner_or_pull(self):
        self.transport.open.side_effect = urllib.error.HTTPError('https://example', 404, 'absent', {}, None)
        self.prepare()
        self.factory.assert_not_called()
        self.assertFalse((self.root / 'current').exists())
        self.fake.ensure_image.assert_not_called()

    def test_present_distinct_versions_verified_and_first_pointer_only(self):
        legacy = self.root / 'dist'
        legacy.mkdir()
        (legacy / 'index.html').write_bytes(b'legacy user_type=C')
        self.serve()
        self.prepare()
        self.assertEqual(r.target(self.root), 'releases/' + portable.A)
        self.assertEqual((legacy / 'index.html').read_bytes(), b'legacy user_type=C')
        self.assertEqual(self.fake.calls, [('offline', portable.A)])
        self.fake.ensure_image.assert_called_once_with()
        urls = [call.args[0] for call in self.transport.open.call_args_list]
        prefix = 'https://cdn.example/releases/2.6.0/portal-view/'
        self.assertEqual(urls, [prefix + name for name in ('portal-view-release.env', 'portal-view-' + portable.A + '.zip', 'release-manifest.json', 'release-manifest.sig')])

    def test_bad_verification_prevents_signed_extraction_and_image_acquisition(self):
        self.serve(tampered=True)
        with self.assertRaises(r.ActivationError):
            self.prepare()
        self.assertFalse((self.root / 'releases' / portable.A).exists())
        self.factory.assert_not_called()
        self.assertFalse((self.root / 'current').exists())

    def test_same_version_repeat_verifies_offline_without_readback(self):
        self.serve()
        self.prepare()
        state = (self.root / 'state.json').read_bytes()
        inode = (self.root / 'state.json').stat().st_ino
        for serving in (None, r.TransientReadbackError('connection refused')):
            # Legacy serving before cutover, or a stopped gateway: neither is read back.
            self.fake.calls.clear()
            self.fake.readbacks = [serving]
            self.prepare()
            self.assertEqual(self.fake.calls, [('offline', portable.A)])
            self.assertEqual((self.root / 'state.json').read_bytes(), state)
            self.assertEqual((self.root / 'state.json').stat().st_ino, inode)
            self.assertEqual(r.target(self.root), 'releases/' + portable.A)
        self.fake.offline_error = True
        with self.assertRaisesRegex(r.ActivationError, 'offline validation rejected'):
            self.prepare()
        self.assertEqual((self.root / 'state.json').read_bytes(), state)

    def test_different_active_version_stages_validates_warns_and_keeps_state(self):
        self.serve()
        self.prepare()
        self.serve(portable.B)
        state = (self.root / 'state.json').read_bytes()
        self.fake.calls.clear()
        self.fake.ensure_image.reset_mock()
        warning = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(warning):
            cli.prepare('2.6.0', 'https://cdn.example/releases', self.factory, self.transport)
        self.assertEqual(self.fake.calls, [('offline', portable.B)])
        self.fake.ensure_image.assert_called_once()
        self.assertTrue((self.root / 'releases' / portable.B / 'dist').is_dir())
        self.assertEqual((self.root / 'state.json').read_bytes(), state)
        self.assertEqual(r.target(self.root), 'releases/' + portable.A)
        self.assertFalse((self.root / 'transition.json').exists())
        self.assertIn('WARNING', warning.getvalue())
        self.assertIn('activate --version ' + portable.B, warning.getvalue())

    def test_different_active_version_invalid_candidate_refuses_without_state_change(self):
        self.serve()
        self.prepare()
        self.serve(portable.B)
        state = (self.root / 'state.json').read_bytes()
        self.fake.offline_error = True
        with self.assertRaisesRegex(r.ActivationError, 'offline validation rejected'):
            self.prepare()
        self.assertEqual((self.root / 'state.json').read_bytes(), state)
        self.assertEqual(r.target(self.root), 'releases/' + portable.A)

    def test_image_acquisition_failure_retains_staged_but_unprepared_candidate(self):
        self.serve()
        self.fake.ensure_image.side_effect = r.ActivationError('pull failed')
        with self.assertRaisesRegex(r.ActivationError, 'pull failed'):
            self.prepare()
        self.assertTrue((self.root / 'releases' / portable.A).is_dir())
        self.assertFalse((self.root / 'current').exists())
        self.assertFalse((self.root / 'state.json').exists())
        self.assertFalse((self.root / 'transition.json').exists())
        self.assertEqual(self.fake.calls, [])

    def test_metadata_failure_is_never_legacy_success_or_executed(self):
        for code in (401, 403, 429, 500, 503):
            self.transport.open.side_effect = urllib.error.HTTPError('https://example', code, 'failure', {}, None)
            with self.assertRaises(r.ActivationError):
                self.prepare()
        self.transport.open.side_effect = OSError('transport failure')
        with self.assertRaises(OSError):
            self.prepare()
        for data in (b'', b'PORTAL_VIEW_VERSION=../x\n', b'PORTAL_VIEW_VERSION=$(touch /tmp/never)\n', b'PORTAL_VIEW_VERSION=x\nBAD=1\n', b'PORTAL_VIEW_VERSION=x; echo bad\n', b'PORTAL_VIEW_VERSION=x\nPORTAL_VIEW_VERSION=y\n', b'export PORTAL_VIEW_VERSION=x', b'\xff', b'x' * 4097):
            with self.assertRaises(r.ActivationError):
                cli.metadata_version(data)
        self.factory.assert_not_called()
        with self.assertRaises(r.ActivationError):
            cli.NoRedirect().redirect_request(None, None, 302, '', {}, 'https://other/')

    def test_retained_transition_is_refused_without_recovery(self):
        self.serve()
        (self.root / 'transition.json').write_text('{"retained": true}')
        (self.root / '.activation.lock').write_bytes(b'retained lock')
        before = snapshot(self.root)
        with self.assertRaisesRegex(r.ActivationError, 'interrupted'):
            self.prepare()
        self.factory.assert_not_called()
        self.assertEqual(snapshot(self.root), before)

    def runner(self, execute=None, opener=None):
        if cli.MODE == 'bootstrap':
            (self.base / '.env.bootstrap').write_text('COMPOSE_PROJECT_NAME=fixture-project\n')
        self.execute = execute or Mock(return_value=subprocess.CompletedProcess([], 0, json.dumps({'services': {'light-gateway': {'image': 'configured:test'}}}), ''))
        with patch.dict(os.environ, {'LIGHT_PORTAL_ENV_FILE': str(self.base / 'no-env'), 'BOOTSTRAP_ENV_FILE': str(self.base / '.env.bootstrap')}, clear=True):
            return cli.RealRunner('https://fixture.example/', execute=self.execute, opener_factory=opener or Mock())

    def test_image_present_no_pull_and_absent_exact_pull_confirmed(self):
        runner = self.runner()
        self.execute.reset_mock()
        self.execute.return_value = subprocess.CompletedProcess([], 0, '', '')
        runner.ensure_image()
        self.assertEqual([c.args[0] for c in self.execute.call_args_list], [['docker', 'image', 'inspect', 'configured:test']])
        self.execute.reset_mock()
        self.execute.side_effect = [subprocess.CompletedProcess([], 1, '', 'Error: No such image: configured:test'), subprocess.CompletedProcess([], 0, '', ''), subprocess.CompletedProcess([], 0, '', '')]
        runner.ensure_image()
        self.assertEqual([c.args[0] for c in self.execute.call_args_list], [['docker', 'image', 'inspect', 'configured:test'], ['docker', 'pull', 'configured:test'], ['docker', 'image', 'inspect', 'configured:test']])

    def test_pull_failure_and_daemon_error_stop_before_validation(self):
        runner = self.runner()
        for results, count in [([subprocess.CompletedProcess([], 1, '', 'daemon unavailable')], 1), ([subprocess.CompletedProcess([], 1, '', 'No such image'), subprocess.CompletedProcess([], 1, '', 'pull failed')], 2), ([subprocess.CompletedProcess([], 1, '', 'No such image'), subprocess.CompletedProcess([], 0, '', ''), subprocess.CompletedProcess([], 1, '', 'still absent')], 3)]:
            self.execute.reset_mock()
            self.execute.side_effect = results
            with self.assertRaises(r.ActivationError):
                runner.ensure_image()
            self.assertEqual(self.execute.call_count, count)
            self.assertTrue(all('run' not in c.args[0] and 'up' not in c.args[0] for c in self.execute.call_args_list))

    def test_offline_target_image_readonly_mounts_and_strict_reports(self):
        self.serve()
        path = self.fixture.stage()
        runner = self.runner()
        report = dict(status='ok', version=portable.A, capability=1, manifestDigest='a' * 64, runtimeConfigDigest='b' * 64)
        self.execute.return_value = subprocess.CompletedProcess([], 0, json.dumps(report), '')
        self.assertEqual(runner.validate_offline(path, self.fixture.ctx.runtime_config, self.fixture.keys, '/', None), report)
        args = self.execute.call_args.args[0]
        self.assertEqual(args[:7], ['docker', 'run', '--rm', '--network', 'none', '--pull', 'never'])
        self.assertIn('configured:test', args)
        mounts = [args[i + 1] for i, value in enumerate(args) if value == '--mount']
        self.assertEqual(len(mounts), 3)
        self.assertTrue(all(value.endswith(',readonly') for value in mounts))
        for code, output in [(0, '{}'), (0, '[]'), (0, '{bad'), (1, json.dumps(report)), (2, 'unknown subcommand')]:
            self.execute.return_value = subprocess.CompletedProcess([], code, output, '')
            with self.assertRaises(r.ActivationError):
                runner.validate_offline(path, self.fixture.ctx.runtime_config, self.fixture.keys, '/', None)

    def test_readback_mandatory_head_get_and_failure_not_absent(self):
        opener = Mock()
        opener.open.return_value = response(b'', headers={'X-Portal-Release-Digest': 'a' * 64})
        runner = self.runner(opener=Mock(return_value=opener))
        with patch.object(cli.ssl, 'create_default_context', return_value=Mock()):
            self.assertEqual(runner.read_release_digest(), 'a' * 64)
            self.assertTrue(runner.gateway_healthy())
        self.assertEqual([c.args[0].method for c in opener.open.call_args_list], ['HEAD', 'GET'])
        self.assertTrue(all(c.kwargs['timeout'] == 10 for c in opener.open.call_args_list))
        opener.open.return_value = response(b'', status=503)
        with self.assertRaises(r.ActivationError):
            runner.read_release_digest()
        opener.open.side_effect = OSError('offline')
        with self.assertRaises(r.ActivationError):
            runner.read_release_digest()

    def test_repository_compose_files_environment_and_overlay(self):
        (self.base / 'docker-images.env').write_text('LIGHT_GATEWAY_IMAGE=configured:test\n')
        host = self.base / 'host.env'
        host.write_text('')
        bootstrap = self.base / '.env.bootstrap'
        bootstrap.write_text('COMPOSE_PROJECT_NAME=fixture-project\n')
        env = {'LIGHT_PORTAL_ENV_FILE': str(host), 'BOOTSTRAP_ENV_FILE': str(bootstrap)}
        command, effective = cli.compose_command(self.base, env)
        expected = ['docker', 'compose']
        if cli.MODE == 'bootstrap':
            expected += ['-f', str(self.base / 'docker-compose.yml'), '-f', str(self.base / 'docker-compose.bootstrap.yml')]
        expected += ['--env-file', str(self.base / 'docker-images.env')]
        if cli.MODE == 'installer':
            expected += ['--env-file', str(self.base / '.env')]
        expected += ['--env-file', str(host)]
        if cli.MODE == 'bootstrap':
            expected += ['--env-file', str(bootstrap)]
            self.assertEqual(effective['COMPOSE_PROJECT_NAME'], 'fixture-project')
        self.assertEqual(command, expected)
        if cli.MODE == 'installer':
            runtime = self.base / 'light-workflow-runner-claude-personal/.runtime'
            runtime.mkdir(parents=True)
            (runtime / 'runner.yml').write_text('')
            command, _ = cli.compose_command(self.base, env)
            self.assertEqual(command[-4:], ['-f', str(self.base / 'docker-compose.yml'), '-f', str(self.base / 'light-workflow-runner-claude-personal/controller.compose.yml')])

    def test_installer_existing_runtime_and_trust_preserved(self):
        if cli.MODE != 'installer':
            self.skipTest('installer-only copy adapter')
        original = b'{"operator":"preserve byte for byte"}\n'
        self.fixture.ctx.runtime_config.write_bytes(original)
        (self.base / 'portal-config.oauth2.template.json').write_bytes(b'{"template":true}')
        public = self.base / 'portal-view-release-keys'
        public.mkdir(exist_ok=True)
        cli.installer_config()
        self.assertEqual(self.fixture.ctx.runtime_config.read_bytes(), original)
        self.assertEqual((self.config / 'portal-view-release-keys/test.pem').read_bytes(), (public / 'test.pem').read_bytes())
        self.fixture.ctx.runtime_config.unlink()
        cli.installer_config()
        self.assertEqual(self.fixture.ctx.runtime_config.read_bytes(), b'{"template":true}')

    def test_legacy_sync_preserves_signed_state_and_never_rewrites_payload(self):
        self.fixture.first()
        for name in ('transition.json', '.activation.lock', 'unrelated'):
            (self.root / name).write_bytes(b'retained ' + name.encode())
        before = snapshot(self.root)
        archive = self.base / 'legacy.zip'
        with zipfile.ZipFile(archive, 'w') as zipped:
            zipped.writestr('dist/index.html', b'legacy user_type=C')
            zipped.writestr('dist/assets/app.js', b'user_type=C')
        cli.legacy_dist(archive, self.root)
        after = snapshot(self.root)
        self.assertEqual({k: v for k, v in after.items() if not k.startswith('dist/')}, before)
        self.assertEqual(after['dist/index.html'], ('file', b'legacy user_type=C'))
        self.assertEqual(after['dist/assets/app.js'], ('file', b'user_type=C'))

    def test_invalid_archive_download_extraction_and_layout_preserve_old_dist(self):
        dist = self.root / 'dist'
        dist.mkdir()
        (dist / 'index.html').write_bytes(b'old')
        before = snapshot(self.root)
        archive = self.base / 'bad.zip'
        for name in ('bad/index.html', 'dist/not-index', 'dist/../index.html', '/dist/index.html'):
            with zipfile.ZipFile(archive, 'w') as zipped:
                zipped.writestr(name, b'bad')
            with self.assertRaises(r.ActivationError):
                cli.legacy_dist(archive, self.root)
            self.assertEqual(snapshot(self.root), before)
        archive.write_bytes(b'corrupt download')
        with self.assertRaises(zipfile.BadZipFile):
            cli.legacy_dist(archive, self.root)
        self.assertEqual(snapshot(self.root), before)
        with zipfile.ZipFile(archive, 'w') as zipped:
            zipped.writestr('dist/index.html', b'new')
        with patch.object(zipfile.ZipFile, 'extractall', side_effect=OSError('failed extraction')):
            with self.assertRaises(OSError):
                cli.legacy_dist(archive, self.root)
        self.assertEqual(snapshot(self.root), before)

    def test_mounts_expose_legacy_and_signed_parent_readonly(self):
        import yaml
        data = yaml.safe_load((REPO / 'docker-compose.yml').read_text())
        volumes = data['services']['light-gateway']['volumes']
        self.assertIn('./light-gateway-rust/lightapi:/lightapi:ro,Z', volumes)
        self.assertFalse(any('lightapi/dist:' in value for value in volumes))
        if cli.MODE == 'bootstrap':
            data = yaml.safe_load((REPO / 'docker-compose.bootstrap.yml').read_text())
            self.assertIn('./portal-bff-sso/lightapi:/lightapi:ro,Z', data['services']['portal-bff-sso']['volumes'])


class ShellDispatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='wp12-shell-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.checkout = self.base / 'checkout'
        self.checkout.mkdir()
        (self.checkout / '.env.example').write_text('')
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.log = self.base / 'calls'
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'], WP12_LOG=str(self.log), LIGHT_PORTAL_VERSION='2.6.0', ASSET_CACHE_DIR=str(self.base / 'cache'), LIGHT_PORTAL_ENV_FILE=str(self.base / 'not-present'))
        for name in ('docker', 'podman', 'docker-compose', 'wget'):
            path = self.bin / name
            path.write_text('#!/bin/sh\nprintf "UNEXPECTED %s\\n" "$0" >> "$WP12_LOG"\nexit 99\n')
            path.chmod(0o700)
        self.curl = self.bin / 'curl'
        self.curl.write_text('#!/bin/sh\nprintf "curl %s\\n" "$*" >> "$WP12_LOG"\n[ "${WP12_FAIL_DOWNLOAD:-0}" = 0 ] || exit 22\nwhile [ "$#" -gt 0 ]; do if [ "$1" = -o ]; then shift; cp "$WP12_LEGACY" "$1"; exit; fi; shift; done\nexit 99\n')
        self.curl.chmod(0o700)
        archive = self.base / 'legacy.zip'
        with zipfile.ZipFile(archive, 'w') as zipped:
            zipped.writestr('dist/index.html', b'legacy user_type=C')
        self.env['WP12_LEGACY'] = str(archive)
        scripts = self.checkout / 'scripts'
        scripts.mkdir()
        for name in ('portal-view-release.py', 'portal_view_release.py'):
            shutil.copyfile(REPO / 'scripts' / name, scripts / name)
        # Preparation's external operations are mocked at the entry-point boundary;
        # library/Runner behavior is tested above with signed fixtures.
        python = self.bin / 'python3'
        python.write_text('#!/bin/sh\nprintf "python %s\\n" "$*" >> "$WP12_LOG"\ncase "$*" in *" prepare "*) exit "${WP12_PREPARE_EXIT:-0}";; *" installer-config"*) exit 0;; esac\nexec ' + shutil.which('python3') + ' "$@"\n')
        python.chmod(0o700)
        self.root = self.checkout / 'light-gateway-rust/lightapi'
        (self.root / 'dist').mkdir(parents=True)
        (self.root / 'dist/index.html').write_bytes(b'old')
        (self.root / 'releases/A/dist').mkdir(parents=True)
        (self.root / 'releases/A/dist/index.html').write_bytes(b'signed')
        (self.root / 'current').symlink_to('releases/A')
        for name in ('state.json', 'transition.json', '.activation.lock', 'unrelated'):
            (self.root / name).write_bytes(b'retained ' + name.encode())

    def run_shell(self, signed=False, command='assets'):
        if cli.MODE == 'installer':
            source = (REPO / 'install.sh').read_text()
            helpers = '\n'.join(re.findall(r'^(?:log|die|require_command|download_file|download_archive|download_assets)\(\) \{.*?^\}', source, re.M | re.S))
            # Preserve actual installer install/assets dispatch while stubbing only
            # unrelated database/container and event-bundle effects.
            dispatch = source[source.index('case "$command_name" in\n'):]
            stub = '\ndownload_archive_file() { :; }\nnormalize_events_json() { :; }\ndownload_release_artifacts() { :; }\nclean_volumes_if_requested() { :; }\nbootstrap_events() { :; }\nstart_stack() { :; }\n'
            script = 'set -euo pipefail\n' + helpers + stub + '\nversion=2.6.0\nasset_base_url=https://cdn.example\nrelease_base_url=https://cdn.example/releases\ncommand_name=' + command + '\n' + dispatch
            return ORIGINAL_RUN(['bash', '-c', script], cwd=self.checkout, env=self.env, capture_output=True, text=True)
        shutil.copyfile(REPO / 'scripts/sync-assets.sh', self.checkout / 'scripts/sync-assets.sh')
        return ORIGINAL_RUN(['bash', str(self.checkout / 'scripts/sync-assets.sh'), *(['--stage-signed'] if signed else [])], cwd=self.checkout, env=self.env, capture_output=True, text=True)

    def test_ordinary_and_signed_dispatch_preserve_all_parent_state(self):
        commands = ('assets', 'install') if cli.MODE == 'installer' else ('assets',)
        for command in commands:
            for signed in (False, True):
                before = {k: v for k, v in snapshot(self.root).items() if not k.startswith('dist/')}
                result = self.run_shell(signed, command)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual({k: v for k, v in snapshot(self.root).items() if not k.startswith('dist/')}, before)
                self.assertEqual((self.root / 'dist/index.html').read_bytes(), b'legacy user_type=C')
                calls = self.log.read_text()
                self.assertNotIn('UNEXPECTED', calls)
                self.assertEqual(' prepare ' in calls, signed or cli.MODE == 'installer')
                self.log.unlink()

    def test_failed_download_and_invalid_extraction_preserve_all_contents(self):
        before = snapshot(self.root)
        self.env['WP12_FAIL_DOWNLOAD'] = '1'
        result = self.run_shell(True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(snapshot(self.root), before)
        self.env['WP12_FAIL_DOWNLOAD'] = '0'
        with zipfile.ZipFile(self.env['WP12_LEGACY'], 'w') as zipped:
            zipped.writestr('wrong/index.html', b'invalid')
        result = self.run_shell(True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(snapshot(self.root), before)

    def test_preparation_refusal_propagates_without_operational_fallback(self):
        self.env['WP12_PREPARE_EXIT'] = '2'
        result = self.run_shell(True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('UNEXPECTED', self.log.read_text())
        self.assertEqual((self.root / 'releases/A/dist/index.html').read_bytes(), b'signed')


if __name__ == '__main__':
    unittest.main()
