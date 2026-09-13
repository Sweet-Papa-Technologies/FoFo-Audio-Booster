#!/usr/bin/env python3
"""Publish verified CI artifacts without ever overwriting an existing release."""
import hashlib
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import xml.etree.ElementTree as ET

repo = 'Sweet-Papa-Technologies/FoFo-Audio-Booster'
version = plistlib.loads(Path('Config/Info.plist').read_bytes())['CFBundleShortVersionString']
assert re.fullmatch(r'\d+\.\d+\.\d+', version), 'Invalid release version'
tag = f'v{version}'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--artifacts', type=Path, default=Path('build/release'))
parser.add_argument('--verify-only', action='store_true')
args = parser.parse_args()
artifacts = args.artifacts
names = [f'FoFoBooster-{version}.dmg', f'FoFoBooster-{version}.pkg',
         f'FoFoBooster-{version}.zip', 'appcast.xml', 'SHA256SUMS', 'fofobooster.rb',
         f'FoFoBooster-{version}.dmg.notary.json', f'FoFoBooster-{version}.pkg.notary.json',
         'notarization.zip.notary.json']
for name in names:
    assert (artifacts / name).is_file(), f'Missing {name}'
for name in names:
    if name.endswith('.notary.json'):
        assert json.loads((artifacts / name).read_text())['status'] == 'Accepted', name
checked = set()
for line in (artifacts / 'SHA256SUMS').read_text().splitlines():
    digest, name = line.split()
    assert name in names and name not in checked, f'Unexpected checksum entry {name}'
    assert hashlib.sha256((artifacts / name).read_bytes()).hexdigest() == digest, name
    checked.add(name)
assert {f'FoFoBooster-{version}.dmg', f'FoFoBooster-{version}.pkg', 'appcast.xml'} <= checked
enclosure = ET.parse(artifacts / 'appcast.xml').find('./channel/item/enclosure')
assert enclosure is not None
assert enclosure.attrib['url'] == f'https://github.com/{repo}/releases/download/{tag}/FoFoBooster-{version}.dmg'
assert int(enclosure.attrib['length']) == (artifacts / f'FoFoBooster-{version}.dmg').stat().st_size
assert enclosure.attrib['{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature']
if args.verify_only:
    print(f'Verified release assets for {tag}.')
    raise SystemExit(0)

def gh(*args):
    return subprocess.check_output(['gh', *args, '--repo', repo], text=True)

# A published version is immutable, including a manually published initial version.
existing = json.loads(gh('release', 'list', '--limit', '100', '--json', 'tagName'))
assert not any(r['tagName'] == tag for r in existing), f'{tag} already exists; do not replace public binaries. Bump the app version.'
sha = os.environ['GITHUB_SHA']
subprocess.run(['git', 'merge-base', '--is-ancestor', sha, 'origin/main'], check=True)
notes = artifacts / 'release-notes.md'
details = Path(f'docs/releases/{version}.md')
notes.write_text((details.read_text()+'\n\n' if details.is_file() else '') + f'''FoFoBooster {version} is a free, native Mac audio booster for macOS 14.4 and later, on Apple silicon and Intel.

Download the DMG and drag FoFoBooster to Applications, or use the PKG installer. These artifacts were built by GitHub Actions, Developer ID signed, notarized, and stapled. SHA256SUMS contains the installer and appcast checksums.

See the [website](https://fofo-booster.web.app/) and [setup guide](https://fofo-booster.web.app/guide/). Hardware and plugin compatibility vary; see the repository's validation notes. The signed appcast supports in-app Sparkle updates.
''')
gh('release', 'create', tag, '--draft', '--target', sha, '--title', f'FoFoBooster {version}', '--notes-file', str(notes))
gh('release', 'upload', tag, *(str(artifacts / n) for n in names))
gh('release', 'edit', tag, '--draft=false', '--latest')
print(f'Published {tag} with signed CI downloads.')
