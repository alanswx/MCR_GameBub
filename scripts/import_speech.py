#!/usr/bin/env python3
"""Import the user's tested Squawk & Talk feature branch, without game data."""
import argparse
from datetime import datetime, timezone
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'scratch/upstream-speech'
URL = 'https://github.com/alanswx/Arcade-MCR3_MiSTer.git'
BRANCH = 'squawk-n-talk-speech'
MD5 = '979cb63d85f917cdae2179c515111a24'


def git(*args):
    return subprocess.check_output(['git', '-C', str(SOURCE), *args], text=True).strip()


def replace(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f'Expected one occurrence of {old!r}')
    return text.replace(old, new)


def initialized(text, filename, array, width, count, binary=False):
    raw = (SOURCE / 'rtl' / filename).read_text()
    raw = re.sub(r'/\*.*?\*/|//[^\n]*', '', raw, flags=re.S)
    words = raw.split()
    if len(words) != count or any(not re.fullmatch('[01]+' if binary else '[0-9a-fA-F]+', w) for w in words):
        raise ValueError(f'Unexpected CPU/chip table: {filename}')
    base = 'b' if binary else 'h'
    initial = 'begin\n' + '\n'.join(f"    {array}[{i}] = {width}'{base}{w};" for i, w in enumerate(words)) + '\nend'
    return replace(text, f'$readmem{"b" if binary else "h"}("{Path(filename).name}",{array});' if binary else
                   f'$readmemh("{Path(filename).name}", {array});', initial)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--check', action='store_true')
    args = p.parse_args()
    if git('status', '--porcelain', '--untracked-files=all'):
        raise SystemExit('Speech source clone must be clean')
    commit = git('rev-parse', 'HEAD')
    manifest = ROOT / 'scripts/import_speech.txt'
    if args.check:
        if f'Commit: {commit}\n' not in manifest.read_text():
            raise SystemExit('Speech source revision differs')
    else:
        official = subprocess.check_output(['git', 'ls-remote', '--symref',
            'https://github.com/MiSTer-devel/Arcade-MCR3_MiSTer.git', 'HEAD'], text=True)
        base = subprocess.check_output(['git', '-C', str(ROOT.parent / 'Arcade-MCR3_MiSTer'), 'rev-parse', 'HEAD'], text=True).strip()
        if f'{base}\tHEAD' not in official:
            raise SystemExit('Refresh official MCR3 base first')
        remote = subprocess.check_output(['git', 'ls-remote', URL, f'refs/heads/{BRANCH}'], text=True)
        if not remote.startswith(commit + '\t'):
            raise SystemExit('Refresh speech branch first')
    if (SOURCE / 'rtl/pia6821.vhd').read_bytes() != (ROOT.parent / 'Arcade-MCR3Mono_MiSTer/rtl/pia6821.vhd').read_bytes():
        raise SystemExit('Shared PIA differs')
    outputs = {}
    for path in sorted((SOURCE / 'rtl/jt680x').glob('*.v')):
        text = path.read_text()
        if path.stem == 'jt680x_ctrl':
            # The generated control file uses these before their upstream
            # declarations. Xsim rejects the implicit nets; Gowin truncates
            # jsr_sel to one bit. Declare the real widths before expansion.
            declarations = "wire [4:0] jsr_sel;\nreg  [2:0] iv_sel;\nwire       halt, swi, ni, still;"
            text = replace(text, declarations, '')
            text = replace(text, '`include "6801.vh"', declarations + '\n`include "6801.vh"')
        for name in ('6801_param.vh', '6801.vh'):
            text = text.replace(f'`include "{name}"', (SOURCE / 'rtl/jt680x' / name).read_text())
        if path.stem == 'jt680x_ctrl':
            text = initialized(text, 'jt680x/6801.uc', 'ucode_rom', 40, 4096, True)
        text = re.sub(r'`ifdef SIMULATION\n.*?`endif', '', text, flags=re.S)
        outputs[ROOT / 'rtl/speech' / path.name] = text
    for path in sorted((SOURCE / 'rtl/tms5200').glob('*.v')):
        text = path.read_text()
        # Vivado gives otherwise uninitialized flops/SRLs an INIT of zero.
        # Make that existing FPGA startup state explicit for four-state sim;
        # the serial lattice otherwise feeds X into the reconstruction IIR.
        # Preserve explicit initializers, including the all-ones noise LFSR,
        # and the separately initialized coefficient/chirp ROM arrays.
        def powerup(match):
            prefix, variables = match.groups()
            if '[' in variables:
                if path.stem in ('tms5200_prom','tms5200_crom') and variables.startswith('data '):
                    return match.group(0)
                if path.stem == 'tms5200_multiplier' and variables.strip() == 'mr_out [1:3]':
                    return match.group(0) + '\n   initial begin mr_out[1]=0; mr_out[2]=0; mr_out[3]=0; end'
                raise ValueError(f'Unexpected register array: {variables}')
            return prefix + ', '.join(v.strip() if '=' in v else v.strip() + ' = 0' for v in variables.split(',')) + ';'
        text = re.sub(r'(^[ \t]*reg[ \t]+(?:\[[^\]\n]+\][ \t]*)?)([^;\n]+);', powerup, text, flags=re.M)
        if path.stem == 'tms5200_crom':
            text = initialized(text, 'tms5200/tms5200_chirp_rom.hex', 'data', 8, 52)
        if path.stem == 'tms5200_prom':
            text = initialized(text, 'tms5200/tms5200_parameter_rom.hex', 'data', 10, 272)
        outputs[ROOT / 'rtl/speech' / path.name] = text
    text = (SOURCE / 'rtl/squawk_n_talk.sv').read_text()
    text = re.sub(r'`ifdef SNT_JTAG_PROBE\n.*?`endif[^\n]*', '', text, flags=re.S)
    outputs[ROOT / 'rtl/speech/squawk_n_talk.sv'] = text
    for path, text in outputs.items():
        if re.search(r'^\s*`(?:include|define|ifdef|else|endif)', text, re.M) or '$readmem' in text:
            raise ValueError(f'Unexpanded dependency: {path}')
    # Only retain game descriptions/recipes, not the branch's inline artwork.
    tree = ET.parse(SOURCE / 'releases/Discs of Tron (Environmental).mra')
    root = tree.getroot()
    for element in list(root):
        if element.tag == 'rom' and element.get('index') not in ('0', '1'):
            root.remove(element)
        if element.tag == 'nvram':
            root.remove(element)
    root.find("rom[@index='0']").set('md5', MD5)
    ET.indent(tree, space='  ')
    outputs[ROOT / 'gamedb/mra/Discs of Tron (Environmental).mra'] = ET.tostring(root, encoding='unicode') + '\n'
    if not args.check:
        outputs[manifest] = f'Upstream: {URL}\nBranch: {BRANCH}\nCommit: {commit}\nVerified UTC: {datetime.now(timezone.utc).date()}\nPatches: inline jt680x includes and CPU/chip control tables; declare CPU control nets before use; explicit TMS FPGA-zero power-up state, preserving existing initializers/tables; omit Altera JTAG probes; MRA index-0 MD5 verified locally, omit backdrop/artwork and unused file slots.\nShared PIA: byte-identical to official MCR3 Mono source.\n'
    for path, text in outputs.items():
        if args.check:
            if path.read_text() != text:
                raise SystemExit(f'Import differs: {path}')
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
    print(f'{"Verified" if args.check else "Imported"} speech board and Environmental recipe')


if __name__ == '__main__':
    main()
