"""Exercise the real iOS staging command with original synthetic approvals."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
TITLE = '0100152000022000'
HOST = 'g2b309e01-lp1.s.n.srv.nintendo.net'


class IOSPeerProfiles(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'ec', '-pkeyopt',
                            'ec_paramgen_curve:P-256', '-nodes', '-keyout', str(root/'key'),
                            '-out', str(root/'cert'), '-days', '1', '-subj', '/CN=synthetic.invalid'],
                           check=True, capture_output=True)
            cls.der = subprocess.check_output(['openssl', 'x509', '-in', str(root/'cert'), '-outform', 'DER'])

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.engine = self.root/'engine'
        tools = self.engine/'dm/tools'; tools.mkdir(parents=True)
        for name in ('nextendo_services.py', 'nextendo_local_peers.py'):
            shutil.copyfile(REPO/'dm/tools'/name, tools/name)
        ios_tools = self.engine/'dm/ios/tools'; ios_tools.mkdir(parents=True)
        helper = REPO/'dm/ios/tools/nextendo_profiles.py'
        if helper.exists(): shutil.copyfile(helper, ios_tools/helper.name)
        self.ca = b'original synthetic public CA bytes'
        self.contract = json.loads((REPO/'dm/net/nextendo-services.json').read_text())
        self.contract['provider']['caSHA256'] = hashlib.sha256(self.ca).hexdigest()
        contract_path = self.engine/'dm/net/nextendo-services.json'
        contract_path.parent.mkdir(); contract_path.write_text(json.dumps(self.contract))
        self.source = self.root/'public'; self.source.mkdir()
        # Prepare with the copied public exporter and its own synthetic contract.
        code = ('import sys;from pathlib import Path;sys.path.insert(0,sys.argv[1]);'
                'import nextendo_services as n;n.prepare(sys.argv[2],sys.argv[3],sys.argv[4],ca=bytes.fromhex(sys.argv[5]))')
        subprocess.run(['python3', '-c', code, str(tools), str(self.engine), TITLE,
                        str(self.source), self.ca.hex()], check=True, capture_output=True)
        self.public_bytes = {p.name:p.read_bytes() for p in self.source.iterdir()}
        self.collection = self.root/'approvals'; self.collection.mkdir(mode=0o700)
        self.sha = hashlib.sha256(self.der).hexdigest()
        (self.collection/(self.sha+'.der')).write_bytes(self.der)
        (self.collection/(self.sha+'.der')).chmod(0o600)
        self.binding = {'titleID':TITLE, 'host':HOST, 'ip':'192.0.2.99'}
        self.write_index()
        self.output = self.root/'project'; (self.output/'Gen/dm').mkdir(parents=True)

    def write_index(self):
        value = {'formatVersion':1, 'certificates':{self.sha:{
            'role':'approved-service-leaf', 'file':self.sha+'.der',
            'approval':'Explicit original synthetic fixture approval', 'bindings':[self.binding]}}}
        index = self.collection/'index.json'; index.write_text(json.dumps(value)); index.chmod(0o600)

    def stage(self, success=True, source=None, collection=None):
        script = (REPO/'dm/ios/tools/build_ipa.sh').read_text()
        begin = script.index('if [ -n "${DM_NEXTENDO_SERVICES_DIR:-}" ]; then')
        end = script.index('\nfi', begin) + len('\nfi')
        environment = {k:v for k,v in os.environ.items() if not k.startswith('DM_')}
        environment.update(DM=str(self.engine/'dm'), IOS_SOURCE=str(self.engine/'dm/ios'), GAME=TITLE,
                           DM_NEXTENDO_SERVICES_DIR=str(source or self.source),
                           DM_NEXTENDO_PEER_COLLECTION=str(collection or self.collection))
        result = subprocess.run(['bash', '-c', 'set -eu\ndie() { exit 1; }\n'+script[begin:end]],
                                cwd=self.output, env=environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0 if success else 1, result.stdout+result.stderr)
        self.assertEqual({p.name:p.read_bytes() for p in self.source.iterdir()}, self.public_bytes)
        return self.output/'Gen/dm'

    def test_approved_pair_uses_current_public_address_and_preserves_public_bytes(self):
        dm = self.stage()
        self.assertEqual({p.name:p.read_bytes() for p in (dm/'nextendo').iterdir()}, self.public_bytes)
        private = dm/'nextendo-private'
        self.assertEqual((private/(self.sha+'.der')).read_bytes(), self.der)
        rows = [line.split('\t') for line in (private/'routes.tsv').read_text().splitlines()[1:]]
        address = self.contract['provider']['nat']
        self.assertIn(['pinned-exact',HOST,address,HOST,self.sha+'.der',self.sha], rows)
        self.assertIn(['pinned-address',address,address,HOST,self.sha+'.der',self.sha], rows)
        self.assertNotIn('192.0.2.99', (private/'routes.tsv').read_text())
        manifest = json.loads((private/'manifest.json').read_text())
        self.assertEqual(manifest['titleID'], TITLE)
        self.assertEqual(manifest['localPeers']['bindings'][0]['host'], HOST)
        for name, sha in manifest['files'].items():
            self.assertEqual(hashlib.sha256((private/name).read_bytes()).hexdigest(), sha)

    def test_absent_collection_preserves_public_export_only(self):
        dm = self.stage(collection=self.root/'absent')
        self.assertFalse((dm/'nextendo-private').exists())
        self.assertEqual({p.name:p.read_bytes() for p in (dm/'nextendo').iterdir()}, self.public_bytes)

    def test_other_title_does_not_export_approval(self):
        self.binding['titleID'] = '01006a800016e000'; self.write_index()
        dm = self.stage(); self.assertFalse((dm/'nextendo-private').exists())

    def test_malformed_collection_fails_before_staging_either_profile(self):
        (self.collection/'index.json').write_text('not JSON')
        dm = self.stage(success=False)
        self.assertFalse((dm/'nextendo').exists()); self.assertFalse((dm/'nextendo-private').exists())

    def test_malformed_public_profile_is_not_repaired_or_exported(self):
        (self.source/'routes.tsv').write_bytes(b'not a public profile')
        self.public_bytes = {p.name:p.read_bytes() for p in self.source.iterdir()}
        dm = self.stage(success=False)
        self.assertFalse((dm/'nextendo').exists()); self.assertFalse((dm/'nextendo-private').exists())

    def test_private_result_is_not_accepted_by_the_public_exporter(self):
        dm = self.stage(); private = dm/'nextendo-private'
        other = self.root/'public-reexport'
        code = ('import sys;sys.path.insert(0,sys.argv[1]);import nextendo_services as n;'
                'n.stage(sys.argv[2],sys.argv[3],sys.argv[4])')
        result = subprocess.run(['python3', '-c', code, str(self.engine/'dm/tools'), str(private), str(other), TITLE], capture_output=True)
        self.assertNotEqual(result.returncode, 0); self.assertFalse(other.exists())

    def test_existing_private_output_is_never_reused_or_replaced(self):
        private = self.output/'Gen/dm/nextendo-private'; private.mkdir(); (private/'keep').write_bytes(b'keep')
        dm = self.stage(success=False)
        self.assertEqual((private/'keep').read_bytes(), b'keep'); self.assertFalse((dm/'nextendo').exists())
