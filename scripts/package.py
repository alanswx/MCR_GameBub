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
    parser.add_argument("--roms", type=Path, help="local folder with tapper.rom, timber.rom, ssio.prom")
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
    sources = [*ROOT.glob("rtl/**/*"), *ROOT.glob("chisel/src/**/*"), ROOT / "build.mill"]
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
    print("Copy your ssio.prom into that folder, then select a supported MCR3 ROM at launch.")
    if not args.zip:
        print("Staging folder contains only the core and metadata.")
        return
    sources = [(stage / name, f"cores/{core_id}/{name}") for name in
               ("core.json", "files.json", "settings.json", bit_name)]
    for name, checksum in (("tapper", 0x0f584827), ("timber", 0x3f49e94e)):
        path = args.roms / (name + ".rom")
        data = path.read_bytes()
        if len(data) != 0x3a000 or zlib.crc32(data) != checksum:
            raise SystemExit(f"Unexpected {name} ROM size/CRC")
        sources.append((path, f"roms/MCR3/{name.title()}.rom"))
    prom = args.roms / "ssio.prom"
    if hashlib.sha256(prom.read_bytes()).hexdigest() != "4962a47f67ce0cebc655026efed495eb17fc29e7072650ecab2cecc4f16c06dc":
        raise SystemExit("Unexpected SSIO timing PROM")
    sources.append((prom, f"cores/{core_id}/ssio.prom"))
    instructions = """MCR3 Game Bub rev 4 - private hardware test

Extract this ZIP at the root of your Game Bub SD card. Merge cores/ and
roms/ with the existing folders, replacing the alanswx.MCR3 core files.
Existing settings and other cores are not included or overwritten.

Launch Bally Midway MCR3. Select Tapper.rom or Timber.rom in roms/MCR3.
The core recognizes the game automatically; there is no game setting.
The required sound PROM is already in the core folder.

Both: D-pad move, Select coin, Start player 1.
Tapper: A fill, R player 2 start (alternating).
Timber: A axe right, B axe left. Single-player controls only in this build.
Picture defaults to 4:3. The startup double-reset correction is included.

Tapper picture, controls, and sound worked on hardware after manual Reset
in the previous build. This update's automatic startup and Timber still
need hardware testing. High scores are not saved yet. Other MCR games
and other ROM revisions are not recognized by this test build.

This private test bundle includes your local ROM data. Do not publish it.
"""
    args.zip.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(args.zip, "w", zipfile.ZIP_DEFLATED) as archive:
        for src, name in sources:
            archive.write(src, name)
        archive.writestr("MCR3-INSTALL.txt", instructions)
        archive.writestr("MCR3-SHA256SUMS.txt", "".join(
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
