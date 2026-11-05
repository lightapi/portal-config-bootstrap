"""Release download identity through real urllib processing and localhost I/O."""
import contextlib
import http.client
import http.server
import io
import os
from pathlib import Path
import threading
import unittest
from unittest.mock import Mock, patch
import urllib.request

import test_portal_view_release as portable

r, cli = portable.r, portable.cli


class DownloadFixture(unittest.TestCase):
    def setUp(self):
        self.fixture = portable.ReleaseTests('runTest')
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.folder = self.fixture.fixture()
        self.observed = []
        observed, folder = self.observed, self.folder

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                observed.append((self.path, self.headers.get('User-Agent')))
                name = self.path.rsplit('/', 1)[1]
                if name == 'release-pointer.env':
                    data = b'LIGHT_PORTAL_VERSION=2.6.0\n'
                elif name == 'portal-view-release.env':
                    data = ('PORTAL_VIEW_VERSION=' + portable.A + '\n').encode()
                else:
                    data = (folder / name).read_bytes()
                self.send_response(200)
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass

        # Keep urllib request handling real; replace only TLS for localhost.
        class LocalHTTPS(urllib.request.HTTPSHandler):
            def https_open(self, request):
                return self.do_open(http.client.HTTPConnection, request)

        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(thread.join)
        self.addCleanup(server.shutdown)
        self.origin = 'https://127.0.0.1:' + str(server.server_port)
        build = urllib.request.build_opener

        def local_opener(*handlers):
            return build(*handlers, LocalHTTPS())

        guard = patch.object(r.urllib.request, 'build_opener', side_effect=local_opener)
        guard.start()
        self.addCleanup(guard.stop)
        for name, value in [('ROOT', self.fixture.root), ('CONFIG', self.fixture.base)]:
            guard = patch.object(cli, name, value)
            guard.start()
            self.addCleanup(guard.stop)
        (self.fixture.base / 'portal-config.json').write_text('{}')
        self.fake = self.fixture.fake
        self.fake.ensure_image = Mock()
        self.fake.recreate_command = 'fixture recreate'

    def assert_identity(self, identity, count):
        self.assertEqual(len(self.observed), count)
        self.assertEqual({value for _, value in self.observed}, {identity})


class StageContract:
    def test_stage_downloads_default_and_overridden_identity(self):
        for identity in (None, '', 'customer-release/2.0'):
            self.observed.clear()
            env = {'LIGHT_PORTAL_VERSION': '2.6.0',
                   'LIGHT_PORTAL_ASSET_BASE_URL': self.origin,
                   'LIGHT_PORTAL_RELEASE_BASE_URL': self.origin + '/light-portal/releases',
                   'PORTAL_VIEW_USER_AGENT': identity or ''}
            if identity is None:
                env.pop('PORTAL_VIEW_USER_AGENT')
            with patch.dict(os.environ, env), contextlib.redirect_stdout(io.StringIO()), \
                    patch.object(r, 'download_opener', wraps=r.download_opener) as opened:
                if identity is None:
                    os.environ.pop('PORTAL_VIEW_USER_AGENT', None)
                self.assertEqual(cli.main(['stage', '--version', portable.A]), 0)
            self.assertEqual(opened.call_count, 1)
            self.assert_identity(identity or 'portal-view-release/1.0', 3)
            self.assertEqual({Path(path).name for path, _ in self.observed},
                             {'portal-view-' + portable.A + '.zip',
                              'release-manifest.json', 'release-manifest.sig'})
            self.assertTrue(all(path.startswith('/light-portal/releases/2.6.0/portal-view/')
                                for path, _ in self.observed))

    def test_invalid_stage_identity_has_no_network_or_disk_effects(self):
        for identity in (' ', 'client\r\nX-Injected: value', 'client\u00e9'):
            untouched = self.fixture.base / 'untouched-release-root'
            env = {'LIGHT_PORTAL_VERSION': '2.6.0',
                   'LIGHT_PORTAL_ASSET_BASE_URL': self.origin,
                   'LIGHT_PORTAL_RELEASE_BASE_URL': self.origin,
                   'PORTAL_VIEW_USER_AGENT': identity}
            with self.subTest(identity=identity), patch.dict(os.environ, env), \
                    patch.object(cli, 'ROOT', untouched), \
                    contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(cli.main(['stage', '--version', portable.A]), 2)
            self.assertFalse(untouched.exists())
            self.assertEqual(self.observed, [])

    def test_local_stage_does_not_require_download_identity(self):
        with patch.dict(os.environ, {'PORTAL_VIEW_USER_AGENT': 'invalid\nidentity'}), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(cli.main(['stage', '--version', portable.A,
                                       '--from-dir', str(self.folder)]), 0)
        self.assertEqual(self.observed, [])


class PrepareContract:
    def test_prepare_downloads_default_and_overridden_identity(self):
        for identity in (None, '', 'customer-release/2.0'):
            self.observed.clear()
            with patch.dict(os.environ, {}), contextlib.redirect_stdout(io.StringIO()):
                if identity is None:
                    os.environ.pop('PORTAL_VIEW_USER_AGENT', None)
                else:
                    os.environ['PORTAL_VIEW_USER_AGENT'] = identity
                cli.prepare('latest', self.origin, lambda _: self.fake)
            self.assert_identity(identity or 'portal-view-release/1.0', 5)
            self.assertEqual(self.observed[0][0], '/latest/portal-view/release-pointer.env')
            self.assertTrue(self.observed[1][0].endswith('/portal-view-release.env'))
            self.assertTrue(all(path.startswith('/2.6.0/portal-view/')
                                for path, _ in self.observed[1:]))

    def test_prepare_preserves_injected_transport_headers(self):
        transport = r.download_opener(cli.urllib.request.ProxyHandler({}), cli.NoRedirect())
        transport.addheaders = [('User-Agent', 'owner-client'), ('X-Owner', 'retained')]
        with contextlib.redirect_stdout(io.StringIO()):
            cli.prepare('latest', self.origin, lambda _: self.fake, transport)
        self.assertEqual(transport.addheaders,
                         [('User-Agent', 'owner-client'), ('X-Owner', 'retained')])
        self.assert_identity('owner-client', 5)

    def test_invalid_prepare_identity_has_no_network_or_disk_effects(self):
        untouched = self.fixture.base / 'untouched-prepare-root'
        with patch.dict(os.environ, {'PORTAL_VIEW_USER_AGENT': 'invalid\nidentity'}), \
                patch.object(cli, 'ROOT', untouched):
            with self.assertRaises(r.ActivationError):
                cli.prepare('latest', self.origin, lambda _: self.fake)
        self.assertFalse(untouched.exists())
        self.assertEqual(self.observed, [])


class ResolveContract:
    def test_installer_resolve_download_identity(self):
        for identity in (None, '', 'customer-release/2.0'):
            self.observed.clear()
            with patch.dict(os.environ, {}), contextlib.redirect_stdout(io.StringIO()) as output:
                if identity is None:
                    os.environ.pop('PORTAL_VIEW_USER_AGENT', None)
                else:
                    os.environ['PORTAL_VIEW_USER_AGENT'] = identity
                self.assertEqual(cli.main(['resolve', '--release-base', self.origin]), 0)
            self.assertEqual(output.getvalue().strip(), '2.6.0')
            self.assert_identity(identity or 'portal-view-release/1.0', 1)
