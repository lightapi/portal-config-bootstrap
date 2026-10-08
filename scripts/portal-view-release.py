#!/usr/bin/env python3
"""Repository signed release command. Importing this module performs no effects."""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import ssl
import subprocess
import sys
import shutil
import stat
import tempfile
import zipfile
import urllib.error
import urllib.parse
import urllib.request

import portal_view_release as release

BASE = Path(__file__).resolve().parents[1]
ROOT = BASE / 'light-gateway-rust/lightapi'
CONFIG = BASE / 'light-gateway-rust/config'
MODE = 'bootstrap'
DEFAULT_READBACK = 'https://local.localhost/'

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise release.ActivationError('readback redirects are refused')


class RealRunner:
    """Repository Compose adapter; all effects are injectable for isolated tests."""
    def __init__(self, readback_url=None, execute=None, opener_factory=None):
        self.execute = execute or subprocess.run
        self.opener_factory = opener_factory or urllib.request.build_opener
        self.cmd, self.env = compose_command(BASE, os.environ)
        result = self.run(self.cmd + ['config', '--format', 'json'])
        self.config = json.loads(result.stdout)
        self.image = self.config.get('services', {}).get('light-gateway', {}).get('image')
        release.require(isinstance(self.image, str) and self.image and not self.image.startswith('-'), 'target gateway image is missing')
        self.recreate_command = shlex.join(self.cmd + ['up', '-d', '--no-deps', '--force-recreate', 'light-gateway'])
        default = urllib.parse.urlsplit(DEFAULT_READBACK)
        ports = self.config['services']['light-gateway'].get('ports', [])
        published = next((port.get('published') for port in ports if isinstance(port, dict) and port.get('target') == 8443), None)
        if published is not None:
            release.require(str(published).isdigit() and 1 <= int(published) <= 65535, 'invalid gateway published port')
        self.url = readback_url or (default.scheme + '://' + default.hostname + (':' + str(published) if published is not None else '') + '/')
        parsed = urllib.parse.urlsplit(self.url)
        release.require(parsed.scheme == 'https' and parsed.hostname and not parsed.username
                        and not parsed.password and not parsed.fragment, 'readback URL must be HTTPS without credentials or fragment')
        self.opener = None

    def run(self, args, check=True, timeout=180):
        result = self.execute(args, cwd=BASE, env=self.env, capture_output=True, text=True, timeout=timeout)
        release.require(not check or result.returncode == 0, 'command failed: ' + shlex.join(args))
        return result

    def ensure_image(self):
        result = self.run(['docker', 'image', 'inspect', self.image], check=False)
        if result.returncode == 0:
            return
        # Do not convert daemon/auth/transport failures into image absence.
        release.require('no such image' in result.stderr.lower(), 'cannot inspect target gateway image')
        self.run(['docker', 'pull', self.image], timeout=600)
        self.run(['docker', 'image', 'inspect', self.image])

    def validate_offline(self, release_dir, runtime_config, key_dir, mount_path, handler_config):
        args = ['docker', 'run', '--rm', '--network', 'none', '--pull', 'never']
        mounts = [(release.directory(release_dir), '/release'),
                  (release.regular(runtime_config), '/runtime/portal-config.json'),
                  (release.directory(key_dir), '/keys')]
        if handler_config is not None:
            mounts.append((release.regular(handler_config), '/runtime/handler.yml'))
        for source, destination in mounts:
            release.require(',' not in str(source), 'comma in Docker bind source')
            args += ['--mount', 'type=bind,src=' + str(source.resolve()) + ',dst=' + destination + ',readonly']
        args += [self.image, '/app/light-gateway', 'validate-portal-release',
                 '--release-dir', '/release', '--runtime-config', '/runtime/portal-config.json',
                 '--key-dir', '/keys', '--mount-path', mount_path]
        if handler_config is not None:
            args += ['--handler-config', '/runtime/handler.yml']
        result = self.run(args, check=False)
        try:
            report = json.loads(result.stdout)
        except (ValueError, TypeError) as error:
            raise release.ActivationError('gateway image does not support validate-portal-release or returned invalid JSON') from error
        release.require(isinstance(report, dict), 'invalid offline validation result')
        release.require(result.returncode == 0 and report.get('status') == 'ok', 'offline validation failed')
        release.require(type(report.get('capability')) is int and report['capability'] >= 1
                        and isinstance(report.get('version'), str)
                        and isinstance(report.get('manifestDigest'), str)
                        and re.fullmatch('[0-9a-f]{64}', report['manifestDigest'])
                        and isinstance(report.get('runtimeConfigDigest'), str)
                        and re.fullmatch('[0-9a-f]{64}', report['runtimeConfigDigest']), 'incomplete offline validation result')
        return report

    def recreate_gateways(self):
        # Only explicit owner lifecycle commands use this; never preparation.
        self.run(self.cmd + ['up', '-d', '--no-deps', '--force-recreate', 'light-gateway'])

    def trust(self):
        if self.opener is None:
            ca = CONFIG / 'ca.pem'
            context = ssl.create_default_context(cafile=str(ca)) if ca.is_file() else ssl.create_default_context()
            self.opener = self.opener_factory(urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=context), NoRedirect())
        return self.opener

    def read_release_digest(self):
        try:
            with self.trust().open(urllib.request.Request(self.url, method='HEAD'), timeout=10) as response:
                release.require(response.status == 200, 'HEAD readback did not return HTTP 200')
                return response.headers.get('X-Portal-Release-Digest')
        except OSError as error:
            raise release.ActivationError('HEAD release readback failed') from error

    def gateway_healthy(self):
        try:
            with self.trust().open(urllib.request.Request(self.url, method='GET'), timeout=10) as response:
                return response.status == 200
        except OSError:
            return False


def local_env_value(path, name):
    """Read a supported local Compose selection as data, never execute it."""
    for line in path.read_text().splitlines():
        if line.startswith(name + '='):
            return line.split('=', 1)[1].strip().strip('"')
    return None


def compose_command(base, environment):
    env = dict(environment)
    cmd = ['docker', 'compose']
    host = Path(env.get('LIGHT_PORTAL_ENV_FILE', str(Path(env.get('XDG_CONFIG_HOME', str(Path.home() / '.config'))) / 'lightapi/light-portal.env')))
    images = base / 'docker-images.env'
    if MODE == 'bootstrap':
        cmd += ['-f', str(base / 'docker-compose.yml'), '-f', str(base / 'docker-compose.bootstrap.yml')]
    if images.is_file():
        cmd += ['--env-file', str(images)]
    if MODE == 'installer':
        cmd += ['--env-file', str(base / '.env')]
    if host.is_file():
        cmd += ['--env-file', str(host)]
    if MODE == 'installer' and (base / 'light-workflow-runner-claude-personal/.runtime/runner.yml').is_file():
        cmd += ['-f', str(base / 'docker-compose.yml'), '-f', str(base / 'light-workflow-runner-claude-personal/controller.compose.yml')]
    if MODE == 'bootstrap':
        bootstrap = Path(env.get('BOOTSTRAP_ENV_FILE', str(base / '.env.bootstrap')))
        release.require(bootstrap.is_file(), 'bootstrap environment file is missing (copy .env.bootstrap.example)')
        cmd += ['--env-file', str(bootstrap)]
        project = local_env_value(bootstrap, 'COMPOSE_PROJECT_NAME') or 'light-portal-bootstrap'
        release.require(re.fullmatch('[a-z0-9][a-z0-9_-]*', project), 'invalid COMPOSE_PROJECT_NAME')
        env['COMPOSE_PROJECT_NAME'] = project
    return cmd, env


def legacy_dist(archive_path, root):
    """Validate a legacy dist archive before replacing only the legacy directory."""
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    release.directory(root)
    destination = root / 'dist'
    if os.path.lexists(destination):
        release.directory(destination)
    with tempfile.TemporaryDirectory(prefix='.legacy-sync-', dir=root) as temporary:
        owned = Path(temporary)
        with zipfile.ZipFile(release.regular(archive_path)) as archive:
            seen = set()
            for info in archive.infolist():
                name = info.filename.rstrip('/') if info.is_dir() else info.filename
                release.member_path(name)
                release.require(name == 'dist' or name.startswith('dist/'), 'legacy archive must contain only dist/')
                release.require(name not in seen, 'duplicate legacy archive member')
                seen.add(name)
                mode = stat.S_IFMT(info.external_attr >> 16)
                release.require(mode in (0, stat.S_IFDIR if info.is_dir() else stat.S_IFREG), 'non-regular legacy member')
            release.require('dist/index.html' in seen, 'legacy archive missing dist/index.html')
            # Paths and types are checked before extraction; payload bytes stay intact.
            archive.extractall(owned)
        release.regular(owned / 'dist/index.html')
        had_dist = os.path.lexists(destination)
        if had_dist:
            os.replace(destination, owned / 'previous-dist')
        try:
            os.replace(owned / 'dist', destination)
        except BaseException:
            if had_dist:
                os.replace(owned / 'previous-dist', destination)
            raise


def metadata_version(data):
    release.require(len(data) <= 4096, 'release env is too large')
    try:
        lines = data.decode('ascii').splitlines()
    except UnicodeError as error:
        raise release.ActivationError('release env must be ASCII data') from error
    values = [line for line in lines if line and not line.startswith('#')]
    release.require(len(values) == 1 and values[0].startswith('PORTAL_VIEW_VERSION='), 'malformed release env data')
    return release.component(values[0].split('=', 1)[1])


def prepare(enclosing, release_base=None, runner_factory=RealRunner, opener=None):
    """Optional signed discovery; only HTTP 404 means genuinely absent."""
    release.component(enclosing)
    base = release_base or os.environ.get('LIGHT_PORTAL_RELEASE_BASE_URL', os.environ.get('LIGHT_PORTAL_ASSET_BASE_URL', 'https://cdn.networknt.com').rstrip('/') + '/light-portal/releases')
    parsed = urllib.parse.urlsplit(base)
    release.require(parsed.scheme == 'https' and parsed.hostname and not parsed.username and not parsed.password
                    and not parsed.query and not parsed.fragment, 'release base must be HTTPS without credentials/query/fragment')
    source = base.rstrip('/') + '/' + enclosing + '/portal-view'
    transport = opener or urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    try:
        with transport.open(source + '/portal-view-release.env', timeout=60) as response:
            release.require(response.status == 200, 'release env did not return HTTP 200')
            version = metadata_version(response.read(4097))
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise release.ActivationError('signed release metadata download failed: HTTP ' + str(error.code)) from error
        print('portal-view signed release not published for ' + enclosing + '; serving legacy UI')
        return
    ROOT.mkdir(parents=True, exist_ok=True)
    with release.locked(ROOT):
        _, state = release.consistent(ROOT)
        release.require(state['active'] in (None, version),
                        'different release already active; stage separately and run python3 -B scripts/portal-view-release.py activate --version ' + version + ' explicitly')
    def download(url, destination):
        with transport.open(url, timeout=60) as response, destination.open('xb') as output:
            release.require(response.status == 200, 'signed release member download failed')
            shutil.copyfileobj(response, output)
    release.stage(source, version, ROOT, CONFIG / 'portal-view-release-keys', downloader=download)
    try:
        real = runner_factory(None)
        real.ensure_image()
    except Exception:
        print('PORTAL_VIEW_RELEASE: verified staged ' + version + '; not prepared; current/state/journal unchanged', file=sys.stderr)
        raise
    ctx = release.Context(release.Runner(real.validate_offline, real.recreate_gateways, real.read_release_digest, real.gateway_healthy),
                          CONFIG / 'portal-config.json', CONFIG / 'portal-view-release-keys')
    ctx.recreate_command = real.recreate_command
    release.activate(version, ROOT, ctx, pointer_only=True)
    print('PORTAL_VIEW_RELEASE: prepared ' + version + '; serving cutover remains an owner action')


def installer_config():
    CONFIG.mkdir(parents=True, exist_ok=True)
    config = CONFIG / 'portal-config.json'
    if not os.path.lexists(config):
        with config.open('xb') as output:
            output.write((BASE / 'portal-config.oauth2.template.json').read_bytes())
    keys = CONFIG / 'portal-view-release-keys'
    keys.mkdir(exist_ok=True)
    for key in (BASE / 'portal-view-release-keys').glob('*.pem'):
        data = release.regular(key).read_bytes()
        release.require(b'-----BEGIN PUBLIC KEY-----' in data and b'PRIVATE KEY' not in data, 'trust directory accepts public keys only')
        target = keys / key.name
        if os.path.lexists(target):
            release.require(release.regular(target).read_bytes() == data, 'existing trust key differs; enroll explicitly')
        else:
            with target.open('xb') as output:
                output.write(data)


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise UsageError(message)


class UsageError(Exception):
    pass


def parser():
    cli = Parser(description='Explicit verified Portal View release lifecycle (never run by bare lt)')
    commands = cli.add_subparsers(dest='command', required=True, parser_class=Parser)
    staging = commands.add_parser('stage')
    staging.add_argument('--version', required=True)
    staging.add_argument('--from-dir', type=Path)
    for name in ('activate', 'rollback', 'recover', 'recreate'):
        command = commands.add_parser(name)
        command.add_argument('--readback-url')
        command.add_argument('--mount-path', default='/')
        command.add_argument('--handler-config', type=Path)
        if name == 'activate':
            command.add_argument('--version', required=True)
            command.add_argument('--pointer-only', action='store_true')
        if name == 'recreate':
            command.add_argument('--expect-legacy', action='store_true')
    commands.add_parser('status')
    prep = commands.add_parser('prepare')
    prep.add_argument('--enclosing-version', required=True)
    prep.add_argument('--release-base')
    legacy = commands.add_parser('legacy-dist')
    legacy.add_argument('--archive', required=True, type=Path)
    legacy.add_argument('--root', required=True, type=Path)
    commands.add_parser('installer-config')
    return cli


def source_for(args, env):
    if args.from_dir is not None:
        return args.from_dir
    enclosing = env.get('LIGHT_PORTAL_VERSION')
    release.require(enclosing is not None and enclosing != '', 'remote stage requires explicit LIGHT_PORTAL_VERSION (enclosing release), separate from --version')
    release.component(enclosing)
    base = env.get('LIGHT_PORTAL_ASSET_BASE_URL', 'https://cdn.networknt.com').rstrip('/')
    parsed = urllib.parse.urlsplit(base)
    release.require(parsed.scheme == 'https' and parsed.hostname and not parsed.username
                    and not parsed.password and not parsed.query and not parsed.fragment, 'asset base must be HTTPS without credentials/query/fragment')
    release_base = env.get('LIGHT_PORTAL_RELEASE_BASE_URL', base + '/light-portal/releases').rstrip('/')
    parsed = urllib.parse.urlsplit(release_base)
    release.require(parsed.scheme == 'https' and parsed.hostname and not parsed.username
                    and not parsed.password and not parsed.query and not parsed.fragment, 'release base must be HTTPS without credentials/query/fragment')
    return release_base + '/' + enclosing + '/portal-view'


def main(argv=None, runner_factory=RealRunner):
    try:
        args = parser().parse_args(argv)
        if args.command == 'prepare':
            prepare(args.enclosing_version, args.release_base, runner_factory)
        elif args.command == 'legacy-dist':
            legacy_dist(args.archive, args.root)
        elif args.command == 'installer-config':
            release.require(MODE == 'installer', 'installer-config is installer only')
            installer_config()
        elif args.command == 'status':
            print('PORTAL_VIEW_RELEASE: ' + json.dumps(release.status(ROOT), sort_keys=True))
        elif args.command == 'stage':
            release.component(args.version)
            release.stage(source_for(args, os.environ), args.version, ROOT, CONFIG / 'portal-view-release-keys')
            print('PORTAL_VIEW_RELEASE: staged ' + args.version + '; serving unchanged')
        else:
            if args.command == 'activate':
                release.component(args.version)
            real = runner_factory(args.readback_url)
            runner = release.Runner(real.validate_offline, real.recreate_gateways, real.read_release_digest, real.gateway_healthy)
            ctx = release.Context(runner, CONFIG / 'portal-config.json', CONFIG / 'portal-view-release-keys', args.mount_path, args.handler_config)
            if hasattr(real, 'recreate_command'):
                ctx.recreate_command = real.recreate_command
            if args.command == 'activate':
                release.activate(args.version, ROOT, ctx, args.pointer_only)
            elif args.command == 'rollback':
                release.rollback(ROOT, ctx)
            elif args.command == 'recover':
                release.recover(ROOT, ctx)
            else:
                release.recreate(ROOT, ctx, args.expect_legacy)
            print('PORTAL_VIEW_RELEASE: ' + args.command + ' complete')
        return 0
    except UsageError as error:
        print('PORTAL_VIEW_RELEASE: usage: ' + str(error), file=sys.stderr)
        return 1
    except release.RecoveryFailed as error:
        print('PORTAL_VIEW_RECOVERY_FAILED: ' + str(error), file=sys.stderr)
        return 3
    except (release.ActivationError, OSError, ValueError, KeyError, zipfile.BadZipFile, subprocess.SubprocessError) as error:
        print('PORTAL_VIEW_ACTIVATION_REFUSED: ' + str(error), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
