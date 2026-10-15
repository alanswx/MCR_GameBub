#!/usr/bin/env python3
"""Compare generated non-opted-in Coleco/IIgs HDL with framework db9d3b0 baselines."""
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess

ROOT=Path(__file__).resolve().parents[1]

def clean(source):
    return re.sub(r'\s+', ' ', re.sub(r'//[^\n]*', '', source)).strip()

def main():
    fixtures=json.loads((ROOT/'sim/fixtures/rotation_default_hashes.json').read_text())
    for key,folder,name in [('coleco','adam/ColecoVision_GameBub','ColecoVision'),('iigs','iigs/Apple-IIgs_GameBub','AppleIIgs')]:
        original=ROOT.parent.parent/folder/'chisel/src'/f'{name}.scala'
        temporary=ROOT/'chisel/src'/f'RotationRegression{name}.scala'
        work=ROOT/'scratch/rotation-regression'/('check-'+key)
        log=work.with_suffix('.log')
        work.parent.mkdir(parents=True,exist_ok=True)
        if temporary.exists():
            raise SystemExit(f'Remove stale temporary source first: {temporary}')
        try:
            shutil.copyfile(original,temporary)
            with log.open('w') as output:
                subprocess.run([str(ROOT/'mill'),'root.runMain','platform.handheld.HandheldTop',name,'4',f'--target-dir={work}'],cwd=ROOT,stdout=output,stderr=subprocess.STDOUT,check=True)
            actual={p.name:hashlib.sha256(clean(p.read_text()).encode()).hexdigest() for p in work.glob('*.sv')}
            if actual != fixtures[key]:
                raise SystemExit(f'{name} default HDL differs; see {work}')
            print(f'{name}: identical default HDL ({len(actual)} modules; source comments excluded)',flush=True)
        finally:
            temporary.unlink(missing_ok=True)

if __name__=='__main__': main()
