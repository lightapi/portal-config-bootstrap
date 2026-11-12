"""Startup diagnostics through the real CLI, without deployment operations."""
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch


CLI = Path(__file__).resolve().with_name('portal-view-release.py')


class DiagnosticsTests(unittest.TestCase):
    def command(self, arguments, enabled=False):
        env = os.environ.copy()
        for name in ('PORTAL_VIEW_DEBUG', 'PORTAL_VIEW_TRACE'):
            env.pop(name, None)
        if enabled:
            env['PORTAL_VIEW_TRACE'] = '1'
        env['PRIVATE_DIAGNOSTIC_SENTINEL'] = 'do-not-print-this-value'
        return subprocess.run([sys.executable, '-B', *arguments], env=env,
                              capture_output=True, text=True, timeout=20)

    def test_help_has_no_diagnostics_by_default(self):
        result = self.command([str(CLI), '--help'], False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('usage:', result.stdout)
        self.assertEqual(result.stderr, '')

    def test_import_stays_silent_even_when_enabled(self):
        code = ('import sys, runpy; from pathlib import Path; '
                'sys.path.insert(0, str(Path(sys.argv[1]).parent)); '
                'runpy.run_path(sys.argv[1], run_name="diagnostic")')
        result = self.command(['-c', code, str(CLI)], True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout + result.stderr, '')

    def test_line_trace_reports_script_lines_without_source_or_values(self):
        result = self.command([str(CLI), '--help'], True)
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
        result = self.command(['-c', code, str(CLI)], True)
        self.assertEqual(result.returncode, 86, result.stderr)
        import_line = CLI.read_text().splitlines().index('import argparse') + 1
        self.assertTrue(result.stderr.splitlines()[-1].endswith('portal-view-release.py:' + str(import_line)))

    def test_ambient_diagnostic_settings_do_not_enable_child_tracing(self):
        with patch.dict(os.environ, {'PORTAL_VIEW_DEBUG': '1', 'PORTAL_VIEW_TRACE': '1'}):
            result = self.command([str(CLI), '--help'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')

    def test_broken_or_closed_stderr_does_not_change_help_exit_or_output(self):
        baseline = self.command([str(CLI), '--help'])
        for close in ("os.close(2)",
                      "r,w=os.pipe(); os.close(r); os.dup2(w,2); os.close(w)",
                      "sys.stderr.close()"):
            with self.subTest(close=close):
                code = ("import os,sys,runpy; from pathlib import Path; "
                        "sys.path.insert(0,str(Path(sys.argv[1]).parent)); "
                        "filename=sys.argv[1]; sys.argv=[filename,'--help']; "
                        + close + "; runpy.run_path(filename,run_name='__main__')")
                result = self.command(['-c', code, str(CLI)], True)
                self.assertEqual(result.returncode, baseline.returncode, result.stderr)
                self.assertEqual(result.stdout, baseline.stdout)
                self.assertNotIn('ACTIVATION_REFUSED', result.stderr)
                self.assertNotIn('BrokenPipeError', result.stderr)
