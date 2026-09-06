#!/usr/bin/env python3
"""Run a quiet, non-disruptive engine soak from an immutable app copy."""
import argparse, pathlib, subprocess, json, datetime
root=pathlib.Path(__file__).resolve().parent.parent
parser=argparse.ArgumentParser()
parser.add_argument('--app',type=pathlib.Path,default=root/'build/release/FoFoBooster.app')
parser.add_argument('--seconds',type=int,default=86400)
parser.add_argument('--relaunch-every',type=int,default=300)
args=parser.parse_args()
if args.seconds<1 or args.relaunch_every<1:parser.error('Durations must be positive.')
out=root/'build/soak'/datetime.datetime.now().strftime('%Y%m%d-%H%M%S');out.mkdir(parents=True)
app=out/'FoFoBooster.app'
subprocess.run(['ditto',str(args.app.resolve()),str(app)],check=True)
with (out/'events.jsonl').open('wb') as log, (out/'stderr.log').open('wb') as errors:
    child=subprocess.Popen([str(app/'Contents/MacOS/FoFoBooster'),'--soak',str(args.seconds),'--relaunch-every',str(args.relaunch_every)],stdout=log,stderr=errors,stdin=subprocess.DEVNULL,start_new_session=True)
(out/'runner.json').write_text(json.dumps({'pid':child.pid,'durationSeconds':args.seconds,'relaunchEverySeconds':args.relaunch_every,'stopCommand':f'kill {child.pid}','scope':'Only its own quiet test source is restarted; no output switching or sleep is initiated.'},indent=2)+'\n')
print(f'Started PID {child.pid}; events: {out}/events.jsonl\nStop: kill {child.pid}')
