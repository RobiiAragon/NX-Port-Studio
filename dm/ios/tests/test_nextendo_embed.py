"""Separate online/offline code must remain ordinary signed iPhone text pages."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO=Path(__file__).resolve().parents[3]

@unittest.skipUnless(sys.platform=='darwin' and shutil.which('xcrun'),'requires Apple assembler')
class NextendoEmbedTests(unittest.TestCase):
    def test_both_variants_assemble_for_iphone_without_jit_or_extra_executable_segment(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder); modules=root/'modules'; modules.mkdir(); (modules/'nextendo').mkdir()
            header='# TEXT_END 0x4000\n# PATCH_OFF 0xc000\n# KEY_PAGE_OFF 0x8000\n# KEY_PAGE_SIZE 0x4000\n'
            for target,word in [(modules,bytes.fromhex('c0035fd6')),(modules/'nextendo',bytes.fromhex('1f2003d5'))]:
                (target/'main.fixups.tsv').write_text(header)
                (target/'main.patched.bin').write_bytes(word*(0x10000//4))
            assembly=root/'embed.S'; result=subprocess.run([sys.executable,str(REPO/'dm/ios/tools/gen_embed.py'),str(modules),str(assembly),'main'],capture_output=True,text=True,check=True)
            text=assembly.read_text(); self.assertIn('__TEXT,__dmmainx0',text); self.assertIn('__TEXT,__dmnmainx0',text)
            self.assertIn('__DMnmainW,rw,rw',result.stdout)
            self.assertNotIn('rwx',result.stdout)
            obj=root/'embed.o'
            subprocess.run(['xcrun','--sdk','iphoneos','clang','-target','arm64-apple-ios26.0','-c',str(assembly),'-o',str(obj)],capture_output=True,check=True)
            sections=subprocess.check_output(['xcrun','otool','-l',str(obj)],text=True)
            self.assertIn('__dmnmainx0',sections); self.assertIn('__dmmainx0',sections)
            # Removing the online build leaves the original module generator path.
            shutil.rmtree(modules/'nextendo')
            subprocess.run([sys.executable,str(REPO/'dm/ios/tools/gen_embed.py'),str(modules),str(assembly),'main'],capture_output=True,check=True)
            self.assertNotIn('__dmnmainx0',assembly.read_text())
