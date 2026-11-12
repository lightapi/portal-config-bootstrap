"""Startup diagnostics through the real CLI, without deployment operations."""
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch


CLI = Path(__file__).resolve().with_name('portal-view-release.py')


class DiagnosticsTests(unittest.TestCase):
    def command(self, arguments, enabled):
        env = os.environ.copy()
        env.pop('PORTAL_VIEW_DEBUG', None)
        if enabled:
            env['PORTAL_VIEW_DEBUG'] = '1'
        env['PRIVATE_DIAGNOSTIC_SENTINEL'] = 'do-not-print-this-value'
        return subprocess.run([sys.executable, '-B', *arguments], env=env,
                              capture_output=True, text=True, timeout=20)

    def test_help_has_no_diagnostics_by_default(self):
        result = self.command([str(CLI), '--help'], False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('usage:', result.stdout)
        self.assertEqual(result.stderr, '')

    def test_direct_help_marks_startup_and_parser_entry(self):
        result = self.command([str(CLI), '--help'], True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('usage:', result.stdout)
        events = []
        for line in result.stderr.splitlines():
            self.assertRegex(line, r'^PORTAL_VIEW_DEBUG: pid=[0-9]+ [a-z.-]+$')
            events.append(line.rsplit(' ', 1)[1])
        self.assertEqual(events, ['startup.before-imports', 'startup.after-imports',
                                  'startup.before-main', 'main.enter', 'arguments.parse.begin'])
        self.assertNotIn('do-not-print-this-value', result.stdout + result.stderr)

    def test_import_stays_silent_even_when_enabled(self):
        code = ('import sys, runpy; from pathlib import Path; '
                'sys.path.insert(0, str(Path(sys.argv[1]).parent)); '
                'runpy.run_path(sys.argv[1], run_name="diagnostic")')
        result = self.command(['-c', code, str(CLI)], True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout + result.stderr, '')

    def test_first_marker_survives_abrupt_exit_before_argparse_import(self):
        # _exit deliberately skips normal Python cleanup and buffer flushing.
        code = '''import builtins, os, runpy, sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]).parent))
original = builtins.__import__
def importing(name, *args, **kwargs):
    if name == 'argparse':
        os._exit(86)
    return original(name, *args, **kwargs)
builtins.__import__ = importing
runpy.run_path(sys.argv[1], run_name='__main__')
'''
        result = self.command(['-c', code, str(CLI)], True)
        self.assertEqual(result.returncode, 86, result.stderr)
        self.assertRegex(result.stderr, r'^PORTAL_VIEW_DEBUG: pid=[0-9]+ startup.before-imports\n$')

    def test_line_trace_reports_script_lines_without_source_or_values(self):
        with patch.dict(os.environ, {'PORTAL_VIEW_TRACE': '1'}):
            result = self.command([str(CLI), '--help'], False)
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stderr.splitlines()
        self.assertGreater(len(lines), 20)
        for line in lines:
            self.assertRegex(line, r'^PORTAL_VIEW_TRACE: pid=[0-9]+ portal[-_]view[-_]release\.py:[0-9]+$')
        source = CLI.read_text().splitlines()
        import_line = source.index('import argparse') + 1
        self.assertTrue(any(line.endswith('portal-view-release.py:' + str(import_line)) for line in lines))
        self.assertTrue(any('portal_view_release.py:' in line for line in lines))
        self.assertNotIn('do-not-print-this-value', result.stdout + result.stderr)
        self.assertNotIn('import argparse', result.stderr)

    def test_line_trace_survives_abrupt_exit_on_the_reported_line(self):
        code = '''import builtins, os, runpy, sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]).parent))
original = builtins.__import__
def importing(name, *args, **kwargs):
    if name == 'argparse':
        os._exit(86)
    return original(name, *args, **kwargs)
builtins.__import__ = importing
runpy.run_path(sys.argv[1], run_name='__main__')
'''
        with patch.dict(os.environ, {'PORTAL_VIEW_TRACE': '1'}):
            result = self.command(['-c', code, str(CLI)], False)
        self.assertEqual(result.returncode, 86, result.stderr)
        import_line = CLI.read_text().splitlines().index('import argparse') + 1
        self.assertTrue(result.stderr.splitlines()[-1].endswith('portal-view-release.py:' + str(import_line)))
