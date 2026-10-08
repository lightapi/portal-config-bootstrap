"""Readiness regressions: actual adapters, fake HTTP/Compose, disposable signed fixtures."""
import http.client
import json
import os
import ssl
import subprocess
import types
import unittest
from unittest.mock import Mock, patch
import urllib.error

import test_portal_view_release as portable

r, cli = portable.r, portable.cli


def response(digest=None, status=200):
    value = Mock(status=status, headers={} if digest is None else {'X-Portal-Release-Digest': digest})
    value.__enter__ = Mock(return_value=value)
    value.__exit__ = Mock(return_value=False)
    return value


class ReadbackTests(unittest.TestCase):
    def setUp(self):
        self.fixture = portable.ReleaseTests('runTest')
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.root, self.ctx = self.fixture.root, self.fixture.ctx
        self.fixture.first()
        self.fixture.stage(portable.B)
        self.opener = Mock()
        self.events = []
        self.legacy = False
        self.opener.open.side_effect = self.read
        self.execute = Mock(return_value=subprocess.CompletedProcess([], 0, json.dumps({
            'services': {'light-gateway': {'image': 'fixture:never-run'}}}), ''))
        self.compose = Mock()
        with patch.object(cli.ssl, 'create_default_context', return_value=Mock()):
            if hasattr(cli, 'MODE'):
                for name, value in [('BASE', self.fixture.base), ('CONFIG', self.fixture.base), ('ROOT', self.root)]:
                    guard = patch.object(cli, name, value)
                    guard.start()
                    self.addCleanup(guard.stop)
                (self.fixture.base / '.env.bootstrap').write_text('COMPOSE_PROJECT_NAME=fixture\n')
                with patch.dict(os.environ, {'BOOTSTRAP_ENV_FILE': str(self.fixture.base / '.env.bootstrap'),
                                            'LIGHT_PORTAL_ENV_FILE': str(self.fixture.base / 'none')}, clear=True):
                    self.runner = cli.RealRunner('https://fixture.example/', execute=self.execute,
                                                 opener_factory=Mock(return_value=self.opener))
                self.runner.run = self.compose
            else:
                stack = types.SimpleNamespace(BASE=self.fixture.base,
                    containers=Mock(return_value={'light-gateway': {'Mounts': []}}),
                    configuration=Mock(return_value=({'services': {'light-gateway': {'image': 'fixture:never-run'}}},
                                                     ['docker', 'compose'], {})), run=self.compose, wait=Mock())
                self.runner = cli.RealRunner('https://fixture.example/', stack=stack, execute=self.execute,
                                             opener_factory=Mock(return_value=self.opener))
            self.runner.trust()
        self.ctx.runner = r.Runner(self.fixture.fake.validate_offline, self.runner.recreate_gateways,
                                   self.runner.read_release_digest, self.runner.gateway_healthy)
        self.now = 0.0
        self.ctx.monotonic = lambda: self.now
        self.ctx.sleep = Mock(side_effect=self.advance)

    def advance(self, seconds):
        self.now += seconds

    def read(self, request, timeout):
        self.assertGreater(timeout, 0)
        self.assertLessEqual(timeout, 10)
        if self.events:
            event = self.events.pop(0)
            if isinstance(event, Exception):
                raise event
            return event
        pointer = r.target(self.root)
        digest = None if self.legacy else r.digest((self.root / pointer / 'release-manifest.json').read_bytes())
        return response(digest)

    def transient(self):
        return [urllib.error.URLError(ConnectionRefusedError('starting')),
                ConnectionResetError('restarting'), TimeoutError('not ready')]

    def assert_prior(self, prior):
        self.assertEqual(r.snapshot(self.root)[1], prior)
        self.assertEqual(r.target(self.root), 'releases/' + prior['active'])
        self.assertFalse((self.root / 'transition.json').exists())

    def test_activation_retries_transport_errors_then_publishes(self):
        self.events = self.transient()
        r.activate(portable.B, self.root, self.ctx)
        self.fixture.assert_state(portable.B, portable.A)
        self.assertFalse((self.root / 'transition.json').exists())
        self.assertEqual(self.opener.open.call_count, 4)
        self.assertEqual(self.ctx.sleep.call_count, 3)
        self.compose.assert_called_once()

    def test_rollback_retries_transient_readback(self):
        r.activate(portable.B, self.root, self.ctx)
        self.opener.open.reset_mock()
        self.events = self.transient()
        r.rollback(self.root, self.ctx)
        self.fixture.assert_state(portable.A, portable.B)
        self.assertEqual(self.opener.open.call_count, 4)
        self.assertFalse((self.root / 'transition.json').exists())

    def test_failed_activation_restoration_retries_and_restores_complete_state(self):
        r.activate(portable.B, self.root, self.ctx)
        prior = r.snapshot(self.root)[1]
        self.fixture.stage(portable.C)
        self.opener.open.reset_mock()
        self.events = [urllib.error.HTTPError('https://fixture', 403, 'permanent', {}, None), *self.transient()]
        with self.assertRaisesRegex(r.ActivationError, 'prior release restored'):
            r.activate(portable.C, self.root, self.ctx)
        self.assert_prior(prior)
        self.assertEqual(self.opener.open.call_count, 5)

    def test_retry_exhaustion_restores_prior_release(self):
        prior = r.snapshot(self.root)[1]
        self.events = [TimeoutError('starting')] * 15
        with self.assertRaisesRegex(r.ActivationError, 'prior release restored'):
            r.activate(portable.B, self.root, self.ctx)
        self.assert_prior(prior)
        self.assertEqual(self.opener.open.call_count, 16)
        self.assertEqual(self.ctx.sleep.call_count, 14)

    def test_failed_restoration_retains_journal_then_recovery_retries(self):
        prior = r.snapshot(self.root)[1]
        self.events = [TimeoutError('offline')] * 30
        with self.assertRaises(r.RecoveryFailed):
            r.activate(portable.B, self.root, self.ctx)
        journal = r.read_json(self.root / 'transition.json')
        self.assertEqual(journal['priorState'], prior)
        self.assertTrue(journal['priorStateExists'])
        self.assertEqual(self.opener.open.call_count, 30)
        self.events = self.transient()
        r.recover(self.root, self.ctx)
        self.assert_prior(prior)

    def test_recovery_after_candidate_state_publication_restores_complete_prior_state(self):
        r.activate(portable.B, self.root, self.ctx)
        prior = r.snapshot(self.root)[1]
        self.fixture.stage(portable.C)
        self.fixture.interrupt('state.json', portable.C)
        self.fixture.assert_state(portable.C, portable.B)
        self.events = self.transient()
        r.recover(self.root, self.ctx)
        self.assert_prior(prior)

    def test_signed_recreate_retries_without_state_or_pointer_mutation(self):
        prior = (self.root / 'state.json').read_bytes()
        inode = (self.root / 'current').lstat().st_ino
        self.events = self.transient()
        r.recreate(self.root, self.ctx)
        self.assertEqual(self.opener.open.call_count, 4)
        self.assertEqual((self.root / 'state.json').read_bytes(), prior)
        self.assertEqual((self.root / 'current').lstat().st_ino, inode)

    def test_legacy_recreate_retries_startup_but_requires_get_and_absent_head(self):
        self.legacy = True
        self.events = [urllib.error.URLError(ConnectionRefusedError('starting'))]
        prior = (self.root / 'state.json').read_bytes()
        r.recreate(self.root, self.ctx, expect_legacy=True)
        self.assertEqual([c.args[0].method for c in self.opener.open.call_args_list], ['GET', 'GET', 'HEAD'])
        self.assertEqual((self.root / 'state.json').read_bytes(), prior)
        self.assertFalse((self.root / 'transition.json').exists())

    def test_permanent_errors_fail_immediately_for_signed_and_legacy(self):
        errors = [urllib.error.URLError(ssl.SSLCertVerificationError('untrusted')),
                  ssl.SSLError('invalid TLS'), OSError('unclassified'),
                  urllib.error.URLError('permanent DNS failure'),
                  ValueError('invalid trust configuration'), r.ActivationError('redirect refused')]
        errors += [urllib.error.HTTPError('https://fixture', code, 'permanent', {}, None)
                   for code in (301, 401, 403, 404, 500)]
        prior = (self.root / 'state.json').read_bytes()
        for legacy in (False, True):
            for error in errors:
                with self.subTest(legacy=legacy, error=error):
                    self.events = [error]
                    self.opener.open.reset_mock()
                    self.ctx.sleep.reset_mock()
                    with self.assertRaises(r.ActivationError):
                        r.recreate(self.root, self.ctx, expect_legacy=legacy)
                    self.assertEqual(self.opener.open.call_count, 1)
                    self.ctx.sleep.assert_not_called()
                    self.assertEqual((self.root / 'state.json').read_bytes(), prior)

    def test_temporary_http_and_disconnect_failures_retry(self):
        self.events = [urllib.error.HTTPError('https://fixture', code, 'starting', {}, None)
                       for code in (502, 503, 504)] + [http.client.RemoteDisconnected('starting')]
        r.recreate(self.root, self.ctx)
        self.assertEqual(self.opener.open.call_count, 5)
        self.assertEqual(self.ctx.sleep.call_count, 4)

    def test_deadline_caps_each_request_and_rejects_late_success(self):
        timeouts = []
        def slow_read(request, timeout):
            timeouts.append(timeout)
            self.advance(timeout)
            raise TimeoutError('slow startup')
        self.opener.open.side_effect = slow_read
        with self.assertRaisesRegex(r.ActivationError, '60 seconds'):
            r.poll(self.ctx, 'a' * 64)
        self.assertEqual(self.now, 60)
        self.assertEqual(timeouts, [10, 10, 10, 10, 10])
        self.assertEqual(self.ctx.sleep.call_count, 5)
        self.now = 0
        def late_read(request, timeout):
            self.advance(61)
            return response('a' * 64)
        self.opener.open.side_effect = late_read
        with self.assertRaisesRegex(r.ActivationError, '60 seconds'):
            r.poll(self.ctx, 'a' * 64)

    def test_short_remaining_budget_is_forwarded_to_http(self):
        timeouts = []
        def read(request, timeout):
            timeouts.append(timeout)
            self.advance(55 if len(timeouts) == 1 else timeout)
            raise TimeoutError('slow startup')
        self.opener.open.side_effect = read
        with self.assertRaises(r.ActivationError):
            r.poll(self.ctx, 'a' * 64)
        self.assertEqual(timeouts, [10, 3])
        self.assertEqual(self.now, 60)

    def test_legacy_get_and_head_share_the_remaining_budget(self):
        timeouts = []
        def read(request, timeout):
            timeouts.append((request.method, timeout))
            self.advance(59 if request.method == 'GET' else timeout)
            return response()
        self.opener.open.side_effect = read
        with self.assertRaisesRegex(r.ActivationError, '60 seconds'):
            r.recreate(self.root, self.ctx, expect_legacy=True)
        self.assertEqual(timeouts, [('GET', 10), ('HEAD', 1)])

    def test_failed_legacy_head_is_not_an_absent_digest(self):
        self.events = [event for _ in range(15) for event in (response(), TimeoutError('starting'))]
        with self.assertRaises(r.ActivationError):
            r.recreate(self.root, self.ctx, expect_legacy=True)
        self.assertEqual(self.opener.open.call_count, 30)
        self.assertEqual(self.ctx.sleep.call_count, 14)
        self.assertFalse((self.root / 'transition.json').exists())

    def test_certificate_failure_during_restoration_retains_recovery_evidence(self):
        prior = r.snapshot(self.root)[1]
        self.events = [TimeoutError('starting')] * 15 + [urllib.error.URLError(ssl.SSLCertVerificationError('untrusted'))]
        with self.assertRaises(r.RecoveryFailed):
            r.activate(portable.B, self.root, self.ctx)
        self.assertEqual(self.opener.open.call_count, 16)
        self.assertEqual(r.read_json(self.root / 'transition.json')['priorState'], prior)
        self.assertEqual(self.ctx.sleep.call_count, 14)

    def test_default_readback_follows_mount_and_explicit_url_wins(self):
        self.runner.use_mount_path('/ai/portal')
        self.assertEqual(self.runner.url, 'https://fixture.example/')
        with patch.object(cli.ssl, 'create_default_context', return_value=Mock()):
            if hasattr(cli, 'MODE'):
                with patch.dict(os.environ, {'BOOTSTRAP_ENV_FILE': str(self.fixture.base / '.env.bootstrap'),
                                            'LIGHT_PORTAL_ENV_FILE': str(self.fixture.base / 'none')}, clear=True):
                    runner = cli.RealRunner(None, execute=self.execute, opener_factory=Mock(return_value=self.opener))
            else:
                stack = types.SimpleNamespace(BASE=self.fixture.base,
                    containers=Mock(return_value={'light-gateway': {'Mounts': []}}),
                    configuration=Mock(return_value=({'services': {'light-gateway': {'image': 'fixture:never-run'}}},
                                                     ['docker', 'compose'], {})), run=self.compose, wait=Mock())
                with patch.dict(os.environ, {}, clear=True):
                    runner = cli.RealRunner(None, stack=stack, execute=self.execute, opener_factory=Mock(return_value=self.opener))
        self.assertEqual(runner.url, runner.readback_origin + '/')
        runner.use_mount_path('/ai/portal')
        self.assertEqual(runner.url, runner.readback_origin + '/ai/portal/')
        self.assertRegex(runner.readback_origin, r'\Ahttps://[^/]+\Z')
        with self.assertRaisesRegex(r.ActivationError, 'invalid mount path'):
            runner.use_mount_path('/ai/../portal')


if __name__ == '__main__':
    unittest.main()
