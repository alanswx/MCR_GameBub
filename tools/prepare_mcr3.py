#!/usr/bin/env python3
"""Build local Tapper or Timber test files with mra-tools-c; never downloads ROM data.

The timing PROM comes from a user-supplied binary or the locally cloned
upstream VHDL initializer, which is deliberately omitted from imported RTL.
"""
import argparse
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--game", choices=("tapper", "timber"), default="tapper")
    p.add_argument("--zip", type=Path, required=True, help="local MAME zip")
    p.add_argument("--mra-tool", type=Path, default=ROOT.parent / "mra-tools-c/mra")
    p.add_argument("--mra", type=Path, default=None)
    prom = p.add_mutually_exclusive_group(required=True)
    prom.add_argument("--prom", type=Path, help="32-byte SSIO timing PROM")
    prom.add_argument("--prom-vhdl", type=Path, help="local upstream midssio_82s123.vhd")
    p.add_argument("--out", type=Path, default=ROOT / "scratch/roms")
    args = p.parse_args()
    if args.mra is None:
        name = "Tapper (Budweiser, 840127).mra" if args.game == "tapper" else "Timber.mra"
        args.mra = ROOT.parent / "Arcade-MCR3_MiSTer/releases" / name
    if args.prom:
        data = args.prom.read_bytes()
    else:
        source = args.prom_vhdl.read_text()
        match = re.search(r'signal\s+rom_data:\s*rom\s*:=\s*\((.*?)\);', source, re.S | re.I)
        if not match:
            p.error("SSIO initializer not found")
        data = bytes(int(v, 16) for v in re.findall(r'X"([0-9a-f]{2})"', match[1], re.I))
    if len(data) != 32:
        p.error("SSIO PROM must contain exactly 32 bytes")
    rom = ET.parse(args.mra).find("rom[@index='0']")
    if rom is None or rom.get("zip") != args.game + ".zip":
        p.error("MRA does not match the selected game")
    args.out.mkdir(parents=True, exist_ok=True)
    # Use a private staging directory so existing user ROM sets are untouched.
    import tempfile
    with tempfile.TemporaryDirectory(prefix="mra-", dir=args.out) as stage:
        stage = Path(stage)
        shutil.copyfile(args.mra, stage / "game.mra")
        (stage / (args.game + ".zip")).symlink_to(args.zip.resolve(strict=True))
        subprocess.run([str(args.mra_tool.resolve()), "-A", "game.mra"], cwd=stage, check=True)
        result = (stage / (args.game + ".rom")).read_bytes()
        if len(result) != 0x3a000 or hashlib.md5(result).hexdigest() != rom.get("md5"):
            p.error("Assembled ROM size or MRA MD5 mismatch")
        (args.out / (args.game + ".rom")).write_bytes(result)
    (args.out / "ssio.prom").write_bytes(data)
    print(f"Verified {args.game} ROM and wrote SSIO PROM to {args.out}")


if __name__ == "__main__":
    main()
