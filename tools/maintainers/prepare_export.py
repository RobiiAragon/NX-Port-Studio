#!/usr/bin/env python3
"""Plan an independent source export; copying requires an explicit frozen digest.

No git staging, commits, pushes, device access, or edits to the canonical source.
Reports are private preparation files and are never included in the export.
"""
from __future__ import annotations
import argparse
import collections
import hashlib
import html
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
from urllib.parse import unquote

TRANSLATOR = 'dm/gfx/tools/dmsh_xlate_bin/'
ART = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg', '.icns', '.ico', '.heic', '.avif', '.bmp', '.tif', '.tiff'}
GAME = {'.nsp', '.nsz', '.xci', '.xcz', '.nca', '.nso', '.nro', '.ipa', '.tik', '.cert', '.metallib', '.spv', '.bntx', '.bfres', '.bnsh', '.bnvib', '.bdf', '.bfttf', '.bnk', '.bcstm'}
PRIVATE_FORMATS = {'.keys','.key','.keyring','.p12','.pfx','.pem','.mobileprovision','.provisionprofile','.keystore','.jks'}
PRIVATE_NAMES = {'prod.keys','title.keys','dev.keys','keyset','credentials.json','catalog-cache.json','nextendo-account.json','nextendo-session.json','nextendo-token.json','account.json','auth.json','token.json','.netrc','.ds_store','.env'}
REVIEWED_REDACTOR_FIXTURE = '5b882f0db22ac31658a0d44093732d598f620959bd166c22d15e7bc6c9ece808'
GENERATED = {'.o', '.a', '.dylib', '.so', '.dll', '.pdb', '.pyc', '.dSYM', '.partial', '.log'}
MACH = {bytes.fromhex(x) for x in ['feedface','cefaedfe','feedfacf','cffaedfe','cafebabe','bebafeca','cafebabf','bfbafeca']}
DOCS = ['README.md','README.es.md','README.upstream.md','CREDITS.md','ROADMAP.md','CONTRIBUTING.md','AGENTS.md','LICENSE','public-assets.json','.github/workflows/ci.yml']
HOME = re.compile(rb'/(?:Users|home)/([A-Za-z0-9_.-]+)/')
GENERIC_USERS = {b'runner', b'runneradmin', b'test', b'user', b'username', b'example', b'you', b'name'}
SCANS = {
    'console_key_material': re.compile(rb'\b(?:header_key|master_key_[0-9a-f]{2}|titlekek_[0-9a-f]{2}|key_area_key_(?:application|ocean|system)_[0-9a-f]{2})\s*=\s*([0-9a-fA-F]{32,})'),
    'private_key_material': re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----'),
    'nextendo_client_id': re.compile(rb'\bnxc_[A-Za-z0-9_-]{8,}\b'),
    'nex_credential': re.compile(rb'\bnx2\.[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{40,}\b'),
    'github_token': re.compile(rb'\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,})\b'),
    'nintendo_copyright_notice': re.compile(rb'\bCopyright\s*(?:\([cC]\)|\xc2\xa9)?\s*\d{4}(?:-\d{4})?[^\r\n]{0,100}\bNintendo\b', re.I),
    'apple_device_id': re.compile(rb'\b0000[0-9A-Fa-f]{4}-[0-9A-Fa-f]{16}\b'),
}

def git(root, *args):
    return subprocess.check_output(['git', *args], cwd=root)

def digest(data):
    return hashlib.sha256(data).hexdigest()

def binary_kind(data):
    if data[:4] in MACH: return 'Mach-O'
    if data[:4] == b'\x7fELF': return 'ELF'
    if data[:2] == b'MZ': return 'PE'
    return None

def filtered(rel, tracked):
    p = PurePosixPath(rel); parts = p.parts; lower = {x.lower() for x in parts}
    if any(x in {'.git','.build','.swiftpm','__pycache__','node_modules','obj','cmakefiles'} or x.endswith('_build') for x in lower): return 'generated directory'
    if parts[0] in {'work','outputs','dist','build','.github','.vscode','.idea'}: return 'local/generated configuration'
    if rel in DOCS or rel == 'README.md': return 'presentation override'
    if rel.startswith('dm/host/gen/') or rel.startswith('dm/ios/Gen/') or '.app' in ''.join(parts[:-1]): return 'generated product'
    if lower & {'romfs','exefs','firmware','extracted','system_data','save','saves'}: return 'game/firmware/user data directory'
    if p.suffix.lower() in ART: return 'inherited artwork denied by default'
    if p.suffix.lower() in GAME: return 'game/firmware/compiled shader format'
    if p.suffix.lower() in PRIVATE_FORMATS or p.name.lower() in PRIVATE_NAMES or p.name.lower().startswith('.env.') and p.name.lower() != '.env.example': return 'private credential/signing file'
    if p.name.lower().startswith(('nextendo-account','nextendo-session','nextendo-token','oauth-session')) and p.suffix.lower()=='.json': return 'private account session file'
    if p.suffix.lower() == '.pdb': return 'optional debug symbols; private build paths excluded'
    if rel.startswith(TRANSLATOR) and rel in tracked: return None
    if p.suffix in GENERATED or p.suffix.lower() in {x.lower() for x in GENERATED}: return 'compiled/generated artifact'
    return None

def scan(rel, data):
    hits=[]
    for category, pattern in SCANS.items():
        for m in pattern.finditer(data):
            if category == 'console_key_material' and rel == 'macOS/NXPortStudio/Tests/PortCoreTests/BuildCoreTests.swift' and digest(m.group(0)) == REVIEWED_REDACTOR_FIXTURE:
                # Root-reviewed synthetic literal, pinned by exact bytes, not
                # a blanket exception for the test file or function.
                continue
            hits.append({'path':rel,'line':data.count(b'\n',0,m.start())+1,'category':category})
    for m in HOME.finditer(data):
        if m.group(1).lower() not in GENERIC_USERS:
            hits.append({'path':rel,'line':data.count(b'\n',0,m.start())+1,'category':'personal_home_path'})
    # Opaque OAuth sessions may have no recognizable token prefix. Detect the
    # serialized credential shape without retaining any matching value in reports.
    if data.lstrip().startswith((b'{', b'[')):
        try: obj=json.loads(data)
        except (ValueError, UnicodeDecodeError): obj=None
        def credential(value):
            if isinstance(value,dict):
                keys={str(k).lower():v for k,v in value.items()}
                if keys.get('schema_version',keys.get('schemaversion'))==1 and ('token_kind' in keys or 'tokenkind' in keys) and isinstance(keys.get('token'),str) and keys['token']:return True
                if any(isinstance(keys.get(k),str) and keys[k] for k in ('access_token','refresh_token','nex_token','client_secret','private_key')):return True
                return any(credential(v) for v in value.values())
            return isinstance(value,list) and any(credential(v) for v in value)
        if credential(obj):hits.append({'path':rel,'line':1,'category':'serialized_credential_payload'})
    return hits

def ancestors_anchor(text):
    seen=collections.Counter(); out=set(); fenced=False
    for line in text.splitlines():
        if line.startswith('```'): fenced=not fenced
        if fenced: continue
        m=re.match(r'#{1,6}\s+(.*?)\s*#*$',line)
        if not m: continue
        s=re.sub(r'[^\w\- ]','',m.group(1).lower()).replace(' ','-')
        index=seen[s];seen[s]+=1;out.add(s if not index else f'{s}-{index}')
    return out

def normalize_link(rel, target):
    file,_,anchor=unquote(target.strip('<>')).partition('#')
    if re.match(r'[a-z][a-z0-9+.-]*:',file,re.I): return None,anchor
    base=PurePosixPath(rel).parent; stack=list(base.parts)
    for piece in PurePosixPath(file).parts:
        if piece=='..':
            if not stack: return '',anchor
            stack.pop()
        elif piece not in {'.','/'}:stack.append(piece)
    return '/'.join(stack) if file else rel,anchor

def sanitize_markdown(rel, raw, excluded, root_anchors, upstream):
    text=raw.decode('utf-8'); operations=[]
    # Remove image embeds rather than leave missing assets or externally embed
    # copyrighted visuals. All inherited images are denied; original draft art
    # is overlaid separately after this transformation.
    def image(m):
        operations.append('remove inherited image embed'); return ''
    text=re.sub(r'!\[[^\]]*\]\([^\n]*?\)',image,text)
    text=re.sub(r'!\[[^\]]*\]\s*\[[^\]]*\]',image,text)
    text=re.sub(r'<(?:img|source)\b[^>]*>',image,text,flags=re.I|re.S)
    def link(m):
        label,target=m.group(1),m.group(2)
        resolved,anchor=normalize_link(rel,target)
        if resolved is None:return m.group(0)
        if resolved in excluded or resolved=='README.md' and anchor and anchor not in root_anchors:
            operations.append('replace unavailable link with upstream reference')
            return f'[{label}]({upstream}/README.md' + (('#'+anchor) if resolved=='README.md' and anchor else '') + ')'
        return m.group(0)
    text=re.sub(r'(?<!!)\[([^\]]+)\]\(([^\s)]+)\)',link,text)
    # Scrub machine-specific prose/examples only. Source code is never modified
    # by a blanket replacement; any source finding remains an export blocker.
    text=re.sub(r'/Users/[^/\s`"<>]+/Documents/Codex/\d{4}-\d{2}-\d{2}/[^/\s`"<>]+','/path/to/workspace',text)
    text=re.sub(r'/(?:Users|home)/([A-Za-z0-9_.-]+)',lambda m:m.group(0) if m.group(1).lower().encode() in GENERIC_USERS else '/path/to/user',text)
    if text != raw.decode('utf-8'):operations.append('public documentation normalization')
    return text.encode(),sorted(set(operations))

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,required=True);parser.add_argument('--destination',type=Path,required=True)
    default_draft=Path(__file__).resolve().parents[1]
    if not (default_draft/'public-assets.json').is_file():default_draft=Path(__file__).resolve().parents[2]
    parser.add_argument('--draft',type=Path,default=default_draft);parser.add_argument('--report',type=Path,required=True)
    parser.add_argument('--apply',action='store_true');parser.add_argument('--confirm-frozen',action='store_true');parser.add_argument('--expected-digest')
    args=parser.parse_args();source=args.source.resolve();destination=args.destination.resolve();draft=args.draft.resolve();report=args.report.resolve()
    if source==destination or source in destination.parents or destination in source.parents:parser.error('Source and destination must be separate repositories.')
    if not (destination/'.git').exists():parser.error('Destination must already be the separate GitHub Desktop checkout.')
    head=git(source,'rev-parse','HEAD').decode().strip(); upstream='https://github.com/seedds/nxnative/blob/'+head
    all_paths=sorted(set(os.fsdecode(p) for p in git(source,'ls-files','-co','--exclude-standard','-z').split(b'\0') if p))
    tracked={os.fsdecode(p) for p in git(source,'ls-files','-z').split(b'\0') if p}
    excluded={};inputs={}; modes={};origins={}; operations={};binary=[];symlinks=[]
    for rel in all_paths:
        path=source/rel;reason=filtered(rel,tracked)
        if path.is_symlink():reason='symlink requires explicit provenance review';symlinks.append(rel)
        if not path.is_file() and not path.is_symlink():continue
        if reason:excluded[rel]=reason;continue
        data=path.read_bytes();kind=binary_kind(data)
        if kind:
            binary.append({'path':rel,'kind':kind,'bytes':len(data),'trackedTranslator':rel.startswith(TRANSLATOR) and rel in tracked})
            if not (rel.startswith(TRANSLATOR) and rel in tracked):excluded[rel]='compiled binary outside checked translator';continue
        if data[:4] in {b'NSO0',b'NRO0',b'NCA2',b'NCA3'}:excluded[rel]='Nintendo executable/archive magic';continue
        inputs[rel]=data;modes[rel]=stat.S_IMODE(path.stat().st_mode);origins[rel]='canonical'
    own={name:(draft/name).read_bytes() for name in DOCS}
    asset_policy=json.loads((draft/'public-assets.json').read_text())
    for asset in asset_policy['assets']:
        rel=asset['path'];path=draft/rel
        if not rel.startswith('docs/images/') or '..' in PurePosixPath(rel).parts or not asset.get('provenance'):parser.error('Invalid original-asset provenance record.')
        if path.is_symlink() or not path.is_file():parser.error('An approved original asset is missing or is a symlink.')
        data=path.read_bytes()
        if digest(data)!=asset['sha256']:parser.error('An original asset changed; review its provenance before updating the allowlist.')
        own[rel]=data
    # Preserve the sole GitHub Desktop baseline file explicitly. Its reviewed
    # text and digest enter the plan; arbitrary destination extras stay blocked.
    attributes=destination/'.gitattributes'
    if attributes.exists() and '.gitattributes' not in inputs:
        if attributes.is_symlink() or not attributes.is_file() or attributes.stat().st_size>4096:parser.error('Destination .gitattributes must be a small regular file.')
        data=attributes.read_bytes()
        expected=b'# Auto detect text files and perform LF normalization\n* text=auto\n'
        if data.replace(b'\r\n',b'\n')!=expected:parser.error('Review destination .gitattributes before retaining a different baseline.')
        own['.gitattributes']=data
    notices=draft/'notices'
    if notices.exists():
        for path in sorted(notices.rglob('*')):
            if path.is_symlink():parser.error('Notices overlay must not contain symlinks.')
            if path.is_file():
                rel='dm/third_party/notices/'+path.relative_to(notices).as_posix()
                own[rel]=path.read_bytes()
    # Keep this reviewed, asset-free maintenance workflow in the durable repo.
    maintainer_source=draft/'export-tools'
    if maintainer_source.is_dir():
        for name in ('prepare_export.py','test_prepare_export.py','README.md'):
            own['tools/maintainers/'+name]=(maintainer_source/name).read_bytes()
    root_anchors=ancestors_anchor(own['README.md'].decode())
    outputs={}
    for rel,data in inputs.items():
        if rel.endswith('.md'):
            data,changes=sanitize_markdown(rel,data,excluded,root_anchors,upstream)
            if changes:operations[rel]=changes
        outputs[rel]=data
    for rel,data in own.items():outputs[rel]=data;modes[rel]=0o644;origins[rel]='presentation'
    findings=[]
    for rel,data in outputs.items():
        if origins[rel]=='presentation' and binary_kind(data):
            findings.append({'path':rel,'line':1,'category':'binary_in_documentation_overlay'})
        if rel.startswith('dm/third_party/notices/'):
            try: data.decode('utf-8')
            except UnicodeDecodeError: findings.append({'path':rel,'line':1,'category':'nontext_notice_overlay'})
            if b'\0' in data:findings.append({'path':rel,'line':1,'category':'binary_notice_overlay'})
        findings.extend(scan(rel,data))
    missing=[]
    for rel,data in outputs.items():
        if not rel.endswith('.md') or 'third_party' in PurePosixPath(rel).parts:continue
        text=re.sub(r'```.*?```','',data.decode('utf-8'),flags=re.S)
        for line_no,line in enumerate(text.splitlines(),1):
            line=re.sub(r'`[^`]*`','',line)
            for m in re.finditer(r'\]\(([^\s)]+)',line):
                resolved,anchor=normalize_link(rel,m.group(1))
                if resolved is None:continue
                exists=resolved in outputs or any(x.startswith(resolved.rstrip('/')+'/') for x in outputs)
                if not exists:missing.append({'path':rel,'line':line_no,'target':m.group(1),'reason':'missing output'})
                elif anchor and resolved.endswith('.md') and anchor.lower() not in ancestors_anchor(outputs[resolved].decode('utf-8')):
                    missing.append({'path':rel,'line':line_no,'target':m.group(1),'reason':'missing anchor'})
    manifest=[]
    for rel,data in sorted(outputs.items()):
        original=inputs.get(rel,own.get(rel,data))
        manifest.append({'path':rel,'origin':origins[rel],'mode':modes[rel],'inputSHA256':digest(original),'sha256':digest(data),'bytes':len(data),'transforms':operations.get(rel,[])})
    fingerprint=digest(json.dumps({'sourceCommit':head,'files':manifest},sort_keys=True,separators=(',',':')).encode())
    report.mkdir(parents=True,exist_ok=True)
    (report/'dry-run-manifest.json').write_text(json.dumps({'format':1,'sourceCommit':head,'fingerprint':fingerprint,'files':manifest},indent=2))
    (report/'excluded-files.json').write_text(json.dumps([{'path':p,'reason':r} for p,r in sorted(excluded.items())],indent=2))
    (report/'secret-scan.json').write_text(json.dumps({'valuesRedacted':True,'filesScanned':len(outputs),'findings':findings,'imagePolicy':'inherited images denied; hash-reviewed original artwork and Studio UI allowlist','NintendoAssetsExported':False},indent=2))
    (report/'link-check.json').write_text(json.dumps({'issues':missing},indent=2))
    (report/'binary-audit.json').write_text(json.dumps({'binaries':binary,'symlinksExcluded':symlinks},indent=2))
    summary={'plannedFiles':len(outputs),'plannedBytes':sum(len(x) for x in outputs.values()),'excludedFiles':len(excluded),'excludedImages':sum(PurePosixPath(x).suffix.lower() in ART for x in excluded),'findings':len(findings),'linkIssues':len(missing),'fingerprint':fingerprint,'copied':False}
    print(json.dumps(summary,indent=2))
    if not args.apply:return
    if not args.confirm_frozen or args.expected_digest!=fingerprint:parser.error('Apply requires root freeze confirmation and the exact current reviewed fingerprint.')
    if findings or missing:parser.error('Resolve every redacted scan and link finding before applying.')
    # Retain the destination .git and its configured identity. A source import
    # may replace the initial README/.gitignore, but never stages or commits.
    existing=git(destination,'ls-files','-co','--exclude-standard','-z').split(b'\0')
    extras=[os.fsdecode(x) for x in existing if x and os.fsdecode(x) not in outputs]
    if extras:parser.error('Destination has files outside the reviewed plan; preserve/reconcile them before apply.')
    for rel in outputs:
        target=destination/rel
        if target.is_symlink() or any(p.is_symlink() for p in target.parents if p!=destination and destination in p.parents):parser.error('Destination contains a symlink; stop before writing.')
        if target.exists() and not target.is_file():parser.error('Destination target is not a regular file; stop before writing.')
    for rel,data in sorted(outputs.items()):
        target=destination/rel
        target.parent.mkdir(parents=True,exist_ok=True);temporary=target.with_name('.'+target.name+'.source-import')
        temporary.write_bytes(data);os.chmod(temporary,modes[rel]);os.replace(temporary,target)
    print('Source files copied. No git staging, commit or publication performed.')
if __name__=='__main__':main()
