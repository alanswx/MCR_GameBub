#!/usr/bin/env python3
"""Generate and test the production framebuffer rotation mapper; source env.sh first."""
import argparse
from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parents[1]

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--defaults',action='store_true',help='also compare non-opted-in Coleco/IIgs HDL')
    args=p.parse_args()
    work=ROOT/'scratch/rotation-test'
    generated=work/'generated'
    work.mkdir(parents=True,exist_ok=True)
    def run(name,command,marker=None):
        log=work/(name+'.log')
        with log.open('w') as output:
            subprocess.run(command,cwd=ROOT,stdout=output,stderr=subprocess.STDOUT,check=True)
        if marker and marker not in log.read_text():
            raise SystemExit(f'Missing success marker in {log}')
        print(f'{name}: passed ({log.relative_to(ROOT)})',flush=True)
    run('generate',[str(ROOT/'mill'),'root.runMain','GenerateRotationTest',f'--target-dir={generated}'])
    run('build',['verilator','--binary','--timing','-j','8','-Wno-fatal','-Wno-lint','-Wno-style',
        '--top-module','tb_rotation','--Mdir',str(work/'obj'),
        *[str(p) for p in sorted(generated.glob('*.sv'))],str(ROOT/'sim/tb_rotation.sv')])
    run('run',[str(work/'obj/Vtb_rotation')],'ROTATION PASS')
    if args.defaults:
        run('defaults',['python3',str(ROOT/'scripts/check_rotation_defaults.py')])

if __name__=='__main__': main()
