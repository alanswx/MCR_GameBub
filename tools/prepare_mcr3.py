#!/usr/bin/env python3
"""Build local MCR2/MCR3 game files with mra-tools-c; never downloads ROM data.

The timing PROM comes from a user-supplied binary or the locally cloned
upstream VHDL initializer, which is deliberately omitted from imported RTL.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    games = {g["key"]: g for g in json.loads((ROOT / "gamedb/games.json").read_text())}
    p.add_argument("--game", choices=tuple(games), default="tapper")
    p.add_argument("--zip", type=Path, required=True, help="local MAME zip")
    p.add_argument("--mra-tool", type=Path, default=ROOT.parent / "mra-tools-c/mra")
    p.add_argument("--mra", type=Path, default=None)
    prom = p.add_mutually_exclusive_group(required=True)
    prom.add_argument("--prom", type=Path, help="32-byte SSIO timing PROM")
    prom.add_argument("--prom-vhdl", type=Path, help="local upstream midssio_82s123.vhd")
    p.add_argument("--out", type=Path, default=ROOT / "scratch/roms")
    args = p.parse_args()
    game = games[args.game]
    if args.mra is None:
        args.mra = (ROOT / game['mra_local']) if game.get('mra_local') else ROOT.parent / f"Arcade-MCR{game['family']}_MiSTer/releases" / game["mra"]
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
    description = ET.parse(args.mra)
    rom = description.find("rom[@index='0']")
    if rom is None or rom.get("md5") != game["md5"]:
        p.error("MRA does not match the selected game")
    args.out.mkdir(parents=True, exist_ok=True)
    # Use a private staging directory so existing user ROM sets are untouched.
    import tempfile
    with tempfile.TemporaryDirectory(prefix="mra-", dir=args.out) as stage:
        stage = Path(stage)
        shutil.copyfile(args.mra, stage / "game.mra")
        for filename in rom.get("zip").split("|"):
            (stage / filename).symlink_to(args.zip.resolve(strict=True))
        subprocess.run([str(args.mra_tool.resolve()), "-A", "game.mra"], cwd=stage, check=True)
        assembled = list(stage.glob("*.rom"))
        if len(assembled) != 1:
            p.error("MRA tool did not produce exactly one ROM")
        result = assembled[0].read_bytes()
        if len(result) != game["size"] or hashlib.md5(result).hexdigest() != rom.get("md5"):
            p.error("Assembled ROM size or MRA MD5 mismatch")
        (args.out / (args.game + ".rom")).write_bytes(result)
    (args.out / "ssio.prom").write_bytes(data)
    print(f"Verified {args.game} ROM and wrote SSIO PROM to {args.out}")


if __name__ == "__main__":
    main()
