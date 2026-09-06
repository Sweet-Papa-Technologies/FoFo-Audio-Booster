#!/usr/bin/env python3
"""Import environment secrets into an ephemeral hosted-runner Keychain."""
import base64,json,os,pathlib,secrets,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[2]
config=json.loads((ROOT/'Config/Signing.json').read_text())
def run(args):
    result=subprocess.run(args,capture_output=True)
    if result.returncode:raise RuntimeError(f'{pathlib.Path(args[0]).name} failed (details suppressed to protect credentials)')
    return result.stdout
required=['APPLE_CERT_P12','APPLE_CERT_PASSWORD','APPLE_ID','APPLE_APP_PASSWORD']
if any(not os.environ.get(name) for name in required):raise SystemExit('Required signing secrets are missing; refusing to make an unsigned release.')
keychain=pathlib.Path(os.environ['RUNNER_TEMP'])/'fofo-signing.keychain-db';password=secrets.token_urlsafe(48)
# Register cleanup path before creating or importing anything.
with open(os.environ['GITHUB_ENV'],'a') as f:f.write(f'SIGNING_KEYCHAIN={keychain}\nNOTARY_PROFILE={config["notaryProfile"]}\n')
run(['security','create-keychain','-p',password,str(keychain)])
run(['security','set-keychain-settings','-lut','21600',str(keychain)])
run(['security','unlock-keychain','-p',password,str(keychain)])
run(['security','list-keychains','-d','user','-s',str(keychain),'login.keychain-db'])
with tempfile.NamedTemporaryFile(dir=os.environ['RUNNER_TEMP'],suffix='.p12') as archive:
    os.chmod(archive.name,0o600);archive.write(base64.b64decode(os.environ['APPLE_CERT_P12'],validate=True));archive.flush()
    run(['security','import',archive.name,'-k',str(keychain),'-P',os.environ['APPLE_CERT_PASSWORD'],'-T','/usr/bin/codesign','-T','/usr/bin/productbuild','-T','/usr/bin/productsign'])
run(['security','set-key-partition-list','-S','apple-tool:,apple:','-s','-k',password,str(keychain)])
identities=run(['security','find-identity','-v',str(keychain)]).decode()
if config['applicationIdentity'] not in identities or config['installerIdentity'] not in identities:raise SystemExit('The signing archive does not contain both SPT identities.')
run(['xcrun','notarytool','store-credentials',config['notaryProfile'],'--keychain',str(keychain),'--apple-id',os.environ['APPLE_ID'],'--team-id',config['team'],'--password',os.environ['APPLE_APP_PASSWORD']])
print('Imported SPT signing identities and validated notarization credentials.')
