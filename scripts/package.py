#!/usr/bin/env python3
"""Stage a local hardware-test SD-card folder; excludes ROMs and PROM data."""
import argparse
import hashlib
import json
import zipfile
import zlib
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zip", type=Path, help="write a private SD-card test ZIP")
    parser.add_argument("--roms", type=Path, help="local folder containing the catalog ROMs and ssio.prom")
    args = parser.parse_args()
    if bool(args.zip) != bool(args.roms):
        parser.error("Use --zip and --roms together for the private test bundle")
    metadata = json.loads((ROOT / "metadata/core.json").read_text())
    core_id = metadata["metadata"]["id"]
    bit_name = metadata["bitstreams"][0]["filename"]
    build = ROOT / "build/MCR3-gamebub_rev4"
    bit = build / bit_name
    if not bit.is_file():
        raise SystemExit("Build the rev 4 core first")
    # Do not silently stage an earlier bitstream after editing the hardware.
    sources = [*ROOT.glob("rtl/**/*"), *ROOT.glob("chisel/src/**/*"), ROOT / "build.mill",
               *ROOT.glob("framework/src/**/*.scala"), *ROOT.glob("framework/verilog/**/*"),
               ROOT / "framework/package.mill", ROOT / "framework/scripts/build_core.py"]
    if any(p.is_file() and p.stat().st_mtime > bit.stat().st_mtime for p in sources):
        raise SystemExit("Bitstream is older than its sources; rebuild first")
    report = build / "MCR3-gamebub_rev4.runs/impl_1/top_handheld_timing_summary_routed.rpt"
    if not report.is_file() or "All user specified timing constraints are met." not in report.read_text():
        raise SystemExit("A passing routed timing report is required")
    stage = ROOT / "build/sdcard/cores" / core_id
    stage.mkdir(parents=True, exist_ok=True)
    for name in ("core.json", "files.json", "settings.json"):
        shutil.copyfile(ROOT / "metadata" / name, stage / name)
    shutil.copyfile(bit, stage / bit_name)
    print(f"Local hardware-test folder: {stage}")
    print("Copy your ssio.prom into that folder, then select a supported MCR ROM at launch.")
    if not args.zip:
        print("Staging folder contains only the core and metadata.")
        return
    sources = [(stage / name, f"cores/{core_id}/{name}") for name in
               ("core.json", "files.json", "settings.json", bit_name)]
    games = json.loads((ROOT / "gamedb/games.json").read_text())
    for game in games:
        path = args.roms / (game["key"] + ".rom")
        data = path.read_bytes()
        if len(data) != game["size"] or zlib.crc32(data) != int(game["crc32"], 16):
            raise SystemExit(f"Unexpected {game['key']} ROM size/CRC")
        sources.append((path, f"roms/MCR/{game['name']}.rom"))
    prom = args.roms / "ssio.prom"
    if hashlib.sha256(prom.read_bytes()).hexdigest() != "4962a47f67ce0cebc655026efed495eb17fc29e7072650ecab2cecc4f16c06dc":
        raise SystemExit("Unexpected SSIO timing PROM")
    sources.append((prom, f"cores/{core_id}/ssio.prom"))
    instructions = """Combined MCR Game Bub rev 4 - private hardware test

Extract this ZIP at the root of your Game Bub SD card. Merge cores/ and
roms/ with the existing folders. Launch Bally Midway MCR (alanswx.MCR).
This installs beside the proven Bally Midway MCR3 core (alanswx.MCR3).

Choose any of the ten game ROMs in roms/MCR.
ROM recognition selects MCR2 or MCR3 and the controls automatically.
The required sound PROM is already in the core folder.

All: Select coin, Start player 1. Landscape games use D-pad movement.
Tapper: A fill, R player 2 start (alternating).
Timber: A axe right, B axe left. Single-player controls only.
Domino Man: A swat, R player 2 start (alternating).
Satan's Hollow: Left/right move, A fire, B shield, R player 2 start.
Portrait games defaults to Upright: normal grip, tall picture with side borders.
Hold sideways (CW): turn the Bub clockwise; Down/Up become screen left/right.
Hold sideways (CCW): turn counterclockwise, joypad at bottom; Up/Down move left/right.
The firmware menu keeps its normal orientation. Allow a few seconds for
Satan's Hollow's startup memory/color tests and delayed restart.
Picture defaults to 4:3. Startup double-reset correction is included.
Version 0.4.0 adds all ten official MCR2/MCR3 MRA game sets.
Tron: D-pad move, A fire, L/R spinner. Start+R starts player 2.
Two Tigers (Tron Conversion): Left/Right turn, A shoot, B bomb, X dogfight.
L/R also turn; Start+R starts player 2. Player 2's controls are inactive.
Wacko: D-pad trackball, A right/B down/X up/Y left to shoot.
Kozmik Krooz'r: D-pad ship, A fire, B shield, L/R turret; Start+R starts P2.
Discs of Tron: D-pad move, A toss, B deflect, X/Y aim up/down, L/R rotate.
Start+R starts player 2 in Discs of Tron.
Journey: D-pad move, A fire, R start player 2. Normal sound is included;
the separate Separate Ways music sample is not implemented yet.
Portrait settings apply to Satan's Hollow, Tron and Journey.
It retains MCR2's corrected 18-source-pixel horizontal capture delay
and restores the MCR2 one-second delayed restart.

Tapper, Timber, and Domino Man worked in the previous hardware-confirmed build.
The previous portrait picture looks good on device; the new CCW grip needs testing.
It uses a local, optional framework rotation change; it is a private test.
High scores are not saved. MCR1, scrolling games, and MCR3 Mono are not
included yet. New games need hardware gameplay checks. Other ROM revisions are not recognized.

This private test bundle includes your local ROM data. Do not publish it.
"""
    args.zip.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(args.zip, "w", zipfile.ZIP_DEFLATED) as archive:
        for src, name in sources:
            archive.write(src, name)
        archive.writestr("MCR-INSTALL.txt", instructions)
        archive.writestr("MCR-SHA256SUMS.txt", "".join(
            f"{hashlib.sha256(src.read_bytes()).hexdigest()}  {name}\n" for src, name in sources))
    with zipfile.ZipFile(args.zip) as archive:
        if archive.testzip() is not None:
            raise SystemExit("ZIP integrity check failed")
        for src, name in sources:
            if archive.read(name) != src.read_bytes():
                raise SystemExit(f"ZIP verification failed: {name}")
    print(f"Verified private SD-card ZIP: {args.zip.resolve()}")


if __name__ == "__main__":
    main()
