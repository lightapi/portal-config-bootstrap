"""Exercise the shipped CLI adapter against a provider that reads only one env file."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import test_portal_view_release as portable

ADAPTER = Path(__file__).parent / 'podman-compat'


class PodmanAdapterTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.log = self.base / 'provider.json'
        self.first = self.base / 'release images.env'
        self.second = self.base / 'bootstrap.env'
        self.first.write_text('PORTAL_HYBRID_COMMAND_IMAGE=release/command:pinned\n'
                              'PORTAL_HYBRID_QUERY_IMAGE=release/query:pinned\n'
                              'LIGHT_GATEWAY_IMAGE=release/gateway:pinned\n'
                              'OVERRIDE=first')  # No final newline: the adapter must add one.
        self.second.write_text('OVERRIDE=second\nCOMPOSE_PROJECT_NAME=fixture\n')
        provider = self.bin / 'podman-compose'
        provider.write_text('#!' + sys.executable + '\n' + '''
import json, os, pathlib, stat, sys
args = sys.argv[1:]
files = [args[i+1] for i, arg in enumerate(args) if arg == '--env-file']
values = {}
if files:
    # Reproduce older podman-compose: use the final --env-file only.
    for line in pathlib.Path(files[-1]).read_text().splitlines():
        if line and not line.startswith('#'):
            key, _, value = line.partition('=')
            values[key] = value
pathlib.Path(os.environ['PROVIDER_LOG']).write_text(json.dumps({
    'args': args, 'values': values, 'file': files[-1] if files else None,
    'mode': stat.S_IMODE(pathlib.Path(files[-1]).stat().st_mode) if files else None}))
if os.environ.get('PROVIDER_FAIL'):
    print('provider refused', file=sys.stderr)
    sys.exit(7)
if '--format' in args:
    print('unrecognized arguments: --format json', file=sys.stderr)
    sys.exit(2)
if 'config' in args:
    required = ('PORTAL_HYBRID_COMMAND_IMAGE', 'PORTAL_HYBRID_QUERY_IMAGE')
    if not all(os.environ.get(key) or values.get(key) for key in required):
        print('required hybrid image is missing', file=sys.stderr)
        sys.exit(8)
    image = os.environ.get('LIGHT_GATEWAY_IMAGE') or values['LIGHT_GATEWAY_IMAGE']
    print('services:\\n  portal-bff-sso:\\n    image: ' + image)
    print('# private rendered configuration')
''')
        provider.chmod(0o700)
        engine = self.bin / 'podman'
        engine.write_text('#!' + sys.executable + '\n' + '''
import json, sys
print(json.dumps({'args':sys.argv[1:], 'stdin':sys.stdin.read()}))
''')
        engine.chmod(0o700)
        self.env = dict(os.environ, PATH=str(ADAPTER) + ':' + str(self.bin) + ':' + os.environ['PATH'],
                        PROVIDER_LOG=str(self.log), TMPDIR=str(self.base))
        for name in ('PORTAL_HYBRID_COMMAND_IMAGE', 'PORTAL_HYBRID_QUERY_IMAGE', 'LIGHT_GATEWAY_IMAGE'):
            self.env.pop(name, None)

    def call(self, *args, **kwargs):
        return subprocess.run(['docker', *args], env=self.env, capture_output=True, text=True, **kwargs)

    def compose(self, *args):
        return self.call('compose', '-f', 'compose file.yml', '--env-file', str(self.first),
                         '--env-file=' + str(self.second), *args)

    def capture(self):
        return json.loads(self.log.read_text())

    def test_ordered_files_are_merged_once_with_private_permissions_and_cleanup(self):
        before = (self.first.read_bytes(), self.second.read_bytes())
        result = self.compose('config')
        self.assertEqual(result.returncode, 0, result.stderr)
        capture = self.capture()
        self.assertEqual(capture['args'].count('--env-file'), 1)
        self.assertEqual(capture['values']['OVERRIDE'], 'second')
        self.assertEqual(capture['values']['PORTAL_HYBRID_COMMAND_IMAGE'], 'release/command:pinned')
        self.assertEqual(capture['mode'], 0o600)
        self.assertFalse(Path(capture['file']).exists())
        self.assertEqual((self.first.read_bytes(), self.second.read_bytes()), before)
        self.assertIn('release/gateway:pinned', result.stdout)

    def test_exported_image_override_remains_effective(self):
        self.env['LIGHT_GATEWAY_IMAGE'] = 'owner/gateway:override'
        result = self.compose('config')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('owner/gateway:override', result.stdout)

    def test_config_quiet_hides_rendered_secrets(self):
        result = self.compose('config', '--quiet')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '')
        self.assertNotIn('--quiet', self.capture()['args'])

    def test_provider_errors_preserve_exit_stderr_and_cleanup(self):
        self.env['PROVIDER_FAIL'] = '1'
        result = self.compose('config', '-q')
        self.assertEqual(result.returncode, 7)
        self.assertIn('provider refused', result.stderr)
        self.assertFalse(Path(self.capture()['file']).exists())

    def test_missing_file_refuses_before_provider_and_cleans_temporary_file(self):
        self.second.unlink()
        result = self.compose('config')
        self.assertEqual(result.returncode, 2)
        self.assertIn('missing environment file', result.stderr)
        self.assertFalse(self.log.exists())
        self.assertEqual(list(self.base.glob('portal-podman-env.*')), [])

    def test_engine_arguments_and_stdin_pass_through(self):
        result = self.call('run', '--rm', '-i', 'fixture:tag', 'argument with spaces', input='streamed data')
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data['args'], ['run', '--rm', '-i', 'fixture:tag', 'argument with spaces'])
        self.assertEqual(data['stdin'], 'streamed data')

    def test_service_arguments_are_not_reinterpreted_as_global_env_flags(self):
        result = self.call('compose', 'run', 'service', '--env-file', str(self.first), '--quiet')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.capture()['args'], ['run', 'service', '--env-file', str(self.first), '--quiet'])

    def test_real_runner_reads_sso_config_through_single_file_provider(self):
        (self.base / 'docker-images.env').write_bytes(self.first.read_bytes())
        (self.base / '.env.bootstrap').write_bytes(self.second.read_bytes())
        cli = portable.cli
        self.env.update(BOOTSTRAP_ENV_FILE=str(self.base / '.env.bootstrap'),
                        LIGHT_PORTAL_ENV_FILE=str(self.base / 'no-private.env'))
        with patch.dict(os.environ, self.env, clear=True), patch.object(cli, 'BASE', self.base), \
                patch.object(cli, 'SERVICE', 'portal-bff-sso'):
            runner = cli.RealRunner()
        self.assertEqual(runner.image, 'release/gateway:pinned')
        self.assertFalse(Path(self.capture()['file']).exists())
