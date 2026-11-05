"""Compose providers that cannot print JSON (podman-compose) and have no PyYAML."""
import subprocess
import unittest
from unittest.mock import Mock, patch

import test_portal_view_release as portable

cli, r = portable.cli, portable.r
SERVICE = 'light-gateway'

# PyYAML-style dump: sorted keys, sequences not indented under their key.
LONG_FORM = """\
name: light-portal-bootstrap
services:
  light-gateway:
    environment:
      A: '1'
    image: registry.example/lightapi/gateway:1.2.3
    ports:
    - mode: ingress
      protocol: tcp
      published: '9443'
      target: 8443
    - target: 8080
  other:
    image: other:1
    ports:
    - 1:2
"""
SHORT_FORM = """\
services:
  light-gateway:
    ports:
      - "127.0.0.1:9443:8443/tcp"
      - 8080:80
    image: 'gateway:short'  # pinned
"""


class ParseTests(unittest.TestCase):
    def parse(self, text):
        return cli.parse_compose_config(text, SERVICE)['services'][SERVICE]

    def test_long_form_ports_and_neighbouring_service_ignored(self):
        got = self.parse(LONG_FORM)
        self.assertEqual(got['image'], 'registry.example/lightapi/gateway:1.2.3')
        self.assertEqual(got['ports'], [{'target': 8443, 'published': '9443'}, {'target': 8080}])

    def test_short_form_ports_indented_sequences_quotes_and_comments(self):
        got = self.parse(SHORT_FORM)
        self.assertEqual(got['image'], 'gateway:short')
        self.assertEqual(got['ports'], [{'target': 8443, 'published': '9443'},
                                        {'target': 80, 'published': '8080'}])

    def test_unpublished_and_absent_ports(self):
        self.assertEqual(self.parse('services:\n  light-gateway:\n    image: g:1\n    ports:\n    - "8443"\n')['ports'],
                         [{'target': 8443, 'published': None}])
        self.assertEqual(self.parse('services:\n  light-gateway:\n    image: g:1\n    ports: []\n')['ports'], [])
        self.assertEqual(self.parse('services:\n  light-gateway:\n    image: g:1\n')['ports'], [])

    def test_unsupported_or_missing_input_is_refused(self):
        for text in ('services:\n  other:\n    image: x\n',
                     'nothing: here\n',
                     'services:\n  light-gateway:\n    image: [a]\n',
                     'services:\n  light-gateway:\n    image: g\n    ports: [8443]\n',
                     'services:\n  light-gateway:\n    image: "unterminated\n'):
            with self.subTest(text=text), self.assertRaises(r.ActivationError):
                cli.parse_compose_config(text, SERVICE)


class RunnerFallbackTests(unittest.TestCase):
    def runner(self, outcomes):
        calls = []

        def execute(args, **_):
            calls.append(args)
            return outcomes[len(calls) - 1]

        with patch.object(cli, 'compose_command', return_value=(['docker', 'compose'], {})):
            return calls, execute

    def build(self, outcomes):
        calls, execute = self.runner(outcomes)
        with patch.object(cli, 'compose_command', return_value=(['docker', 'compose'], {})):
            return calls, cli.RealRunner(execute=execute)

    def test_podman_compose_falls_back_to_yaml_config(self):
        refused = subprocess.CompletedProcess([], 2, '', 'podman-compose: error: unrecognized arguments: --format json')
        calls, runner = self.build([refused, subprocess.CompletedProcess([], 0, LONG_FORM, '')])
        self.assertEqual(calls, [['docker', 'compose', 'config', '--format', 'json'], ['docker', 'compose', 'config']])
        self.assertEqual(runner.image, 'registry.example/lightapi/gateway:1.2.3')
        self.assertIn(':9443', runner.url)

    def test_json_is_used_when_supported(self):
        calls, runner = self.build([subprocess.CompletedProcess(
            [], 0, '{"services": {"light-gateway": {"image": "j:1"}}}', '')])
        self.assertEqual(len(calls), 1)
        self.assertEqual(runner.image, 'j:1')

    def test_real_config_failure_reports_provider_stderr(self):
        failed = subprocess.CompletedProcess([], 1, '', 'required variable MSAL_TENANT_ID is missing a value')
        with self.assertRaisesRegex(r.ActivationError, 'MSAL_TENANT_ID is missing'):
            self.build([failed, failed])


if __name__ == '__main__':
    unittest.main()
