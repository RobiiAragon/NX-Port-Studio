"""Private peer preparation from synthetic approvals; no enrollment or network."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import ssl
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'dm/tools'))
spec = importlib.util.spec_from_file_location('nextendo_local_peers', REPO / 'dm/tools/nextendo_local_peers.py')
assert spec is not None and spec.loader is not None
n = importlib.util.module_from_spec(spec); spec.loader.exec_module(n)
TITLE = '0100f8f0000a2000'
HOST = 'g2df33d01-lp1.s.n.srv.nintendo.net'


class LocalPeerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            def run(arguments):
                return subprocess.run(['openssl', *arguments], cwd=root, check=True, capture_output=True).stdout
            run(['req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256', '-nodes',
                 '-keyout', 'key.pem', '-out', 'cert.pem', '-days', '1', '-subj', '/CN=synthetic.invalid'])
            cls.der = run(['x509', '-in', 'cert.pem', '-outform', 'DER'])
            run(['req', '-new', '-x509', '-key', 'key.pem', '-out', 'other.pem', '-days', '1', '-set_serial', '2', '-subj', '/CN=synthetic.invalid'])
            cls.other_der = run(['x509', '-in', 'other.pem', '-outform', 'DER'])

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.digest = hashlib.sha256(self.der).hexdigest()
        self.ca = b'original synthetic CA; parser is only used for approved peers'
        self.contract = n.nextendo_services.contract(REPO)
        self.contract['provider']['caSHA256'] = hashlib.sha256(self.ca).hexdigest()
        self.contract_patch = patch.object(n.nextendo_services, 'contract', return_value=self.contract)
        self.contract_patch.start(); self.addCleanup(self.contract_patch.stop)
        self.no_network = patch('urllib.request.urlopen', side_effect=AssertionError('No network allowed'))
        self.no_network.start(); self.addCleanup(self.no_network.stop)
        self.public = n.nextendo_services.prepare(REPO, TITLE, self.root / 'public', ca=self.ca)
        self.original = {p.name:p.read_bytes() for p in self.public.iterdir()}
        self.destination = self.root / 'private'
        self.count = 0

    def _entry(self, host=HOST, title=TITLE):
        return {'role':'approved-service-leaf', 'file':self.digest + '.der',
                'bindings':[{'titleID':title.upper(), 'host':host, 'ip':'192.0.2.99'}],
                'approval':'Explicit synthetic test approval'}

    def _collection(self, entries=None):
        self.count += 1; directory = self.root / f'collection-{self.count}'; directory.mkdir(mode=0o700)
        value = {'formatVersion':1, 'certificates':entries if entries is not None else {self.digest:self._entry()}}
        self._index(directory, value)
        (directory / (self.digest + '.der')).write_bytes(self.der)
        (directory / (self.digest + '.der')).chmod(0o600)
        return directory

    @staticmethod
    def _index(directory, value):
        path = directory / 'index.json'; path.write_text(json.dumps(value)); path.chmod(0o600)

    def _prepare(self, collection, **kwargs):
        return n.prepare(REPO, kwargs.get('title', TITLE), kwargs.get('public', self.public), collection, self.destination)

    def _unchanged(self):
        self.assertEqual(self.original, {p.name:p.read_bytes() for p in self.public.iterdir()})
        self.assertFalse(self.destination.exists())
        self.assertFalse(list(self.root.glob('.nextendo-peers-*')))

    def test_absent_or_unrelated_collection_is_noop(self):
        for collection in (None, self.root/'absent', self._collection({}), self._collection({self.digest:self._entry(title='0100152000022000')})):
            with self.subTest(collection=collection):
                self.assertIsNone(self._prepare(collection)); self._unchanged()

    def test_private_pair_preserves_base_ca_identity_and_hashes(self):
        collection = self._collection(); self.assertEqual(self._prepare(collection), self.destination)
        routes = (self.destination/'routes.tsv').read_bytes()
        self.assertTrue(routes.startswith(self.original['routes.tsv']))
        address = self.contract['provider']['server']
        self.assertNotIn(b'192.0.2.99', routes)
        rows = [r.split('\t') for r in routes.decode().splitlines()[1:]]
        self.assertEqual(rows[-2], ['pinned-exact', HOST, address, HOST, self.digest+'.der', self.digest])
        self.assertEqual(rows[-1], ['pinned-address', address, address, HOST, self.digest+'.der', self.digest])
        manifest = json.loads((self.destination/'manifest.json').read_text())
        public = json.loads(self.original['manifest.json'])
        self.assertEqual(manifest['identity'], public['identity'])
        self.assertEqual(manifest['publicProfile']['files'], public['files'])
        self.assertEqual(manifest['publicProfile']['manifestSHA256'], hashlib.sha256(self.original['manifest.json']).hexdigest())
        self.assertEqual(manifest['routeCount'], len(rows))
        self.assertEqual((self.destination/'provider-ca.der').read_bytes(), self.ca)
        for name, digest in manifest['files'].items(): self.assertEqual(hashlib.sha256((self.destination/name).read_bytes()).hexdigest(), digest)
        self.assertEqual(stat.S_IMODE(self.destination.stat().st_mode), 0o700)
        for path in self.destination.iterdir(): self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(self.original, {p.name:p.read_bytes() for p in self.public.iterdir()})
        with self.assertRaises(ValueError): n.nextendo_services.stage(self.destination, self.root/'not-public', TITLE)
        with self.assertRaises(ValueError): self._prepare(collection, public=self.destination)

    def test_unapproved_ca_role_is_ignored_without_reading_certificate(self):
        entry = {'role':'published-provider-ca', 'file':'../../not-read', 'bindings':[{'titleID':TITLE,'host':HOST}]}
        collection = self._collection({self.digest:entry})
        (collection/(self.digest+'.der')).unlink()
        self.assertIsNone(self._prepare(collection)); self._unchanged()

    def test_matching_scores_follow_c_priority_and_label_boundaries(self):
        rows = [['suffix','nintendo.net','1.2.3.4','@host','c','h'],
                ['label','g2*-lp1.s.n.srv.nintendo.net','2.3.4.5','@host','c','h'],
                ['suffix','s.n.srv.nintendo.net','3.4.5.6','@host','c','h']]
        self.assertEqual(n._effective(rows, HOST), '2.3.4.5')
        self.assertEqual(n._effective(rows, 'other.s.n.srv.nintendo.net'), '3.4.5.6')
        self.assertEqual(n._score('exact',HOST,HOST),100000+len(HOST))
        self.assertEqual(n._score('label','g*.nintendo.net','g.a.nintendo.net'),0)
        self.assertEqual(n._score('suffix','nintendo.net','notnintendo.net'),0)
        self.assertEqual(n._score('label','g*.nintendo.net','g.nintendo.net'),10000+len('g*.nintendo.net'))
        rows.insert(0, ['label','g2*-lp1.s.n.srv.nintendo.net','4.5.6.7','@host','c','h'])
        self.assertEqual(n._effective(rows,HOST),'4.5.6.7')  # equal score keeps the first row
        rows.append(['exact',HOST,'5.6.7.8','@host','c','h'])
        self.assertEqual(n._effective(rows,HOST),'5.6.7.8')
        rows[-1][3]='another.nintendo.net'
        with self.assertRaisesRegex(ValueError,'TLS identity'): n._effective(rows,HOST)

    def test_label_route_derives_address_but_non_tls_and_unknown_are_rejected(self):
        self.contract['base'].insert(0, {'match':'label','host':'service-*.nintendo.net','server':'nat','tls':True})
        public = n.nextendo_services.prepare(REPO,TITLE,self.root/'label-public',ca=self.ca)
        self._prepare(self._collection({self.digest:self._entry(host='service-test.nintendo.net')}),public=public)
        self.assertIn(('pinned-address\t'+self.contract['provider']['nat']).encode(),(self.destination/'routes.tsv').read_bytes())
        for host in ('unconfigured.invalid','nncs2-lp1.n.n.srv.nintendo.net'):
            with self.subTest(host=host):
                self.destination = self.root/('failed-'+host)
                with self.assertRaises(ValueError): self._prepare(self._collection({self.digest:self._entry(host=host)}))
                self.assertFalse(self.destination.exists())

    def test_same_ip_multiple_services_or_pins_fail_closed(self):
        scenarios = []
        entry = self._entry(); entry['bindings'].append({'titleID':TITLE,'host':'another.nintendo.net','ip':'1.2.3.4'})
        scenarios.append({self.digest:entry})
        other = hashlib.sha256(self.other_der).hexdigest(); second = self._entry(); second['file'] = other+'.der'
        scenarios.append({self.digest:self._entry(),other:second})
        for entries in scenarios:
            collection = self._collection(entries)
            (collection/(other+'.der')).write_bytes(self.other_der); (collection/(other+'.der')).chmod(0o600)
            with self.assertRaisesRegex(ValueError,'Ambiguous'): self._prepare(collection)
            self._unchanged()

    def test_duplicate_identical_binding_deduplicates(self):
        entry = self._entry(); entry['bindings'].append(dict(entry['bindings'][0],ip='198.51.100.12'))
        self._prepare(self._collection({self.digest:entry}))
        rows = (self.destination/'routes.tsv').read_text().splitlines()
        self.assertEqual(sum(r.startswith('pinned-') for r in rows),2)

    def test_invalid_collection_metadata_never_creates_destination(self):
        changes = [lambda v:v.update(formatVersion=2), lambda v:v.update(formatVersion=True),
                   lambda v:v['certificates'][self.digest].update(approval=' '),
                   lambda v:v['certificates'][self.digest].update(approval='bad\npermission'),
                   lambda v:v['certificates'][self.digest].update(file='../'+self.digest+'.der'),
                   lambda v:v['certificates'][self.digest]['bindings'][0].update(titleID='*'),
                   lambda v:v['certificates'][self.digest]['bindings'][0].update(host='*.nintendo.net'),
                   lambda v:v['certificates'][self.digest]['bindings'][0].update(host='1.2.3.4'),
                   lambda v:v['certificates'][self.digest]['bindings'][0].update(host='../nintendo.net'),
                   lambda v:v['certificates'][self.digest]['bindings'][0].update(ip='not-an-ip'),
                   lambda v:v['certificates'][self.digest]['bindings'][0].update(ip=123)]
        for change in changes:
            value = {'formatVersion':1,'certificates':{self.digest:self._entry()}}; change(value)
            collection = self._collection(); self._index(collection,value)
            with self.subTest(value=value), self.assertRaises((ValueError,OSError)): self._prepare(collection)
            self._unchanged()

    def test_corruption_der_hash_and_bounds_fail_closed(self):
        for payload in (b'not json',b'{"formatVersion":1,"formatVersion":1}',b'x'*(n.INDEX_MAX+1)):
            collection=self._collection();(collection/'index.json').write_bytes(payload)
            with self.assertRaises(ValueError):self._prepare(collection)
            self._unchanged()
        for data in (b'corrupt',b'x'*(n.CERT_MAX+1)):
            collection=self._collection();(collection/(self.digest+'.der')).write_bytes(data)
            with self.assertRaises(ValueError):self._prepare(collection)
            self._unchanged()
        invalid=b'\x30\x03\x01\x01\x00';digest=hashlib.sha256(invalid).hexdigest();entry=self._entry();entry['file']=digest+'.der'
        collection=self._collection({digest:entry});(collection/(digest+'.der')).write_bytes(invalid);(collection/(digest+'.der')).chmod(0o600)
        with self.assertRaisesRegex(ValueError,'parsed'):self._prepare(collection)
        self._unchanged()
        with self.assertRaises(ValueError):n._certificate(self.der+b'junk')
        entries={f'{i:064x}':{'role':'published-provider-ca'} for i in range(257)}
        with self.assertRaises(ValueError):self._prepare(self._collection(entries))
        entry=self._entry();entry['bindings']*=1025
        with self.assertRaises(ValueError):self._prepare(self._collection({self.digest:entry}))
        collection=self._collection();(collection/'index.json').unlink()
        with self.assertRaises(FileNotFoundError):self._prepare(collection)
        self._unchanged()

    def test_permissions_ownership_and_symlinks_fail_closed(self):
        for target in ('directory','index','certificate'):
            collection=self._collection();path=collection if target=='directory' else collection/('index.json' if target=='index' else self.digest+'.der')
            path.chmod(0o777 if target=='directory' else 0o666)
            with self.subTest(target=target), self.assertRaises(ValueError):self._prepare(collection)
            self._unchanged()
        collection=self._collection()
        with patch.object(n.os,'geteuid',return_value=os.geteuid()+1000),self.assertRaises(ValueError):self._prepare(collection)
        for target in ('directory','index','certificate','ancestor'):
            collection=self._collection()
            if target=='ancestor':
                link=self.root/('parent-'+str(self.count));link.symlink_to(self.root,target_is_directory=True);collection=link/collection.name
            else:
                path=collection if target=='directory' else collection/('index.json' if target=='index' else self.digest+'.der')
                moved=path.with_name(path.name+'.real');path.rename(moved);path.symlink_to(moved,target_is_directory=target=='directory')
            with self.subTest(target=target),self.assertRaises(OSError):self._prepare(collection)
            self._unchanged()

    def test_public_tampering_and_existing_destination_are_unchanged(self):
        collection=self._collection();self.destination.mkdir();(self.destination/'keep').write_text('untouched')
        with self.assertRaises(FileExistsError):self._prepare(collection)
        self.assertEqual((self.destination/'keep').read_text(),'untouched')
        (self.destination/'keep').unlink();self.destination.rmdir()
        routes=self.public/'routes.tsv';routes.write_bytes(self.original['routes.tsv']+b'exact\tevil.invalid\t1.2.3.4\t-\t-\t-\n')
        value=json.loads(self.original['manifest.json']);value['files']['routes.tsv']=hashlib.sha256(routes.read_bytes()).hexdigest()
        (self.public/'manifest.json').write_text(json.dumps(value))
        with self.assertRaisesRegex(ValueError,'public service contract'):self._prepare(collection)
        self.assertFalse(self.destination.exists())

    def test_exact_public_promotion_and_unknown_manifest_metadata(self):
        collection=self._collection()
        for field,value in (('unexpected','not copied'),('protocol','unknown'),('routeCount',True)):
            manifest=json.loads(self.original['manifest.json']);manifest[field]=value
            (self.public/'manifest.json').write_text(json.dumps(manifest))
            with self.subTest(field=field),self.assertRaises(ValueError):self._prepare(collection)
            self.assertFalse(self.destination.exists())
        (self.public/'manifest.json').write_bytes(self.original['manifest.json'])
        self.contract['base'].append({'match':'exact','host':HOST,'server':'server','tls':True})
        public=n.nextendo_services.prepare(REPO,TITLE,self.root/'exact-public',ca=self.ca)
        original={p.name:p.read_bytes() for p in public.iterdir()}
        self._prepare(collection,public=public)
        rows=[r.split('\t') for r in (self.destination/'routes.tsv').read_text().splitlines()[1:]]
        self.assertEqual(sum(r[1]==HOST for r in rows),1)
        row=next(r for r in rows if r[1]==HOST)
        self.assertEqual(row,['pinned-exact',HOST,self.contract['provider']['server'],HOST,self.digest+'.der',self.digest])
        expected=[r.split('\t') for r in original['routes.tsv'].decode().splitlines()[1:] if r.split('\t')[1]!=HOST]
        self.assertEqual(rows[:-1],[row if r[0]=='exact' and r[1]==HOST else r for r in [r.split('\t') for r in original['routes.tsv'].decode().splitlines()[1:]]])
        self.assertEqual([r for r in rows if r[0] not in ('pinned-exact','pinned-address')],expected)
        manifest=json.loads((self.destination/'manifest.json').read_text())
        self.assertEqual(manifest['localPeers']['promotedExactHosts'],[HOST])
        self.assertEqual(manifest['publicProfile']['files'],json.loads(original['manifest.json'])['files'])
        self.assertEqual(original,{p.name:p.read_bytes() for p in public.iterdir()})
        with self.assertRaises(ValueError):n.nextendo_services.stage(self.destination,self.root/'still-not-public',TITLE)

    def test_expired_and_future_certificates_are_not_prepared(self):
        result=subprocess.run(['openssl','x509','-inform','DER','-noout','-dates'],input=self.der,check=True,capture_output=True)
        dates=dict(line.split('=',1) for line in result.stdout.decode().splitlines())
        for timestamp in (ssl.cert_time_to_seconds(dates['notBefore'])-1,ssl.cert_time_to_seconds(dates['notAfter'])+1):
            with self.subTest(timestamp=timestamp),patch.object(n.time,'time',return_value=timestamp):
                with self.assertRaisesRegex(ValueError,'not currently valid'):self._prepare(self._collection())
                self._unchanged()

    @unittest.skipUnless(sys.platform=='darwin','Production route parser uses Apple Security; Python fixtures remain portable')
    def test_generated_pair_is_accepted_by_the_production_c_loader(self):
        self.contract['provider']['caSHA256']=self.digest
        public=n.nextendo_services.prepare(REPO,TITLE,self.root/'der-public',ca=self.der)
        binary=self.root/'route-loader'
        subprocess.run(['clang','-std=c11','-Wall','-Wextra','-Werror','-Wno-deprecated-declarations','-framework','Security','-framework','CoreFoundation',
                        str(REPO/'dm/host/tests/t_nextendo_local_peers.c'),str(REPO/'dm/host/hle_nextendo_routes.c'),'-o',str(binary)],check=True,capture_output=True)
        for exact in (False,True):
            if exact:
                self.contract['base'].append({'match':'exact','host':HOST,'server':'server','tls':True})
                public=n.nextendo_services.prepare(REPO,TITLE,self.root/'der-public-exact',ca=self.der)
            self.destination=self.root/('loader-private-'+str(exact))
            self._prepare(self._collection(),public=public)
            result=subprocess.run([str(binary),str(self.destination/'routes.tsv'),HOST,self.contract['provider']['server']],check=True,capture_output=True,text=True)
            self.assertIn('production loader accepted',result.stdout)

    def test_exclusive_publication_race_keeps_existing_destination(self):
        real=n._publish
        def race(parent,temporary,name):
            os.mkdir(name,mode=0o700,dir_fd=parent)
            return real(parent,temporary,name)
        with patch.object(n,'_publish',side_effect=race),self.assertRaises(FileExistsError):self._prepare(self._collection())
        self.assertEqual(list(self.destination.iterdir()),[])
        self.assertFalse(list(self.root.glob('.nextendo-peers-*')))

    def test_temporary_name_collision_does_not_remove_an_existing_directory(self):
        existing=self.root/('.nextendo-peers-'+'f'*24);existing.mkdir()
        with patch.object(n.secrets,'token_hex',return_value='f'*24),self.assertRaises(FileExistsError):self._prepare(self._collection())
        self.assertTrue(existing.is_dir());self.assertFalse(self.destination.exists())


if __name__ == '__main__': unittest.main()
