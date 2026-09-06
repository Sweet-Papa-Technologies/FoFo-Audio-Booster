#!/usr/bin/env python3
"""Sign a complete app with the confirmed SPT identity, from the inside out."""
import argparse, json, os, pathlib, plistlib, subprocess
ROOT=pathlib.Path(__file__).resolve().parent.parent
CONFIG=json.loads((ROOT/'Config/Signing.json').read_text())
def run(args): subprocess.run(args,check=True)
def sign(app):
    identity=CONFIG['applicationIdentity']
    common=['codesign','--force','--options','runtime','--timestamp','--sign',identity]
    if os.environ.get('SIGNING_KEYCHAIN'): common += ['--keychain',os.environ['SIGNING_KEYCHAIN']]
    def item(path,entitlements=None):
        if not path.exists(): return
        args=common.copy()
        if entitlements: args += ['--entitlements',str(ROOT/entitlements)]
        run(args+[str(path)])
    framework=app/'Contents/Frameworks/Sparkle.framework'
    for relative in ['Versions/B/Autoupdate','Versions/B/Updater.app','Versions/B/XPCServices/Downloader.xpc','Versions/B/XPCServices/Installer.xpc']:
        item(framework/relative)
    item(framework)
    item(app/'Contents/PlugIns/FoFoBoosterWidget.appex','Config/Widget.entitlements')
    item(app,'Config/App.entitlements')
    run(['codesign','--verify','--deep','--strict',str(app)])
    for executable in [app/'Contents/MacOS/FoFoBooster',app/'Contents/PlugIns/FoFoBoosterWidget.appex/Contents/MacOS/FoFoBoosterWidget']:
        run(['lipo',str(executable),'-verify_arch','arm64','x86_64'])
    metadata=subprocess.run(['codesign','-d','--verbose=4',str(app)],capture_output=True,text=True,check=True).stderr
    if f"TeamIdentifier={CONFIG['team']}" not in metadata: raise RuntimeError('Unexpected signing team.')
    print('Verified SPT signature, hardened runtime, and both architectures.',flush=True)
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('app',type=pathlib.Path);args=parser.parse_args();sign(args.app.resolve())
