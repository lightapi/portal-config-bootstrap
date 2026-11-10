#!/usr/bin/env python3
"""Repository signed release command. Importing this module performs no effects."""
import argparse
import http.client
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
SERVICE = 'light-gateway'


def check_runtime_configuration(path):
    """Report unconfigured Entra identifiers before downloads or container work."""
    value = release.read_json(path)
    authentication = value.get('authentication', {}) if isinstance(value, dict) else {}
    if not isinstance(authentication, dict) or authentication.get('mode') != 'entra-sso':
        return  # The gateway remains authoritative for the full runtime schema.
    for field in ('tenantId', 'clientId'):
        identifier = authentication.get(field)
        valid = isinstance(identifier, str) and re.fullmatch(
            r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', identifier)
        release.require(valid and len(set(identifier.replace('-', '').lower())) > 1,
                        str(path) + ': authentication.' + field
                        + ' must be the registered Entra UUID, not an example placeholder; '
                        'configure the tenant/client IDs and registered redirect URLs before prepare')


def public_validation_inputs(release_dir, runtime_config, key_dir):
    """Make verified public inputs readable by the container's non-root user."""
    release_dir, key_dir = release.directory(release_dir), release.directory(key_dir)
    # Authenticate the tree before changing permissions, including existing stages.
    manifest = release.verify_signature(release_dir, key_dir)
    release.verify_tree(manifest, release_dir / 'dist')
    key = release.regular(key_dir / (manifest['signature']['keyId'] + '.pem'))
    pem = key.read_bytes()
    release.require(b'-----BEGIN PUBLIC KEY-----' in pem and b'PRIVATE KEY' not in pem,
                    'trust directory accepts public keys only')
    runtime_config = release.regular(runtime_config)
    directories, files = [release_dir], []
    for item in release_dir.rglob('*'):
        if stat.S_ISDIR(item.lstat().st_mode):
            directories.append(release.directory(item))
        else:
            files.append(release.regular(item))
    permissions = [(item, 0o555) for item in directories] + [(item, 0o444) for item in files]
    # Preserve operator write access on these public, separately mounted inputs.
    permissions += [(key_dir, stat.S_IMODE(key_dir.stat().st_mode) | 0o555)]
    permissions += [(item, stat.S_IMODE(item.stat().st_mode) | 0o444) for item in (key, runtime_config)]
    for item, mode in permissions:
        if stat.S_IMODE(item.stat().st_mode) != mode:
            item.chmod(mode)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise release.ActivationError('readback redirects are refused')


def parse_compose_config(text, service):
    """Read one service's image and ports from `compose config` YAML.

    podman-compose cannot print JSON, and PyYAML may be unavailable on locked-down
    hosts, so this reads only the block style those tools normalize to. Anything
    outside it is refused rather than guessed.
    """
    def unsupported():
        raise release.ActivationError('compose config output is not in a supported format')

    def scalar(value):
        value = value.strip()
        if value[:1] in ('"', "'"):
            quoted = re.fullmatch(r'(["\'])(.*?)\1(?:\s+#.*)?', value)
            if not quoted:
                unsupported()
            return quoted.group(2)
        value = re.sub(r'\s+#.*$', '', value)
        if not value or value[0] in '[{|>&*!':
            unsupported()
        return value

    def number(value):
        return int(value) if value.isdigit() else value

    lines = [(len(raw) - len(raw.lstrip(' ')), raw.strip()) for raw in text.splitlines()
             if raw.strip() and not raw.lstrip().startswith('#')]

    def body(rows, start):
        end = start + 1
        while end < len(rows) and rows[end][0] > rows[start][0]:
            end += 1
        return rows[start + 1:end]

    top = next((i for i, (indent, line) in enumerate(lines) if indent == 0 and line == 'services:'), None)
    if top is None:
        unsupported()
    services = body(lines, top)
    start = next((i for i, (indent, line) in enumerate(services)
                  if indent == services[0][0] and line == service + ':'), None)
    release.require(start is not None, 'compose config has no ' + service + ' service')
    fields = body(services, start)
    image, ports = None, []
    index = 0
    while index < len(fields):
        indent, line = fields[index]
        index += 1
        if indent != fields[0][0]:
            continue
        if line.startswith('image:'):
            image = scalar(line[len('image:'):])
        elif line == 'ports:' or line.startswith('ports: '):
            if line != 'ports:':
                if line[len('ports:'):].strip() != '[]':
                    unsupported()
                continue
            items = []
            while index < len(fields) and (fields[index][0] > indent
                                           or (fields[index][0] == indent and fields[index][1].startswith('-'))):
                if fields[index][1].startswith('-') and fields[index][0] >= indent:
                    items.append([fields[index]])
                elif not items:
                    unsupported()
                else:
                    items[-1].append(fields[index])
                index += 1
            for item in items:
                first = item[0][1][1:].strip()
                key = re.match(r'(target|published|mode|protocol|host_ip|name|app_protocol):\s*(.*)$', first)
                if not key:
                    port = scalar(first).split('/')[0].split(':')
                    ports.append({'target': number(port[-1]),
                                  'published': port[-2] if len(port) > 1 and port[-2] else None})
                    continue
                pairs = {key.group(1): key.group(2)}
                for _, extra in item[1:]:
                    match = re.match(r'([a-z_]+):\s*(.*)$', extra)
                    if match:
                        pairs.setdefault(match.group(1), match.group(2))
                port = {'target': number(scalar(pairs['target'])) if 'target' in pairs else None}
                if pairs.get('published'):
                    port['published'] = scalar(pairs['published'])
                ports.append(port)
    return {'services': {service: {'image': image, 'ports': ports}}}


class RealRunner:
    """Repository Compose adapter; all effects are injectable for isolated tests."""
    def __init__(self, readback_url=None, execute=None, opener_factory=None):
        self.execute = execute or subprocess.run
        self.opener_factory = opener_factory or urllib.request.build_opener
        self.cmd, self.env = compose_command(BASE, os.environ)
        result = self.run(self.cmd + ['config', '--format', 'json'], check=False)
        if result.returncode == 0:
            self.config = json.loads(result.stdout)
        else:
            # podman-compose rejects --format; read its YAML output instead.
            result = self.run(self.cmd + ['config'])
            self.config = parse_compose_config(result.stdout, SERVICE)
        self.image = self.config.get('services', {}).get(SERVICE, {}).get('image')
        release.require(isinstance(self.image, str) and self.image and not self.image.startswith('-'), 'target gateway image is missing')
        self.recreate_command = shlex.join(self.cmd + ['up', '-d', '--no-deps', '--force-recreate', SERVICE])
        default = urllib.parse.urlsplit(DEFAULT_READBACK)
        ports = self.config['services'][SERVICE].get('ports', [])
        published = next((port.get('published') for port in ports if isinstance(port, dict) and port.get('target') == 8443), None)
        if published is not None:
            release.require(str(published).isdigit() and 1 <= int(published) <= 65535, 'invalid gateway published port')
        self.readback_origin = default.scheme + '://' + default.hostname + (':' + str(published) if published is not None else '')
        self.explicit_readback = readback_url is not None
        self.url = readback_url or self.readback_origin + '/'
        parsed = urllib.parse.urlsplit(self.url)
        release.require(parsed.scheme == 'https' and parsed.hostname and not parsed.username
                        and not parsed.password and not parsed.fragment, 'readback URL must be HTTPS without credentials or fragment')
        self.opener = None

    def use_mount_path(self, mount_path):
        """Default readback targets the SPA mount; an explicit --readback-url wins."""
        if not self.explicit_readback:
            self.url = self.readback_origin + release.readback_path(mount_path)

    def run(self, args, check=True, timeout=180):
        result = self.execute(args, cwd=BASE, env=self.env, capture_output=True, text=True, timeout=timeout)
        detail = result.stderr.strip()[-400:] if isinstance(result.stderr, str) else ''
        release.require(not check or result.returncode == 0,
                        'command failed: ' + shlex.join(args) + (': ' + detail if detail else ''))
        return result

    def ensure_image(self):
        result = self.run(['docker', 'image', 'inspect', self.image], check=False)
        if result.returncode == 0:
            return
        # Do not convert daemon/auth/transport failures into image absence.
        detail = result.stderr.strip()
        podman_missing = result.returncode == 125 and re.search(
            r'^Error: [^\r\n]+: image not known\s*$', detail, re.I | re.M)
        missing = 'no such image' in detail.lower() or podman_missing
        release.require(missing, 'cannot inspect target gateway image ' + self.image
                        + ' (exit ' + str(result.returncode) + ')'
                        + (': ' + detail[-400:] if detail else ''))
        self.run(['docker', 'pull', self.image], timeout=600)
        self.run(['docker', 'image', 'inspect', self.image])

    def validate_offline(self, release_dir, runtime_config, key_dir, mount_path, handler_config):
        check_runtime_configuration(runtime_config)
        public_validation_inputs(release_dir, runtime_config, key_dir)
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
        if result.returncode != 0 or report.get('status') != 'ok':
            detail = report.get('error')
            if not isinstance(detail, str) or not detail:
                detail = 'gateway returned status ' + repr(report.get('status'))
            # Bound and flatten gateway diagnostics; do not dump config or environment.
            detail = ' '.join(detail.split())[:2000]
            raise release.ActivationError('offline validation failed (exit '
                                          + str(result.returncode) + '): ' + detail)
        release.require(type(report.get('capability')) is int and report['capability'] >= 1
                        and isinstance(report.get('version'), str)
                        and isinstance(report.get('manifestDigest'), str)
                        and re.fullmatch('[0-9a-f]{64}', report['manifestDigest'])
                        and isinstance(report.get('runtimeConfigDigest'), str)
                        and re.fullmatch('[0-9a-f]{64}', report['runtimeConfigDigest']), 'incomplete offline validation result')
        return report

    def recreate_gateways(self):
        # Only explicit owner lifecycle commands use this; never preparation.
        self.run(self.cmd + ['up', '-d', '--no-deps', '--force-recreate', SERVICE])

    def trust(self):
        if self.opener is None:
            ca = BASE / 'portal-bff-sso/tls/ca.pem' if SERVICE == 'portal-bff-sso' else CONFIG / 'ca.pem'
            context = ssl.create_default_context(cafile=str(ca)) if ca.is_file() else ssl.create_default_context()
            self.opener = self.opener_factory(urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=context), NoRedirect())
        return self.opener

    def read_release_digest(self, timeout=10):
        try:
            with self.trust().open(urllib.request.Request(self.url, method='HEAD'), timeout=timeout) as response:
                if response.status != 200:
                    raise urllib.error.HTTPError(self.url, response.status, 'HEAD readback did not return HTTP 200', {}, None)
                return response.headers.get('X-Portal-Release-Digest')
        except (OSError, http.client.HTTPException) as error:
            raise release.readback_error(error) from error

    def gateway_healthy(self, timeout=10):
        try:
            with self.trust().open(urllib.request.Request(self.url, method='GET'), timeout=timeout) as response:
                if response.status != 200:
                    raise urllib.error.HTTPError(self.url, response.status, 'GET readback did not return HTTP 200', {}, None)
                return True
        except (OSError, http.client.HTTPException) as error:
            raise release.readback_error(error) from error


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


def resolve_source(base, enclosing, transport):
    """Resolve latest once; all payloads then come from a versioned directory."""
    source = base.rstrip('/') + '/' + enclosing + '/portal-view'
    if enclosing == 'latest':
        with transport.open(source + '/release-pointer.env', timeout=60) as response:
            release.require(response.status == 200, 'release pointer did not return HTTP 200')
            data = response.read(4097)
        release.require(len(data) <= 4096, 'release pointer is too large')
        try:
            text = data.decode('ascii')
        except UnicodeError as error:
            raise release.ActivationError('release pointer must be ASCII') from error
        release.require(text.startswith('LIGHT_PORTAL_VERSION=') and text.count('\n') == 1
                        and text.endswith('\n'), 'malformed release pointer')
        enclosing = release.component(text.strip().split('=', 1)[1])
        release.require(enclosing != 'latest', 'release pointer must select a versioned release')
        source = base.rstrip('/') + '/' + enclosing + '/portal-view'
    return source


def configured_release_base(override=None):
    base = override or os.environ.get('LIGHT_PORTAL_RELEASE_BASE_URL', os.environ.get('LIGHT_PORTAL_ASSET_BASE_URL', 'https://cdn.networknt.com').rstrip('/') + '/light-portal/releases')
    parsed = urllib.parse.urlsplit(base)
    release.require(parsed.scheme == 'https' and parsed.hostname and not parsed.username and not parsed.password
                    and not parsed.query and not parsed.fragment, 'release base must be HTTPS without credentials/query/fragment')
    return base


def validate_image_env(data):
    """Release metadata is image references only, never shell or Compose controls."""
    release.require(len(data) <= 65536, 'release image environment exceeds 64 KiB')
    try:
        lines = data.decode('ascii').splitlines()
    except UnicodeError as error:
        raise release.ActivationError('release image environment must be ASCII') from error
    values = {}
    for number, line in enumerate(lines, 1):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        key, separator, value = line.partition('=')
        release.require(separator and re.fullmatch(r'[A-Z][A-Z0-9_]*_IMAGE', key),
                        'invalid release image environment key at line ' + str(number))
        release.require(key not in values, 'duplicate release image environment key at line ' + str(number))
        release.require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._/:@-]*', value),
                        'invalid release image reference at line ' + str(number))
        if '@' in value:
            valid = re.fullmatch(r'[^@]+@sha256:[0-9a-f]{64}', value)
        else:
            valid = re.fullmatch(r'[^:]+:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}', value.rsplit('/', 1)[-1])
        release.require(valid, 'release image reference must have a tag or sha256 digest at line ' + str(number))
        values[key] = value
    release.require(all(values.get(key) for key in ('PORTAL_HYBRID_COMMAND_IMAGE', 'PORTAL_HYBRID_QUERY_IMAGE')),
                    'release image environment must select both packaged Portal hybrid images')


def ensure_image_env(source, transport):
    """Acquire missing image metadata from the already resolved enclosing release."""
    target = BASE / 'docker-images.env'
    if os.path.lexists(target):
        release.regular(target)
        return target
    url = source.rsplit('/', 1)[0] + '/docker-images.env'
    try:
        with transport.open(url, timeout=60) as response:
            release.require(response.status == 200, 'release image environment did not return HTTP 200')
            data = response.read(65537)
    except urllib.error.HTTPError as error:
        raise release.ActivationError('release image environment download failed: HTTP ' + str(error.code)) from error
    validate_image_env(data)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(prefix='.docker-images-', suffix='.tmp', dir=BASE, delete=False) as output:
            temporary = Path(output.name)
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        try:
            # Atomic publication without replacing a file another operator just created.
            os.link(temporary, target)
        except FileExistsError:
            release.regular(target)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    print('PORTAL_VIEW_RELEASE: release image environment available at ' + str(target))
    return target


def image_env(enclosing, release_base=None, opener=None):
    release.component(enclosing)
    base = configured_release_base(release_base)
    target = BASE / 'docker-images.env'
    if os.path.lexists(target):
        return release.regular(target)
    transport = opener if opener is not None else release.download_opener(NoRedirect())
    source = resolve_source(base, enclosing, transport)
    return ensure_image_env(source, transport)


def prepare(enclosing, release_base=None, runner_factory=RealRunner, opener=None):
    """Resolve and prepare a verified signed package; missing publication fails closed."""
    release.component(enclosing)
    check_runtime_configuration(CONFIG / 'portal-config.json')
    base = configured_release_base(release_base)
    transport = opener if opener is not None else release.download_opener(NoRedirect())
    try:
        source = resolve_source(base, enclosing, transport)
        with transport.open(source + '/portal-view-release.env', timeout=60) as response:
            release.require(response.status == 200, 'release env did not return HTTP 200')
            version = metadata_version(response.read(4097))
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise release.ActivationError('signed release metadata download failed: HTTP ' + str(error.code)) from error
        raise release.ActivationError('signed Portal View release not published for ' + enclosing
                                      + '; publication is required before preparation') from error
    ROOT.mkdir(parents=True, exist_ok=True)
    with release.locked(ROOT):
        release.consistent(ROOT)  # Refuse a retained journal before any download.
    def download(url, destination):
        with transport.open(url, timeout=60) as response, destination.open('xb') as output:
            release.require(response.status == 200, 'signed release member download failed')
            shutil.copyfileobj(response, output)
    release.stage(source, version, ROOT, CONFIG / 'portal-view-release-keys', downloader=download)
    try:
        if MODE == 'bootstrap':
            ensure_image_env(source, transport)
        real = runner_factory(None)
        real.ensure_image()
    except Exception:
        print('PORTAL_VIEW_RELEASE: verified staged ' + version + '; not prepared; current/state/journal unchanged', file=sys.stderr)
        raise
    ctx = release.Context(release.Runner(real.validate_offline, real.recreate_gateways, real.read_release_digest, real.gateway_healthy),
                          CONFIG / 'portal-config.json', CONFIG / 'portal-view-release-keys')
    ctx.recreate_command = real.recreate_command
    outcome, active = release.prepare(version, ROOT, ctx)
    if outcome == 'prepared':
        print('PORTAL_VIEW_RELEASE: prepared ' + version + '; serving cutover remains an owner action')
    elif outcome == 'unchanged':
        print('PORTAL_VIEW_RELEASE: ' + version + ' already prepared; verified offline, serving not read back')
    else:
        print('PORTAL_VIEW_RELEASE: WARNING: verified and staged ' + version + ' while ' + active
              + ' remains active; active/rollback state unchanged. Activate explicitly: '
              + 'python3 -B scripts/portal-view-release.py '
              + ('--service portal-bff-sso ' if SERVICE == 'portal-bff-sso' else '')
              + 'activate --version ' + version, file=sys.stderr)


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
    cli.add_argument('--service', choices=('light-gateway', 'portal-bff-sso'), default='light-gateway')
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
    prep.add_argument('--enclosing-version', default=os.environ.get('LIGHT_PORTAL_VERSION', 'latest'))
    prep.add_argument('--release-base')
    images = commands.add_parser('image-env', help='download missing release image selections without running Compose')
    images.add_argument('--enclosing-version', default=os.environ.get('LIGHT_PORTAL_VERSION', 'latest'))
    images.add_argument('--release-base')
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
    release.require(enclosing != 'latest', 'stage requires a pinned LIGHT_PORTAL_VERSION; use prepare to resolve latest, then pin the enclosing release and artifact version')
    base = env.get('LIGHT_PORTAL_ASSET_BASE_URL', 'https://cdn.networknt.com').rstrip('/')
    parsed = urllib.parse.urlsplit(base)
    release.require(parsed.scheme == 'https' and parsed.hostname and not parsed.username
                    and not parsed.password and not parsed.query and not parsed.fragment, 'asset base must be HTTPS without credentials/query/fragment')
    release_base = env.get('LIGHT_PORTAL_RELEASE_BASE_URL', base + '/light-portal/releases').rstrip('/')
    parsed = urllib.parse.urlsplit(release_base)
    release.require(parsed.scheme == 'https' and parsed.hostname and not parsed.username
                    and not parsed.password and not parsed.query and not parsed.fragment, 'release base must be HTTPS without credentials/query/fragment')
    return resolve_source(release_base, enclosing, None)


def select_sso():
    """Select independent SSO assets/state and the exact effective Compose image."""
    global ROOT, CONFIG, SERVICE, DEFAULT_READBACK
    ROOT = BASE / 'portal-bff-sso/lightapi'
    CONFIG = BASE / 'portal-bff-sso/config'
    SERVICE = 'portal-bff-sso'
    env_file = Path(os.environ.get('BOOTSTRAP_ENV_FILE', str(BASE / '.env.bootstrap')))
    host = os.environ.get('CUSTOMER_PORTAL_HOST') or local_env_value(env_file, 'CUSTOMER_PORTAL_HOST') or 'dev.yourcompany.com'
    release.require(re.fullmatch(r'[A-Za-z0-9.-]+', host), 'invalid CUSTOMER_PORTAL_HOST')
    DEFAULT_READBACK = 'https://' + host + '/'


def main(argv=None, runner_factory=RealRunner):
    try:
        args = parser().parse_args(argv)
        if args.service == 'portal-bff-sso':
            select_sso()
        if args.command == 'image-env':
            image_env(args.enclosing_version, args.release_base)
        elif args.command == 'prepare':
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
            if hasattr(real, 'use_mount_path'):
                real.use_mount_path(args.mount_path)
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
