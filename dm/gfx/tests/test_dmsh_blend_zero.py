"""NVIDIA's "zero times anything is zero" float blend option in a pixel shader (dmsh_build.py blend_zero): where the host's blend word says an output's source colour weight
is zero, a NaN or infinite rgb is returned as 0. The rewrite of main0, the shaders it leaves alone, and the compile on both platforms."""
import ast
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parents[1] / 'tools'
sys.path.insert(0, str(TOOLS))
import dmsh_abi as abi   # noqa: E402

tree = ast.parse((TOOLS / 'dmsh_build.py').read_text())
selected = [n for n in tree.body if (isinstance(n, ast.FunctionDef) and n.name == 'blend_zero')
            or (isinstance(n, ast.Assign) and any(getattr(t, 'id', None) == 'BLEND_ZERO' for t in n.targets))]
scope = {'re': re, 'abi': abi}
exec(compile(ast.Module(body=selected, type_ignores=[]), str(TOOLS / 'dmsh_build.py'), 'exec'), scope)
blend_zero = scope['blend_zero']

HEAD = '#include <metal_stdlib>\n#include <simd/simd.h>\n\nusing namespace metal;\n\n'
# A pixel shader as spirv-cross writes one: two float colour outputs and an early return
TWO = HEAD + '''struct main0_out
{
    float4 out_attr0 [[color(0)]];
    float4 out_attr1 [[color(1)]];
};

struct main0_in
{
    float4 in_attr0 [[user(locn0)]];
};

fragment main0_out main0(main0_in in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]])
{
    main0_out out = {};
    if (in.in_attr0.x < 0.0)
    {
        out.out_attr0 = float4(0.0);
        return out;
    }
    out.out_attr0 = t.sample(s, in.in_attr0.xy);
    out.out_attr1 = in.in_attr0;
    return out;
}
'''
# Only an integer output: nothing a float blender takes
UINT = HEAD + '''struct main0_out
{
    uint4 out_attr0 [[color(0)]];
};

fragment main0_out main0()
{
    main0_out out = {};
    out.out_attr0 = uint4(1u);
    return out;
}
'''
# A colour output at slot 3 and a main0 with no other parameter
LONE = HEAD + '''struct main0_out
{
    float4 out_attr3 [[color(3)]];
};

fragment main0_out main0()
{
    main0_out out = {};
    out.out_attr3 = float4(1.0);
    return out;
}
'''


class BlendZero(unittest.TestCase):
    def test_every_return_of_main0_gets_the_guard(self):
        out, done = blend_zero(TWO)
        self.assertTrue(done)
        self.assertEqual(out.count('dm_blend0(out, dm_blend);\n'), 2)
        for m in re.finditer(r'dm_blend0\(out, dm_blend\);\n([ \t]*)return out;', out):
            self.assertTrue(m.group(1), 'the guard keeps the return\'s indentation')
        self.assertIn(f'constant dm_blend_state& dm_blend [[buffer({abi.BLEND_BUFFER})]])', out)
        bits = abi.BLEND_ZERO_BITS
        self.assertIn('dm_o.out_attr0 = dm_bz(dm_o.out_attr0, m >> 0u);', out)
        self.assertIn(f'dm_o.out_attr1 = dm_bz(dm_o.out_attr1, m >> {bits}u);', out)
        self.assertIn(f'm &= {(1 << bits) - 1}u;', out)
        self.assertLess(out.index('struct dm_blend_state'), out.index('fragment main0_out main0('), 'the helpers come before main0')

    def test_slot_shift_and_a_main0_without_parameters(self):
        out, done = blend_zero(LONE)
        self.assertTrue(done)
        self.assertIn(f'dm_o.out_attr3 = dm_bz(dm_o.out_attr3, m >> {3 * abi.BLEND_ZERO_BITS}u);', out)
        self.assertIn(f'fragment main0_out main0(constant dm_blend_state& dm_blend [[buffer({abi.BLEND_BUFFER})]])', out)

    def test_shaders_left_alone(self):
        self.assertEqual(blend_zero(UINT), (UINT, False))
        taken = TWO.replace('sampler s [[sampler(0)]]', f'sampler s [[sampler(0)]], constant float4& x [[buffer({abi.BLEND_BUFFER})]]')
        self.assertEqual(blend_zero(taken), (taken, False), 'the buffer index is taken')
        other = TWO.replace('        return out;\n    }', '        return main0_out{};\n    }')
        self.assertEqual(blend_zero(other), (other, False), 'a return other than `return out;`')
        once, _ = blend_zero(TWO)
        self.assertEqual(blend_zero(once), (once, False), 'a shader already rewritten')

    @unittest.skipUnless(shutil.which('xcrun'), 'requires Metal compilers')
    def test_compiles(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, src in (('two', TWO), ('lone', LONE)):
                msl = root / (name + '.metal'); msl.write_text(blend_zero(src)[0])
                for sdk in ('macosx', 'iphoneos'):
                    with self.subTest(shader=name, sdk=sdk):
                        r = subprocess.run(['xcrun', '-sdk', sdk, 'metal', '-c', '-fmodules-cache-path=' + str(root / sdk), str(msl), '-o', str(root / f'{name}_{sdk}.air')],
                                           capture_output=True, text=True)
                        self.assertEqual(r.returncode, 0, r.stderr)


if __name__ == '__main__':
    unittest.main()
