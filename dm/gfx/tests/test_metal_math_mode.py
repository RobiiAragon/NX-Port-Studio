"""Owned GPU controls for the packaging chain's actual precise rewrite and flags.

Extract only pure AST nodes: importing dmsh_build starts a game build. No game
inputs or caches are used. --fixture-dir must name a private scratch directory.
"""
import argparse
import ast
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[3]
BUILD = ROOT / 'dm/gfx/tools/dmsh_build.py'


def packaging_contract():
    nodes = ast.parse(BUILD.read_text()).body
    flags = next(n for n in nodes if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'MAC_METAL' for t in n.targets))
    rewrite = next(n for n in nodes if isinstance(n, ast.FunctionDef) and n.name == 'precise')
    namespace = {'re': re}
    exec(compile(ast.Module(body=[rewrite], type_ignores=[]), str(BUILD), 'exec'), namespace)
    command = ast.literal_eval(flags.value)
    record = next(n for n in nodes if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'MAC_RECORD' for t in n.targets))
    namespace['MAC_METAL'] = command
    exec(compile(ast.Module(body=[record], type_ignores=[]), str(BUILD), 'exec'), namespace)
    return command, namespace['precise'], namespace['MAC_RECORD']


class MacMetalMathPolicy(unittest.TestCase):
    def test_real_packaging_flags_and_record_preserve_nonfinite_values(self):
        flags, _, record = packaging_contract()
        self.assertEqual([f for f in flags if f.startswith('-fmetal-math-mode=')], ['-fmetal-math-mode=relaxed'])
        self.assertIn('-O1', flags)
        self.assertIn('-fpreserve-invariance', flags)
        self.assertEqual(record, ' '.join(flags) + '; xcrun -sdk macosx metallib')

    def test_real_precise_rewrite_changes_only_minimum_maximum_and_clamp(self):
        _, rewrite, _ = packaging_contract()
        source = 'fast::min(a,b); fast::max(a,b); fast::clamp(a,0,1); fast::sqrt(a); breakfast::min(a,b);'
        self.assertEqual(rewrite(source), 'precise::min(a,b); precise::max(a,b); precise::clamp(a,0,1); fast::sqrt(a); breakfast::min(a,b);')


def run(directory):
    directory.mkdir(parents=True, exist_ok=True)
    flags, precise, record = packaging_contract()
    raw = Path(__file__).with_name('metal_math_mode.metal').read_text()
    rewritten = precise(raw)
    assert 'fast::min(' not in rewritten and 'precise::min(' in rewritten
    assert 'precise::max(' in rewritten and 'precise::clamp(' in rewritten
    source = directory / 'owned.metal'
    source.write_text(rewritten)
    runner = directory / 't_metal_math_mode'
    subprocess.run(['clang', '-O1', '-g', '-Wall', '-Wextra', '-Werror', '-fobjc-arc', str(Path(__file__).with_name('t_metal_math_mode.m')), '-framework', 'Foundation', '-framework', 'Metal', '-o', str(runner)], check=True)
    base = [f for f in flags if not f.startswith('-fmetal-math-mode=')]
    modes = {'current': flags, 'relaxed': [*base, '-fmetal-math-mode=relaxed'], 'fast': [*base, '-fmetal-math-mode=fast']}
    results = []
    for mode, command in modes.items():
        air, library = directory / f'{mode}.air', directory / f'{mode}.metallib'
        subprocess.run([*command, '-fmodules-cache-path=' + str(directory / 'modules'), str(source), '-o', str(air)], check=True)
        subprocess.run(['xcrun', '-sdk', 'macosx', 'metallib', str(air), '-o', str(library)], check=True)
        for kernel in ('math_control', 'math_float', 'math_derived'):
            ran = subprocess.run([str(runner), mode, str(library), kernel], env={**os.environ, 'MTL_DEBUG_LAYER': '1'}, capture_output=True, text=True)
            if ran.returncode not in (0, 1):
                raise RuntimeError(f'owned GPU runner failed: {ran.returncode}: {ran.stderr}')
            result = json.loads(ran.stdout)
            result['compile_command'] = command
            result['production_compile_record'] = record
            result['validation_stderr'] = ran.stderr
            results.append(result)
            print(json.dumps({k: result[k] for k in ('mode', 'kernel', 'checks', 'failures', 'zero_sign_failures', 'finite_nondegenerate_checks', 'finite_numeric_failures', 'failures_by_operation')}), flush=True)
    (directory / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    # The flag fix qualifies arithmetic/NaN/Inf behavior. Strict signed-zero tie
    # deviations are reported separately and retained in the raw oracle result;
    # they occur equally in every mode and are not claimed fixed here.
    for result in results:
        if result['mode'] in ('current', 'relaxed'):
            assert result['failures'] == result['zero_sign_failures'], result
            assert not result['finite_numeric_failures'], result
    return results


if __name__ == '__main__':
    if '--fixture-dir' in sys.argv:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument('--fixture-dir', required=True, type=Path)
        run(parser.parse_args().fixture_dir)
    else:
        unittest.main()
