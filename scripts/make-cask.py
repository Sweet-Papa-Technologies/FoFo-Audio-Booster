#!/usr/bin/env python3
import hashlib,pathlib,sys,re
if len(sys.argv)!=2: raise SystemExit('Usage: scripts/make-cask.py path/to/FoFoBooster-VERSION.dmg')
p=pathlib.Path(sys.argv[1]); match=re.fullmatch(r'FoFoBooster-(\d+\.\d+\.\d+)\.dmg',p.name)
if not match: raise SystemExit('Expected a versioned FoFoBooster DMG')
root=pathlib.Path(__file__).resolve().parent.parent
text=(root/'Casks/fofobooster.rb.in').read_text().replace('@VERSION@',match[1]).replace('@SHA256@',hashlib.sha256(p.read_bytes()).hexdigest())
output=root/'build/fofobooster.rb';output.parent.mkdir(exist_ok=True);output.write_text(text);print(output)
