import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
VERSION = plistlib.loads((ROOT / 'Config/Info.plist').read_bytes())['CFBundleShortVersionString']


class ReleaseValidation(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.assets = Path(self.temp.name)
        for suffix in ('dmg', 'pkg', 'zip'):
            (self.assets / f'FoFoBooster-{VERSION}.{suffix}').write_bytes(b'fixture')
        (self.assets / 'fofobooster.rb').write_text('# fixture')
        for name in (f'FoFoBooster-{VERSION}.dmg.notary.json', f'FoFoBooster-{VERSION}.pkg.notary.json', 'notarization.zip.notary.json'):
            (self.assets / name).write_text(json.dumps({'status': 'Accepted'}))
        (self.assets / 'appcast.xml').write_text(f'''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><enclosure url="https://github.com/Sweet-Papa-Technologies/FoFo-Audio-Booster/releases/download/v{VERSION}/FoFoBooster-{VERSION}.dmg" length="7" sparkle:edSignature="test-fixture"/></item></channel></rss>''')
        self.checksums()

    def checksums(self):
        names = [f'FoFoBooster-{VERSION}.dmg', f'FoFoBooster-{VERSION}.pkg', 'appcast.xml']
        (self.assets / 'SHA256SUMS').write_text(''.join(f'{hashlib.sha256((self.assets / name).read_bytes()).hexdigest()}  {name}\n' for name in names))

    def verify(self, valid):
        result = subprocess.run(['python3', 'scripts/publish-release.py', '--artifacts', str(self.assets), '--verify-only'], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, valid, result.stderr)

    def test_complete_consistent_release(self):
        self.verify(True)

    def test_rejects_corrupt_installer(self):
        (self.assets / f'FoFoBooster-{VERSION}.dmg').write_bytes(b'corrupt')
        self.verify(False)

    def test_rejects_failed_notarization(self):
        (self.assets / 'notarization.zip.notary.json').write_text('{"status":"Invalid"}')
        self.verify(False)

    def test_rejects_incomplete_release(self):
        (self.assets / f'FoFoBooster-{VERSION}.pkg').unlink()
        self.verify(False)

    def test_rejects_wrong_update_url_even_with_matching_hash(self):
        feed = self.assets / 'appcast.xml'
        feed.write_text(feed.read_text().replace('https://github.com/', 'https://example.com/'))
        self.checksums()
        self.verify(False)

    def test_rejects_checksum_path_escape(self):
        with (self.assets / 'SHA256SUMS').open('a') as file:
            file.write('0' * 64 + '  ../outside\n')
        self.verify(False)


if __name__ == '__main__':
    unittest.main()
