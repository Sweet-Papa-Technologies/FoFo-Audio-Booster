#!/usr/bin/env python3
"""Provision SPT local notarization and GitHub environment secrets without logging secrets."""
import argparse, base64, json, os, pathlib, re, secrets, subprocess, tempfile
ROOT = pathlib.Path(__file__).resolve().parent.parent
CONFIG = json.loads((ROOT / 'Config/Signing.json').read_text())
def run(args, data=None):
    result = subprocess.run(args, input=data, capture_output=True, cwd=ROOT)
    if result.returncode:
        # Never dump argv/stdout/stderr: they may contain private credentials.
        raise RuntimeError(f'{pathlib.Path(args[0]).name} failed with exit status {result.returncode}')
    return result.stdout
def gh_api(path, method='GET', body=None):
    args=['gh','api',path,'--method',method]
    if body is not None: args += ['--input','-']
    return run(args, json.dumps(body).encode() if body is not None else None)
def set_secret(name, value):
    run(['gh','secret','set',name,'--repo',CONFIG['githubRepository'],'--env',CONFIG['githubEnvironment']], value)
    print(f'Configured encrypted environment secret: {name}', flush=True)
def main():
    parser=argparse.ArgumentParser(); parser.add_argument('--local-only',action='store_true'); args=parser.parse_args()
    sparkle=ROOT/'.build/packages/artifacts/sparkle/Sparkle/bin/generate_keys'
    if not sparkle.exists(): raise RuntimeError('Resolve the Xcode Sparkle dependency first.')
    # spt-notary is the existing custom item used by FoFoPedalVST.
    metadata=run(['security','find-generic-password','-s','spt-notary']).decode()
    match=re.search(r'"acct"<blob>="([^"]+)"',metadata)
    if not match: raise RuntimeError('The spt-notary Keychain item has no Apple ID account.')
    apple_id=match[1].encode()
    password=run(['security','find-generic-password','-s','spt-notary','-w']).rstrip(b'\n')
    run(['xcrun','notarytool','store-credentials',CONFIG['notaryProfile'],'--apple-id',apple_id.decode(),'--team-id',CONFIG['team'],'--password',password.decode()])
    print('Local notarization credentials validated and stored in Keychain.',flush=True)
    run([str(sparkle),'--account',CONFIG['sparkleAccount']])
    public_key=run([str(sparkle),'--account',CONFIG['sparkleAccount'],'-p']).decode().strip()
    if len(base64.b64decode(public_key,validate=True)) != 32: raise RuntimeError('Unexpected Sparkle public-key format.')
    (ROOT/'Config/SparklePublicKey.txt').write_text(public_key+'\n')
    print('Application-specific Sparkle key is in Keychain; public key saved in Config.',flush=True)
    if args.local_only: return
    repo=CONFIG['githubRepository']; environment=CONFIG['githubEnvironment']
    gh_api(f'repos/{repo}/environments/{environment}','PUT',{'deployment_branch_policy':{'protected_branches':False,'custom_branch_policies':True}})
    existing=json.loads(gh_api(f'repos/{repo}/environments/{environment}/deployment-branch-policies'))['branch_policies']
    for name,kind in [('main','branch'),('v*','tag')]:
        if not any(p['name']==name and p.get('type','branch')==kind for p in existing):
            gh_api(f'repos/{repo}/environments/{environment}/deployment-branch-policies','POST',{'name':name,'type':kind})
    # Fresh temporary files are mode 0600, outside the checkout, and removed even on failure.
    with tempfile.TemporaryDirectory(prefix='fofo-signing-') as folder:
        directory=pathlib.Path(folder); exporter=directory/'export-spt'
        run(['xcrun','swiftc',str(ROOT/'scripts/signing/export-spt-identities.swift'),'-o',str(exporter)])
        export_password=secrets.token_urlsafe(48).encode()
        p12=run([str(exporter)],export_password+b'\n')
        if not p12: raise RuntimeError('No signing identities were exported.')
        set_secret('APPLE_CERT_P12',base64.b64encode(p12))
        set_secret('APPLE_CERT_PASSWORD',export_password)
        set_secret('APPLE_ID',apple_id)
        set_secret('APPLE_APP_PASSWORD',password)
        private=directory/'sparkle-private'
        run([str(sparkle),'--account',CONFIG['sparkleAccount'],'-x',str(private)])
        os.chmod(private,0o600)
        set_secret('SPARKLE_PRIVATE_KEY',private.read_bytes().strip())
    print('SPT signing is configured locally and in the restricted GitHub signing environment.',flush=True)
if __name__=='__main__':
    try: main()
    except Exception as error: raise SystemExit(str(error))
