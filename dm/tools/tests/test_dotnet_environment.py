"""A native apphost must use the same runtime as the Homebrew dotnet CLI."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

REPO=Path(__file__).resolve().parents[3]
spec=importlib.util.spec_from_file_location('build_ipa_from_nsp',REPO/'scripts/build_ipa_from_nsp.py')
assert spec is not None and spec.loader is not None
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

class DotnetEnvironmentTests(unittest.TestCase):
    def test_homebrew_runtime_discovery_including_spaces(self):
        with tempfile.TemporaryDirectory(prefix='runtime with spaces ') as folder:
            root=Path(folder);binary=root/'dotnet';binary.write_text('synthetic executable');binary.chmod(0o700)
            output=f'Microsoft.AspNetCore.App 10.0.13 [{root}/shared/Microsoft.AspNetCore.App]\nMicrosoft.NETCore.App 10.0.13 [{root}/shared/Microsoft.NETCore.App]\n'
            env={'PATH':'/synthetic/bin'}
            with patch.object(module.shutil,'which',return_value='/synthetic/bin/dotnet'),patch.object(module.subprocess,'run',return_value=subprocess.CompletedProcess([],0,output,'')):
                module.configure_dotnet_environment(env)
            self.assertEqual(env['DOTNET_ROOT'],str(root));self.assertEqual(env['DOTNET_ROOT_ARM64'],str(root))
    def test_explicit_roots_are_retained(self):
        for name in ('DOTNET_ROOT','DOTNET_ROOT_ARM64'):
            env={name:'/selected/runtime'}
            with patch.object(module.subprocess,'run') as run:module.configure_dotnet_environment(env)
            run.assert_not_called();self.assertEqual(env,{name:'/selected/runtime'})
    def test_missing_runtime_never_invents_a_root(self):
        for result in [subprocess.CompletedProcess([],0,'Microsoft.AspNetCore.App 10.0.13 [/unknown/shared/Microsoft.AspNetCore.App]\n',''),subprocess.TimeoutExpired('dotnet',10)]:
            env={'PATH':'/synthetic'}
            with patch.object(module.shutil,'which',return_value='/synthetic/dotnet'),patch.object(module.subprocess,'run') as run:
                if isinstance(result,Exception):run.side_effect=result
                else:run.return_value=result
                module.configure_dotnet_environment(env)
            self.assertNotIn('DOTNET_ROOT',env)
