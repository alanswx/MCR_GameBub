#!/usr/bin/env python3
"""Check catalog ROM detection/orientation, or startup frames, in the built fast model.

Compile first with sim/run_tb.py --backend verilator --compile-only. This is
an experimental two-state smoke check; Xsim platform tests remain required.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--games', nargs='+')
    p.add_argument('--out', type=Path, help='separate output folder for this validation run')
    p.add_argument('--frames', type=int, default=0, help='zero checks identity only; positive runs startup frames')
    p.add_argument('--jobs', type=int, default=4)
    args = p.parse_args()
    games = json.loads((ROOT / 'gamedb/games.json').read_text())
    if args.games:
        unknown = set(args.games) - {g['key'] for g in games}
        if unknown: p.error(f'Unknown games: {sorted(unknown)}')
        games = [g for g in games if g['key'] in args.games]
    if args.frames < 0 or args.jobs < 1: p.error('frames must be nonnegative and jobs positive')
    binary = ROOT / 'build/fast/obj/Vtb_gamebub'
    if not binary.is_file(): p.error('Compile the fast model first')
    folder = ROOT / 'scratch/catalog-startup' if args.frames else ROOT / 'scratch/catalog-identity'
    if args.out: folder = (ROOT / args.out).resolve()
    folder.mkdir(parents=True,exist_ok=True)
    def check(game):
        out = folder / game['key']; out.mkdir(exist_ok=True)
        cmd = [str(binary),f"+rom={ROOT / 'scratch/roms' / (game['key'] + '.rom')}",
            f"+prom={ROOT / 'scratch/roms/ssio.prom'}",f'+out={out}',
            f"+expected_family={game['family_id']}",f"+expected_game={game['mod']}",
            f"+expected_crc={game['crc32']}",f"+expected_portrait={int(game['portrait'])}",
            f"+expected_dips={game['dips']}",f"+expected_size={game['size']}",f"+expected_sg={int(game['sg'])}",f'+frames={args.frames or 1}',f'+dump={min(args.frames,30) or 1}']
        if not args.frames: cmd.append('+orientation_only')
        log = out / 'run.log'
        with log.open('w') as stream:
            result = subprocess.run(cmd,cwd=ROOT,stdout=stream,stderr=subprocess.STDOUT)
        marker = 'GAMEBUB PASS' if args.frames else 'ORIENTATION PASS'
        if result.returncode or marker not in log.read_text():
            return game['key'],False,log
        return game['key'],True,log
    failed = []
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for future in as_completed([pool.submit(check,g) for g in games]):
            name, passed, log = future.result()
            print(f"{name}: {'PASS' if passed else 'FAIL'} ({log.relative_to(ROOT)})",flush=True)
            if not passed: failed.append(name)
    if failed: raise SystemExit(f'Game checks failed: {failed}')
    print(f'CATALOG PASS: {len(games)} games, ' + (f'{args.frames} startup frames each' if args.frames else 'identity, DIP defaults and all grip modes'))

if __name__ == '__main__': main()
