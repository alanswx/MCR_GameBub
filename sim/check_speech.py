#!/usr/bin/env python3
"""Four-state speech/reference comparison with local user-supplied ROM data."""
import argparse
from pathlib import Path
import subprocess
import wave

ROOT = Path(__file__).resolve().parents[1]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--rom', type=Path, default=ROOT / 'scratch/roms/dotrone.rom')
    args = p.parse_args()
    work = ROOT / 'build/speech-check'
    work.mkdir(parents=True, exist_ok=True)
    out = ROOT / 'scratch/speech-test'
    out.mkdir(parents=True, exist_ok=True)
    def run(name, command, marker=None):
        log = work / (name + '.log')
        with log.open('w') as stream:
            result = subprocess.run(command, cwd=work, stdout=stream, stderr=subprocess.STDOUT)
        if result.returncode or (marker and marker not in log.read_text()):
            print(log.read_text()[-6000:])
            raise SystemExit(f'{name} failed: {log}')
        print(f'{name}: passed', flush=True)
    run('vhdl', ['xvhdl', str(ROOT / 'rtl/mcr3mono/pia6821.vhdl')])
    sources = [*sorted((ROOT / 'rtl/speech').glob('*.*')),
               ROOT / 'rtl/gamebub/gb_sram.sv', ROOT / 'rtl/gamebub/gb_mcr_memory.sv', ROOT / 'sim/tb_speech.sv']
    run('compile', ['xvlog', '--sv', *map(str, sources)])
    run('elaborate', ['xelab', '--timescale', '1ns/1ps', 'work.tb_speech', '-s', 'speech_test'])
    pcm = out / 'master-control.pcm'
    run('run', ['xsim', 'speech_test', '--runall', '--testplusarg', f'rom={args.rom.resolve()}',
                '--testplusarg', f'audio={pcm}'], 'SPEECH PASS')
    with wave.open(str(out / 'master-control.wav'), 'wb') as wav:
        wav.setparams((1, 2, 48019, 0, 'NONE', 'not compressed'))
        wav.writeframes(pcm.read_bytes())
    print(f'Speech/reference comparison passed; local audio: {out / "master-control.wav"}')


if __name__ == '__main__':
    main()
