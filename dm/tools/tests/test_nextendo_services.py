"""Public profile generation and closed staging, without user account state."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

REPO=Path(__file__).resolve().parents[3]
spec=importlib.util.spec_from_file_location('nextendo_services',REPO/'dm/tools/nextendo_services.py')
assert spec is not None and spec.loader is not None
n=importlib.util.module_from_spec(spec); spec.loader.exec_module(n)

class NextendoServicesTests(unittest.TestCase):
    def test_shared_families_and_title_scoped_services(self):
        value=n.contract(REPO)
        self.assertIn('suffix\tdemonware.net\t',n.rules(value,'01001b300b9be000'))
        self.assertIn('public-ubiservices.ubi.com',n.rules(value,'0100ea6014bb8000'))
        self.assertIn('api.epicgames.dev',n.rules(value,'0100ab401f136000'))
        self.assertNotIn('api.epicgames.dev',n.rules(value,'0100152000022000'))
        self.assertIn('label\tnncs2-*.',n.rules(value,'0100152000022000'))
        for title in ('0'*16,'bad','../0000000000000'):
            with self.assertRaises(ValueError): n.rules(value,title)
    def test_complete_public_profile_staging_rejects_tampering_and_symlinks(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder); ca=b'original synthetic public CA bytes'; value=n.contract(REPO)
            value['provider']['caSHA256']=hashlib.sha256(ca).hexdigest()
            with patch.object(n,'contract',return_value=value):
                source=n.prepare(REPO,'0100152000022000',root/'profile',ca=ca)
                n.stage(source,root/'staged','0100152000022000')
                self.assertEqual({p.name for p in (root/'staged').iterdir()},{'routes.tsv','provider-ca.der','manifest.json'})
                with self.assertRaises(ValueError): n.stage(source,root/'bad','0100000000001000')
                manifest=source/'manifest.json'; data=json.loads(manifest.read_text())
                (source/'routes.tsv').write_text('NXNEXTENDO_ROUTES_2\nexact\tevil.invalid\t1.2.3.4\t-\t-\t-\n')
                data['files']['routes.tsv']=hashlib.sha256((source/'routes.tsv').read_bytes()).hexdigest(); manifest.write_text(json.dumps(data))
                with self.assertRaises(ValueError): n.stage(source,root/'bad','0100152000022000')
                (source/'provider-ca.der').unlink(); (source/'provider-ca.der').symlink_to(root/'staged/provider-ca.der')
                with self.assertRaises(ValueError): n.stage(source,root/'bad','0100152000022000')

if __name__=='__main__':unittest.main()
