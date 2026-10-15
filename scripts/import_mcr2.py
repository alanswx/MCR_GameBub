#!/usr/bin/env python3
"""Import the current official MCR2 board, sharing the verified MCR3 primitives."""
import argparse
from datetime import datetime, timezone
from pathlib import Path
import subprocess
import re
from import_mcr import ROOT, FILES, PROM_PORTS, git, replace

URL = 'https://github.com/MiSTer-devel/Arcade-MCR2_MiSTer.git'

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--check', action='store_true')
    args = p.parse_args()
    src = ROOT.parent / 'Arcade-MCR2_MiSTer'
    if git(src, 'status', '--porcelain', '--untracked-files=all'):
        raise SystemExit('Source clone is dirty')
    commit = git(src, 'rev-parse', 'HEAD')
    manifest = ROOT / 'scripts/import_mcr2.txt'
    if args.check:
        if f'Commit: {commit}\n' not in manifest.read_text():
            raise SystemExit('Source revision differs')
    else:
        remote = subprocess.check_output(['git', 'ls-remote', '--symref', URL, 'HEAD'], text=True)
        if f'{commit}\tHEAD' not in remote:
            raise SystemExit('Update clean upstream clone to live HEAD before importing')
    # Check shared dependencies against the source of the working MCR3 import.
    for name in FILES:
        if name in ('mcr3.vhd', 'midssio_82s123.vhd'):
            continue
        if (src / 'rtl' / name).read_bytes() != (ROOT.parent / 'Arcade-MCR3_MiSTer/rtl' / name).read_bytes():
            raise SystemExit(f'Shared source differs: {name}')
    # Both boards use the same SSIO PROM; only its VHDL formatting differs.
    def prom_bytes(path):
        match = re.search(r'signal\s+rom_data:\s*rom\s*:=\s*\((.*?)\);', path.read_text(), re.S | re.I)
        if not match:
            raise SystemExit('Unrecognized SSIO PROM source')
        return bytes(int(v, 16) for v in re.findall(r'X"([0-9a-f]{2})"', match[1], re.I))
    if prom_bytes(src / 'rtl/midssio_82s123.vhd') != prom_bytes(ROOT.parent / 'Arcade-MCR3_MiSTer/rtl/midssio_82s123.vhd'):
        raise SystemExit('MCR2 needs a different SSIO timing PROM')
    text = (src / 'rtl/mcr2.vhd').read_text()
    text = replace(text, 'port(\n', 'port(\n' + PROM_PORTS)
    text = replace(text, 'sound_board : entity work.mcr_sound_board\nport map(\n',
                   'sound_board : entity work.mcr_sound_board\nport map(\n prom_addr => prom_addr,\n prom_data => prom_data,\n prom_wr => prom_wr,\n')
    declarations = 'signal gb_ctc_ce_n, gb_nvram_we : std_logic;\nsignal gb_palette_data : std_logic_vector(8 downto 0);\nsignal gb_sprite_addr : std_logic_vector(14 downto 0);\n'
    text = replace(text, 'architecture struct of mcr2 is', 'architecture struct of mcr2 is\n' + declarations)
    assignments = ''
    for expression, signal in [('not ctc_ce', 'gb_ctc_ce_n'), ('(dl_wr or dl_nvram_wr) and dl_nvram', 'gb_nvram_we'), ('cpu_addr(0) & cpu_do', 'gb_palette_data'), ('not dl_addr(14) & dl_addr(13 downto 0)', 'gb_sprite_addr')]:
        text = replace(text, '=> ' + expression + ',', '=> ' + signal + ',')
        assignments += signal + ' <= ' + expression + ';\n'
    text = replace(text, '-- Z80-CTC (MK3882)', assignments + '-- Z80-CTC (MK3882)')
    # Port the Tang merge's progressive 512x480 window. The MiSTer window
    # is only 478 active lines and cannot fill Game Bub's 240-line capture.
    text = replace(text, "if hcnt >= 2+16 and  hcnt < 514+16 and\n\t\t\t\t\tvcnt >= 2 and  vcnt < 481 then video_hblank <= '0';", "if hcnt < 512 then video_hblank <= '0';")
    text = replace(text, "if vcnt >= 2 and vcnt < 480 then", "if vcnt < 480 then")
    dest = ROOT / 'rtl/mcr2/mcr2.vhdl'
    if args.check:
        if dest.read_text() != text:
            raise SystemExit('Imported MCR2 differs')
    else:
        dest.parent.mkdir(exist_ok=True)
        dest.write_text(text)
        manifest.write_text(f'Upstream: {URL}\nCommit: {commit}\nVerified UTC: {datetime.now(timezone.utc).date()}\nPatches: SD-loaded SSIO PROM; static VHDL-93 port expressions; Tang 512x480 progressive active window (60363fa2a2a5e50e07c48bfe084bb61e00b1d393).\nShared dependencies: byte-identical to verified MCR3 source (except external PROM initializer).\n')
    print('Verified MCR2' if args.check else 'Imported MCR2')

if __name__ == '__main__':
    main()
