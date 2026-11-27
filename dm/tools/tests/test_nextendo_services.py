"""Public profile generation and closed staging, without user account state."""
import copy
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
        self.assertIn('exact\tnpln.eevee.ink\t@dns\t-\t-\t-\n',n.rules(value,'0100c2500fc20000'))   # Splatoon 3 12.0.0's adapter names this host
        self.assertNotIn('npln.eevee.ink',n.rules(value,'0100152000022000'))
        for bad in ({'match':'suffix','host':'eevee.ink','server':'public-dns','tls':False},{'match':'exact','host':'npln.eevee.ink','server':'public-dns','tls':True}):
            other=json.loads(json.dumps(value)); other['titles']['0100c2500fc20000']=[bad]
            with self.assertRaises(ValueError): n.rules(other,'0100c2500fc20000')
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
    def test_secure_server_address_keeps_its_service_identity(self):
        value=n.contract(REPO); host='g2ee2e300-lp1.s.n.srv.nintendo.net'; address=value['provider']['server']; ca=['provider-ca.der',value['provider']['caSHA256']]
        routes=n.rules(value,'01006f8002326000')
        self.assertIn('\t'.join(['exact',host,address,'@host']+ca)+'\n',routes)   # the service by its name, verified by the provider CA
        self.assertIn('\t'.join(['address',address,address,host]+ca)+'\n',routes)   # the secure server by its address: same peer, SNI and CA
        self.assertNotIn('address\t',n.rules(value,'0100152000022000'))   # another game's profile carries no numeric alias
        for broken in ({'match':'suffix'},{'tls':False},{'secureAddress':'yes'}):
            changed=copy.deepcopy(value); rule=next(r for r in changed['titles']['01006f8002326000'] if r['host']==host); rule.update(broken)
            with self.assertRaises(ValueError): n.rules(changed,'01006f8002326000')
        twice=copy.deepcopy(value); twice['titles']['01006f8002326000'].append({'match':'exact','host':'other-lp1.s.n.srv.nintendo.net','server':'server','tls':True,'secureAddress':True})
        with self.assertRaises(ValueError): n.rules(twice,'01006f8002326000')   # two services cannot share one secure-server address

    def test_self_signed_endpoint_is_pinned_for_its_game_only(self):
        # Animal Crossing: New Horizons' island API serves a self-signed certificate, not one from the provider CA.
        value=n.contract(REPO); host='api.hac.lp1.acbaa.srv.nintendo.net'
        pin=next(r['pin'] for r in value['titles']['01006f8002326000'] if r['host']==host)
        routes=n.rules(value,'01006f8002326000')
        self.assertIn('\t'.join(['pinned-exact',host,value['provider']['server'],host,pin+'.der',pin])+'\n',routes)
        self.assertNotIn(host,n.rules(value,'0100152000022000'))
        self.assertEqual(hashlib.sha256(n.pin_files(value,routes)[pin+'.der']).hexdigest(),pin)
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder); ca=b'original synthetic public CA bytes'
            value['provider']['caSHA256']=hashlib.sha256(ca).hexdigest()
            with patch.object(n,'contract',return_value=value):
                source=n.prepare(REPO,'01006f8002326000',root/'profile',ca=ca)
                self.assertEqual({p.name for p in n.stage(source,root/'staged','01006f8002326000').iterdir()},
                                 {'routes.tsv','provider-ca.der','manifest.json',pin+'.der'})
                (source/(pin+'.der')).write_bytes(b'0'*809)
                with self.assertRaises(ValueError): n.stage(source,root/'bad','01006f8002326000')
                (source/(pin+'.der')).unlink()
                with self.assertRaises(ValueError): n.stage(source,root/'bad','01006f8002326000')
        for broken in ({'match':'suffix','tls':True},{'match':'exact','tls':False},{'pin':'0'*64}):
            other=json.loads(json.dumps(n.contract(REPO))); rule=other['titles']['01006f8002326000'][0]; rule.update(broken)
            with self.assertRaises(ValueError): n.rules(other,'01006f8002326000')
        tampered=json.loads((REPO/'dm/net/nextendo-services.json').read_text())
        tampered['certificates'][pin]=tampered['certificates'][pin][:-8]+'AAAAAAA='
        with tempfile.TemporaryDirectory() as folder:
            (Path(folder)/'dm/net').mkdir(parents=True); (Path(folder)/'dm/net/nextendo-services.json').write_text(json.dumps(tampered))
            with self.assertRaises(ValueError): n.contract(folder)

if __name__=='__main__':unittest.main()
