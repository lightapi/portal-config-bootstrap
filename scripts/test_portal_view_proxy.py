"""Real urllib proxy routing with fixture HTTPS responses and no external network."""
import contextlib
from email.message import Message
import io
import os
import unittest
from unittest.mock import patch
import urllib.request
import urllib.response

import test_portal_view_adapter as adapters

cli, release = adapters.cli, adapters.r


@contextlib.contextmanager
def proxy_environment(key='HTTPS_PROXY', bypass=None):
    with patch.dict(os.environ, {}):
        for name in list(os.environ):
            if name.lower().endswith('_proxy'):
                os.environ.pop(name)
        os.environ[key] = 'http://proxy.fixture:3128'
        if bypass is not None:
            os.environ['NO_PROXY'] = bypass
        yield


class ReleaseProxyTests(unittest.TestCase):
    def setUp(self):
        self.fixture = adapters.AdapterTests('runTest')
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.folder = self.fixture.serve()
        self.requests = []
        self.redirect = False
        owner = self

        class FixtureHTTPS(urllib.request.HTTPSHandler):
            def https_open(self, request):
                # ProxyHandler has already rewritten host/tunnel fields here.
                owner.requests.append((request.full_url, request.host,
                                       request._tunnel_host, request.get_header('User-agent')))
                name = request.full_url.rsplit('/', 1)[1]
                if name == 'release-pointer.env':
                    data = b'LIGHT_PORTAL_VERSION=2.6.0\n'
                elif name == 'portal-view-release.env':
                    data = ('PORTAL_VIEW_VERSION=' + adapters.portable.A + '\n').encode()
                elif name == 'docker-images.env':
                    data = (b'PORTAL_HYBRID_COMMAND_IMAGE=fixture/command:pinned\n'
                            b'PORTAL_HYBRID_QUERY_IMAGE=fixture/query:pinned\n')
                elif name:
                    data = (owner.folder / name).read_bytes()
                else:
                    data = b''
                headers = Message()
                headers['X-Portal-Release-Digest'] = 'a' * 64
                if owner.redirect:
                    headers['Location'] = 'https://redirect.example/elsewhere'
                response = urllib.response.addinfourl(io.BytesIO(data), headers, request.full_url,
                                                     302 if owner.redirect else 200)
                response.msg = 'Found' if owner.redirect else 'OK'
                return response

        build = urllib.request.build_opener

        def fixture_opener(*handlers):
            # Replace only the HTTPS endpoint; preserve actual ProxyHandler behavior.
            handlers = [handler for handler in handlers
                        if not isinstance(handler, urllib.request.HTTPSHandler)]
            return build(*handlers, FixtureHTTPS())

        self.fixture_opener = fixture_opener
        guard = patch.object(cli.urllib.request, 'build_opener', side_effect=fixture_opener)
        guard.start()
        self.addCleanup(guard.stop)

    def test_prepare_routes_pointer_metadata_and_members_through_environment_proxy(self):
        for variable in ('HTTPS_PROXY', 'https_proxy'):
            with self.subTest(variable=variable), proxy_environment(variable), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.requests.clear()
                cli.prepare('latest', 'https://cdn.example/releases', self.fixture.factory)
                self.assertEqual(len(self.requests), 5)
                self.assertEqual({host for _, host, _, _ in self.requests}, {'proxy.fixture:3128'})
                self.assertEqual({tunnel for _, _, tunnel, _ in self.requests}, {'cdn.example'})
                self.assertEqual({agent for _, _, _, agent in self.requests}, {'portal-view-release/1.0'})

    def test_image_env_uses_environment_proxy(self):
        (self.fixture.base / 'docker-images.env').unlink()
        with proxy_environment(), contextlib.redirect_stdout(io.StringIO()):
            cli.image_env('latest', 'https://cdn.example/releases')
        self.assertEqual(len(self.requests), 2)
        self.assertTrue(self.requests[-1][0].endswith('/2.6.0/docker-images.env'))
        self.assertEqual({host for _, host, _, _ in self.requests}, {'proxy.fixture:3128'})

    def test_no_proxy_bypasses_environment_proxy_for_downloads(self):
        with proxy_environment(bypass='cdn.example'), contextlib.redirect_stdout(io.StringIO()):
            cli.prepare('latest', 'https://cdn.example/releases', self.fixture.factory)
        self.assertEqual(len(self.requests), 5)
        self.assertEqual({host for _, host, _, _ in self.requests}, {'cdn.example'})
        self.assertEqual({tunnel for _, _, tunnel, _ in self.requests}, {None})

    def test_gateway_readback_remains_direct_even_with_environment_proxy(self):
        with proxy_environment():
            runner = self.fixture.runner(opener=self.fixture_opener)
            self.assertEqual(runner.read_release_digest(), 'a' * 64)
        self.assertEqual(len(self.requests), 1)
        self.assertEqual(self.requests[0][1:3], ('fixture.example', None))

    def test_proxy_does_not_enable_redirects(self):
        (self.fixture.base / 'docker-images.env').unlink()
        self.redirect = True
        with proxy_environment(), self.assertRaisesRegex(release.ActivationError, 'redirects are refused'):
            cli.image_env('latest', 'https://cdn.example/releases')
        self.assertEqual(len(self.requests), 1)
        self.assertEqual(self.requests[0][1], 'proxy.fixture:3128')
        self.assertFalse((self.fixture.base / 'docker-images.env').exists())
