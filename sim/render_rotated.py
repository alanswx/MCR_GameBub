#!/usr/bin/env python3
"""Render a native 320x240 capture through the tested LCD/HDMI address mapper."""
import argparse
from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parents[1]

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('capture',type=Path)
    p.add_argument('--out',type=Path,required=True)
    p.add_argument('--rotation',type=int,choices=(0,1,2,3),default=1)
    p.add_argument('--hdmi',action='store_true')
    args=p.parse_args()
    generated=ROOT/'scratch/rotation-test/generated'
    if not (generated/'RotationTestTop.sv').exists():
        p.error('Run python3 scripts/check_rotation.py first')
    work=ROOT/'scratch/rotation-render'
    work.mkdir(parents=True,exist_ok=True)
    with (work/'build.log').open('w') as output:
        subprocess.run(['verilator','--cc','--exe','--build','-j','8','-Wno-fatal','-Wno-lint','-Wno-style',
            '--top-module','RotationTestTop','--Mdir',str(work/'obj'),
            *[str(p) for p in sorted(generated.glob('*.sv'))],str(ROOT/'sim/render_rotated.cpp')],
            cwd=ROOT,stdout=output,stderr=subprocess.STDOUT,check=True)
    args.out.parent.mkdir(parents=True,exist_ok=True)
    subprocess.run([str(work/'obj/VRotationTestTop'),str(args.capture.resolve()),str(args.out.resolve()),str(args.rotation),str(int(args.hdmi))],check=True)

if __name__=='__main__': main()
