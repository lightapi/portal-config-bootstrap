"""Missing release-image metadata is acquired before any Compose operation."""
import contextlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch
import urllib.error

import test_portal_view_adapter as adapters

cli, release = adapters.cli, adapters.r
IMAGES = (b'# Generated release data\n'
          b'PORTAL_HYBRID_COMMAND_IMAGE=fixture/command:packaged\n'
          b'PORTAL_HYBRID_QUERY_IMAGE=fixture/query@sha256:' + b'a' * 64 + b'\n'
          b'LIGHT_GATEWAY_IMAGE=fixture/gateway:packaged\n')


class ImageEnvironmentTests(unittest.TestCase):
    def setUp(self):
        self.fixture = adapters.AdapterTests('runTest')
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.target = self.fixture.base / 'docker-images.env'
        self.target.unlink()
        self.transport = self.fixture.transport

    def output(self):
        return contextlib.redirect_stdout(io.StringIO())

    def test_prepare_resolves_once_and_publishes_images_before_runner(self):
        folder = self.fixture.serve()
        urls = []

        def fetch(url, timeout):
            urls.append(url)
            name = url.rsplit('/', 1)[1]
            if name == 'release-pointer.env':
                data = b'LIGHT_PORTAL_VERSION=2.6.0\n'
            elif name == 'portal-view-release.env':
                data = ('PORTAL_VIEW_VERSION=' + adapters.portable.A + '\n').encode()
            elif name == 'docker-images.env':
                data = IMAGES
            else:
                data = (folder / name).read_bytes()
            return adapters.response(data)

        self.transport.open.side_effect = fetch

        def runner(_):
            self.assertEqual(self.target.read_bytes(), IMAGES)
            return self.fixture.fake

        with self.output():
            cli.prepare('latest', 'https://cdn.example/releases', runner, self.transport)
        self.assertEqual(urls[0], 'https://cdn.example/releases/latest/portal-view/release-pointer.env')
        self.assertEqual(urls.count(urls[0]), 1)
        self.assertEqual(urls[-1], 'https://cdn.example/releases/2.6.0/docker-images.env')
        self.assertFalse(any('/latest/' in url for url in urls[1:]))
        self.assertEqual(list(self.target.parent.glob('.docker-images-*.tmp')), [])

    def test_existing_file_is_preserved_without_network(self):
        self.target.write_bytes(b'OWNER_IMAGE=private/image:pinned\n')
        self.transport.open.side_effect = AssertionError('existing file must not trigger network')
        cli.image_env('latest', opener=self.transport)
        self.assertEqual(self.target.read_bytes(), b'OWNER_IMAGE=private/image:pinned\n')
        self.transport.open.assert_not_called()

    def test_pinned_selection_skips_latest_and_atomic_publication(self):
        self.transport.open.return_value = adapters.response(IMAGES)
        with self.output():
            cli.image_env('2.6.0', 'https://cdn.example/releases', self.transport)
        self.transport.open.assert_called_once_with(
            'https://cdn.example/releases/2.6.0/docker-images.env', timeout=60)
        self.assertEqual(self.target.read_bytes(), IMAGES)

    def test_download_failures_and_invalid_data_leave_no_target(self):
        bad = [b'<html>proxy error</html>', b'PORTAL_HYBRID_COMMAND_IMAGE=fixture/command:packaged\n',
               IMAGES + b'COMPOSE_FILE=untrusted.yml\n', IMAGES + b'BAD_IMAGE=$(execute)\n',
               IMAGES + b'LIGHT_GATEWAY_IMAGE=duplicate:tag\n', b'x' * 65537,
               IMAGES + b'BAD_IMAGE=unqualified\n', b'\xff']
        for data in bad:
            self.transport.open.return_value = adapters.response(data)
            with self.subTest(data=data[:80]), self.assertRaises(release.ActivationError):
                cli.image_env('2.6.0', 'https://cdn.example/releases', self.transport)
            self.assertFalse(self.target.exists())
        self.transport.open.side_effect = urllib.error.HTTPError('https://cdn.example', 404, 'absent', {}, None)
        with self.assertRaisesRegex(release.ActivationError, 'image environment download failed: HTTP 404'):
            cli.image_env('2.6.0', 'https://cdn.example/releases', self.transport)
        self.assertFalse(self.target.exists())
        self.assertEqual(list(self.target.parent.glob('.docker-images-*.tmp')), [])

    def test_prepare_stops_before_runner_when_image_download_fails(self):
        folder = self.fixture.serve()
        fetch = self.transport.open.side_effect

        def fail_images(url, timeout):
            if url.endswith('/docker-images.env'):
                raise urllib.error.HTTPError(url, 403, 'refused', {}, None)
            return fetch(url, timeout)

        self.transport.open.side_effect = fail_images
        with self.output(), contextlib.redirect_stderr(io.StringIO()), \
                self.assertRaises(release.ActivationError):
            cli.prepare('2.6.0', 'https://cdn.example/releases', self.fixture.factory, self.transport)
        self.fixture.factory.assert_not_called()
        self.assertFalse(self.target.exists())
        self.assertFalse(os.path.lexists(self.fixture.root / 'current'))
        self.assertFalse((self.fixture.root / 'state.json').exists())

    def test_concurrent_owner_file_is_not_overwritten(self):
        self.transport.open.return_value = adapters.response(IMAGES)
        link = os.link

        def owner_wins(source, target):
            target.write_bytes(b'OWNER_IMAGE=owner/pin:custom\n')
            return link(source, target)

        with patch.object(cli.os, 'link', side_effect=owner_wins), self.output():
            cli.image_env('2.6.0', 'https://cdn.example/releases', self.transport)
        self.assertEqual(self.target.read_bytes(), b'OWNER_IMAGE=owner/pin:custom\n')
        self.assertEqual(list(self.target.parent.glob('.docker-images-*.tmp')), [])

    def test_existing_symlink_is_refused(self):
        other = self.target.with_name('other.env')
        other.write_bytes(IMAGES)
        self.target.symlink_to(other)
        with self.assertRaises(release.ActivationError):
            cli.image_env('latest', opener=self.transport)
        self.transport.open.assert_not_called()

    def test_failed_publication_leaves_no_partial_file(self):
        self.transport.open.return_value = adapters.response(IMAGES)
        with patch.object(cli.os, 'link', side_effect=PermissionError('injected write refusal')), \
                self.assertRaises(PermissionError):
            cli.image_env('2.6.0', 'https://cdn.example/releases', self.transport)
        self.assertFalse(self.target.exists())
        self.assertEqual(list(self.target.parent.glob('.docker-images-*.tmp')), [])


class BootstrapImageEntryTests(unittest.TestCase):
    def test_scripts_acquire_before_compose_and_preserve_env_order(self):
        for script in ('validate-bootstrap.sh', 'restart-bootstrap-stack.sh'):
            with self.subTest(script=script), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                scripts, binaries = root / 'scripts', root / 'bin'
                scripts.mkdir()
                binaries.mkdir()
                shutil.copyfile(adapters.REPO / 'scripts' / script, scripts / script)
                log = root / 'calls'
                host, bootstrap = root / 'host.env', root / '.env.bootstrap'
                host.write_text('PORTAL_HYBRID_COMMAND_IMAGE=private/override:owner\n')
                bootstrap.write_text('COMPOSE_PROJECT_NAME=fixture\n' + ''.join(
                    key + '=fixture\n' for key in ('MSAL_TENANT_ID', 'MSAL_CLIENT_ID',
                        'MSAL_REDIRECT_URI', 'MSAL_EXCHANGE_CLIENT_ID', 'MSAL_EXCHANGE_CLIENT_SECRET',
                        'PORTAL_BFF_SSO_LIGHT_PORTAL_AUTHORIZATION')))
                for name in ('tls/ca.pem', 'tls/cert.pem', 'tls/key.pem', 'lightapi/dist/index.html'):
                    path = root / 'portal-bff-sso' / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text('fixture')
                python = binaries / 'python3'
                python.write_text('#!/bin/sh\nprintf "image-env\\n" >> "$CAPTURE"\n'
                                  'printf "PORTAL_HYBRID_COMMAND_IMAGE=fixture/c:tag\\n" > "$CHECKOUT/docker-images.env"\n')
                docker = binaries / 'docker'
                # Stop at first Compose render; never exercise deployment operations.
                docker.write_text('#!/bin/sh\nprintf "docker %s\\n" "$*" >> "$CAPTURE"\nexit 71\n')
                python.chmod(0o700)
                docker.chmod(0o700)
                env = dict(os.environ, PATH=str(binaries) + ':' + os.environ['PATH'],
                           CAPTURE=str(log), CHECKOUT=str(root), LIGHT_PORTAL_ENV_FILE=str(host),
                           BOOTSTRAP_ENV_FILE=str(bootstrap))
                result = subprocess.run(['bash', str(scripts / script)], env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 71, result.stderr)
                calls = log.read_text().splitlines()
                self.assertEqual(calls[0], 'image-env')
                self.assertTrue(calls[1].startswith('docker compose '))
                self.assertIn('--env-file ' + str(root / 'docker-images.env'), calls[1])
                self.assertLess(calls[1].index(str(root / 'docker-images.env')), calls[1].index(str(host)))
                self.assertLess(calls[1].index(str(host)), calls[1].index(str(bootstrap)))
                log.unlink()
                python.write_text('#!/bin/sh\nprintf "image-env-failed\\n" >> "$CAPTURE"\nexit 72\n')
                result = subprocess.run(['bash', str(scripts / script)], env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 72, result.stderr)
                self.assertEqual(log.read_text().splitlines(), ['image-env-failed'])
