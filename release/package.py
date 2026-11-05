#!/usr/bin/env python3
"""Build verifiable local candidates or notarized macOS release assets.

Candidate mode never produces a publishable binary. Release mode requires a
Developer ID identity and an existing notarytool Keychain profile, with no
passwords in arguments, source files or manifests.
"""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def run(args, **kw):
    return subprocess.run([str(x) for x in args], check=True, **kw)

def output(args, **kw):
    return subprocess.check_output([str(x) for x in args], text=True, **kw).strip()

def sha(path):
    digest=hashlib.sha256()
    with Path(path).open('rb') as f:
        for chunk in iter(lambda:f.read(1024*1024),b''):
            digest.update(chunk)
    return digest.hexdigest()

def verify(app, config):
    run(['codesign','--verify','--deep','--strict',app])
    info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
    for key, expected in [('CFBundleIdentifier',config['bundle_id']),('CFBundleShortVersionString',config['version']),('LSMinimumSystemVersion',config['minimum_macos'])]:
        if info.get(key)!=expected:
            raise RuntimeError(f'{key}: {info.get(key)!r} != {expected!r}')
    for name in config['executables']:
        binary=app/'Contents/MacOS'/name
        actual=set(output(['lipo','-archs',binary]).split())
        if actual!=set(config['architectures']):
            raise RuntimeError(f'{name} architecture mismatch: {actual}')
        libraries='\n'.join(output(['otool','-L',binary]).splitlines()[1:])
        if any(str(x) in libraries for x in [Path.home(),ROOT,'/private/tmp/']):
            raise RuntimeError(f'{name} links a developer-local library')
    for relative in config['required_resources']:
        if not (app/'Contents'/relative).exists():
            raise RuntimeError('Missing bundled resource: '+relative)
    return {str(p.relative_to(app)):sha(p) for p in sorted(app.rglob('*')) if p.is_file()}

def preflight(mode, identity, profile):
    if mode!='release':
        return
    if not identity or identity=='-' or not profile:
        raise RuntimeError('BLOCKED: release requires --identity (Developer ID Application) and --notary-profile (existing Keychain profile). Candidate builds are not public releases.')
    identities=output(['security','find-identity','-v','-p','codesigning'])
    valid=[line for line in identities.splitlines() if 'Developer ID Application:' in line and identity in line]
    if len(valid)!=1:
        raise RuntimeError('BLOCKED: no unique valid Developer ID Application identity matches --identity')
    if output(['git','status','--porcelain'],cwd=ROOT):
        raise RuntimeError('BLOCKED: release requires a clean committed checkout')

def sign(app, config, identity, public):
    # Sign inner code before outer resources; never rely on --deep signing.
    flags=['--options','runtime','--timestamp'] if public else ['--options','runtime','--timestamp=none']
    for relative in config.get('signed_resources',[]):
        run(['codesign','--force','--sign',identity,*flags,app/'Contents'/relative])
    for name in config['executables']:
        run(['codesign','--force','--sign',identity,*flags,app/'Contents/MacOS'/name])
    entitlement_args=['--entitlements',ROOT/config['entitlements']] if config.get('entitlements') else []
    run(['codesign','--force','--sign',identity,*flags,*entitlement_args,app])

def notarize(path, profile, receipt_path):
    completed=subprocess.run(['xcrun','notarytool','submit',str(path),'--keychain-profile',profile,'--wait','--output-format','json'],capture_output=True,text=True)
    try:receipt=json.loads(completed.stdout)
    except ValueError:receipt={'status':'Error','exit_code':completed.returncode,'message':completed.stderr.strip()}
    receipt_path.write_text(json.dumps(receipt,indent=2)+'\n')
    if completed.returncode or receipt.get('status')!='Accepted':
        failures=ROOT/'artifacts/release-failures';failures.mkdir(parents=True,exist_ok=True)
        preserved=failures/(dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%S%f-')+receipt_path.name)
        preserved.write_text(json.dumps(receipt,indent=2)+'\n')
        raise RuntimeError('Notarization not Accepted; no release assets emitted. Receipt: '+str(preserved))

def archive(app, path):
    run(['ditto','-c','-k','--sequesterRsrc','--keepParent',app,path])

def build(config, app):
    if config['builder']=='mio':
        run(['python3',ROOT/'scripts/build-app.py'],cwd=ROOT)
        run(['ditto','-x','-k',ROOT/'dist/Mio-macOS.zip',app.parent])
    else:
        args=['swift','build','-c','release','--product',config['product']]
        for arch in config['architectures']:
            args+=['--arch',arch]
        run(args,cwd=ROOT)
        bin_dir=Path(output([*args,'--show-bin-path'],cwd=ROOT))
        (app/'Contents/MacOS').mkdir(parents=True)
        (app/'Contents/Resources').mkdir()
        shutil.copy2(bin_dir/config['product'],app/'Contents/MacOS'/config['product'])
        os.chmod(app/'Contents/MacOS'/config['product'],0o755)
        shutil.copy2(ROOT/config['info_plist'],app/'Contents/Info.plist')
        shutil.copy2(ROOT/config['icon'],app/'Contents/Resources'/Path(config['icon']).name)
    info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
    info.update(CFBundleShortVersionString=config['version'],CFBundleVersion=config['build'],LSMinimumSystemVersion=config['minimum_macos'])
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    notices=app/'Contents/Resources/ThirdParty'
    notices.mkdir(exist_ok=True)
    shutil.copy2(ROOT/'LICENSE',notices/(config['product']+'-LICENSE'))
    # Strip only Finder metadata on our newly assembled files, never quarantine
    # or user-selected files. This does not bypass Gatekeeper.
    for path in [app,*app.rglob('*')]:
        for attribute in ('com.apple.FinderInfo','com.apple.ResourceFork'):
            subprocess.run(['xattr','-d',attribute,path],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode',choices=['candidate','release'],default='candidate')
    parser.add_argument('--identity',help='Exact Developer ID Application identity name or hash')
    parser.add_argument('--notary-profile',help='Existing notarytool Keychain profile; never a password')
    parser.add_argument('--output',type=Path,help='New output directory, which must not already exist')
    args=parser.parse_args()
    config=json.loads((ROOT/'release/project.json').read_text())
    preflight(args.mode,args.identity,args.notary_profile)
    label=config['product']+'-'+config['version']+'-macOS-'+'-'.join(config['architectures'])
    if args.mode=='candidate':label+='-candidate'
    destination=args.output or ROOT/'dist'/args.mode/label
    if destination.exists():
        raise RuntimeError('Refusing to replace an existing artifact directory: '+str(destination))
    destination.parent.mkdir(parents=True,exist_ok=True)
    commit=output(['git','rev-parse','HEAD'],cwd=ROOT)
    dirty=bool(output(['git','status','--porcelain'],cwd=ROOT))
    with tempfile.TemporaryDirectory(prefix=config['product'].lower()+'-release-') as temp:
        stage=Path(temp)
        app=stage/config['app_name']
        build(config,app)
        public=args.mode=='release'
        sign(app,config,args.identity if public else '-',public)
        expected=verify(app,config)
        release_stage=stage/'assets';release_stage.mkdir()
        if public:
            submission=stage/'notary-submission.zip';archive(app,submission)
            notarize(submission,args.notary_profile,release_stage/'notary-app.json')
            run(['xcrun','stapler','staple',app])
            run(['xcrun','stapler','validate',app])
            run(['spctl','--assess','--type','execute','--verbose=2',app])
            signature=output(['codesign','-dv','--verbose=4',app],stderr=subprocess.STDOUT)
            if 'Authority=Developer ID Application:' not in signature or 'runtime' not in signature:
                raise RuntimeError('Developer ID or hardened runtime proof missing')
            expected=verify(app,config)
        zipped=release_stage/(label+'.zip');archive(app,zipped)
        dmg_stage=stage/'dmg';dmg_stage.mkdir()
        run(['ditto',app,dmg_stage/config['app_name']])
        (dmg_stage/'Applications').symlink_to('/Applications')
        image=release_stage/(label+'.dmg')
        run(['hdiutil','create','-volname',config['name'],'-srcfolder',dmg_stage,'-format','UDZO',image])
        if public:
            run(['codesign','--force','--sign',args.identity,'--timestamp',image])
            notarize(image,args.notary_profile,release_stage/'notary-dmg.json')
            run(['xcrun','stapler','staple',image])
            run(['xcrun','stapler','validate',image])
        # Exercise extraction and a real read-only DMG mount before emitting assets.
        extracted=stage/'extracted'
        run(['ditto','-x','-k',zipped,extracted])
        if verify(extracted/config['app_name'],config)!=expected:
            raise RuntimeError('ZIP payload differs from signed app')
        mounted=stage/'mounted';mounted.mkdir()
        run(['hdiutil','attach','-readonly','-nobrowse','-mountpoint',mounted,image],stdout=subprocess.DEVNULL)
        try:
            if verify(mounted/config['app_name'],config)!=expected:
                raise RuntimeError('Mounted DMG payload differs from ZIP')
            if (mounted/'Applications').readlink()!=Path('/Applications'):
                raise RuntimeError('DMG Applications install link missing')
        finally:
            run(['hdiutil','detach',mounted],stdout=subprocess.DEVNULL)
        source=release_stage/(config['product']+'-'+config['version']+'-source.zip')
        run(['git','archive','--format=zip','--prefix='+config['product']+'-'+config['version']+'/',commit,'-o',source],cwd=ROOT)
        (release_stage/'READ-ME-FIRST.txt').write_text((ROOT/'release/CANDIDATE.txt').read_text() if not public else (ROOT/'release/INSTALL.txt').read_text())
        receipt={'schema':1,'name':config['name'],'version':config['version'],'build':config['build'],'bundle_id':config['bundle_id'],
                 'minimum_macos':config['minimum_macos'],'architectures':config['architectures'],'source_commit':commit,'source_tree_dirty':dirty,
                 'built_at_utc':dt.datetime.now(dt.timezone.utc).isoformat(),'mode':args.mode,'apple_distribution_checks_passed':public,
                 'publication_status':'pending_clean_mac_acceptance' if public else 'local_candidate_only_not_for_publication',
                 'signing':'Developer ID Application, hardened runtime, notarized and stapled' if public else 'ad hoc, hardened runtime; NOT notarized; local QA only',
                 'verification':['code signatures verified','required bundled resources present','architectures verified','no developer-local dynamic library links','ZIP extracted and every file hash compared','DMG mounted read-only, every file hash compared, Applications link checked'],
                 'unverified':['Clean physical Mac installation after download is still required.','Apple Intel execution is not established by a universal binary alone.'] if 'x86_64' in config['architectures'] else ['Clean physical Mac installation after download is still required.'],
                 'files':[{ 'name':p.name,'bytes':p.stat().st_size,'sha256':sha(p)} for p in sorted(release_stage.iterdir()) if p.is_file()]}
        (release_stage/'manifest.json').write_text(json.dumps(receipt,indent=2)+'\n')
        (release_stage/'SHA256SUMS').write_text(''.join(f'{sha(p)}  {p.name}\n' for p in sorted(release_stage.iterdir()) if p.is_file() and p.name!='SHA256SUMS'))
        shutil.move(release_stage,destination)
    print(json.dumps({'output':str(destination),'apple_distribution_checks_passed':public,'source_commit':commit},indent=2))

if __name__=='__main__':
    try:main()
    except (RuntimeError,subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
