#!/usr/bin/env python3
"""Build, SPT-sign, notarize, staple, package, and sign updates. Never publishes."""
import argparse, concurrent.futures, hashlib, json, os, pathlib, plistlib, shutil, subprocess
from importlib.machinery import SourceFileLoader
ROOT=pathlib.Path(__file__).resolve().parent.parent
CONFIG=json.loads((ROOT/'Config/Signing.json').read_text())
OUT=ROOT/'build/release';OUT.mkdir(parents=True,exist_ok=True)
def run(args,**kwargs):
    return subprocess.run([str(v) for v in args],check=True,cwd=ROOT,**kwargs)
def notarize(path):
    print(f'Submitting {path.name} for notarization…',flush=True)
    keychain=['--keychain',os.environ['SIGNING_KEYCHAIN']] if os.environ.get('SIGNING_KEYCHAIN') else []
    result=run(['xcrun','notarytool','submit',path,'--keychain-profile',os.environ.get('NOTARY_PROFILE',CONFIG['notaryProfile']),*keychain,'--wait','--output-format','json'],capture_output=True,text=True)
    report=json.loads(result.stdout);(OUT/(path.name+'.notary.json')).write_text(json.dumps(report,indent=2)+'\n')
    if report.get('status')!='Accepted':
        raise RuntimeError(f"Notarization did not accept {path.name}; submission {report.get('id')}.")
    print(f'Apple accepted {path.name}.',flush=True)
def main():
    parser=argparse.ArgumentParser();parser.add_argument('--skip-build',action='store_true');parser.add_argument('--sign-only',action='store_true');parser.add_argument('--app',type=pathlib.Path);args=parser.parse_args()
    if not args.skip_build:
        run(['python3','scripts/generate-project.py'])
        with (OUT/'build.log').open('w') as log:
            run(['xcodebuild','-project','FoFoBooster.xcodeproj','-scheme','FoFoBooster','-configuration','Release','-derivedDataPath','.build/xcode','-clonedSourcePackagesDirPath','.build/packages','CODE_SIGNING_ALLOWED=NO','ARCHS=arm64 x86_64','ONLY_ACTIVE_ARCH=NO','build'],stdout=log,stderr=subprocess.STDOUT)
    source=(args.app or ROOT/'.build/xcode/Build/Products/Release/FoFoBooster.app').resolve()
    app=OUT/'FoFoBooster.app'
    if source!=app:
        if app.exists():shutil.rmtree(app)
        run(['ditto',source,app])
    if not app.exists():raise RuntimeError('No built application was found.')
    plist=app/'Contents/Info.plist';info=plistlib.loads(plist.read_bytes())
    public_key=(ROOT/'Config/SparklePublicKey.txt').read_text().strip()
    info['SUPublicEDKey']=public_key
    # Release appcast is a stable GitHub release asset; publishing stays separate.
    info['SUFeedURL']=f"https://github.com/{CONFIG['githubRepository']}/releases/latest/download/appcast.xml"
    plist.write_bytes(plistlib.dumps(info))
    signer=SourceFileLoader('fofo_sign',str(ROOT/'scripts/sign-app.py')).load_module();signer.sign(app)
    if args.sign_only:return
    zipped=OUT/'notarization.zip';run(['ditto','-c','-k','--keepParent',app,zipped]);notarize(zipped)
    run(['xcrun','stapler','staple',app]);run(['xcrun','stapler','validate',app])
    version=info['CFBundleShortVersionString']
    stage=OUT/'dmg-root'
    if stage.exists():shutil.rmtree(stage)
    stage.mkdir();run(['ditto',app,stage/'FoFoBooster.app']);(stage/'Applications').symlink_to('/Applications')
    dmg=OUT/f'FoFoBooster-{version}.dmg';pkg=OUT/f'FoFoBooster-{version}.pkg'
    run(['hdiutil','create','-volname','FoFoBooster','-srcfolder',stage,'-ov','-format','UDZO',dmg])
    run(['codesign','--sign',CONFIG['applicationIdentity'],'--timestamp',dmg])
    run(['productbuild','--component',app,'/Applications','--sign',CONFIG['installerIdentity'],'--timestamp',pkg])
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        list(pool.map(notarize,[dmg,pkg]))
    for archive in [dmg,pkg]:run(['xcrun','stapler','staple',archive]);run(['xcrun','stapler','validate',archive])
    run(['spctl','--assess','--type','execute','--verbose=2',app])
    run(['pkgutil','--check-signature',pkg])
    feed=OUT/'feed'
    if feed.exists():shutil.rmtree(feed)
    feed.mkdir();shutil.copy2(dmg,feed/dmg.name)
    sparkle=ROOT/'.build/packages/artifacts/sparkle/Sparkle/bin'
    if os.environ.get('SPARKLE_PRIVATE_KEY'):
        signing=['--ed-key-file','-'];secret_input=os.environ['SPARKLE_PRIVATE_KEY'].encode()+b'\n'
    else:signing=['--account',CONFIG['sparkleAccount']];secret_input=None
    run([sparkle/'generate_appcast',*signing,'--download-url-prefix',f"https://github.com/{CONFIG['githubRepository']}/releases/download/v{version}/",feed],input=secret_input)
    shutil.copy2(feed/'appcast.xml',OUT/'appcast.xml')
    run(['python3','scripts/make-cask.py',dmg]);shutil.copy2(ROOT/'build/fofobooster.rb',OUT/'fofobooster.rb')
    (OUT/'SHA256SUMS').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in [dmg,pkg,OUT/'appcast.xml']))
    run(['ditto','-c','-k','--keepParent',app,OUT/f'FoFoBooster-{version}.zip'])
    print(f'Notarized app, DMG, PKG, signed appcast and cask ready in {OUT}. Nothing was published.',flush=True)
if __name__=='__main__':main()
