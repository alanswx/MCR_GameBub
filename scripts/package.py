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
    parser.add_argument("--roms", type=Path, help="local folder with tapper.rom, timber.rom, domino.rom, ssio.prom")
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
    print("Copy your ssio.prom into that folder, then select a supported MCR ROM at launch.")
    if not args.zip:
        print("Staging folder contains only the core and metadata.")
        return
    sources = [(stage / name, f"cores/{core_id}/{name}") for name in
               ("core.json", "files.json", "settings.json", bit_name)]
    for name, checksum in (("tapper", 0x0f584827), ("timber", 0x3f49e94e), ("domino", 0x085cde56)):
        path = args.roms / (name + ".rom")
        data = path.read_bytes()
        if len(data) != (0x1c000 if name == "domino" else 0x3a000) or zlib.crc32(data) != checksum:
            raise SystemExit(f"Unexpected {name} ROM size/CRC")
        sources.append((path, f"roms/MCR/{name.title()}.rom"))
    prom = args.roms / "ssio.prom"
    if hashlib.sha256(prom.read_bytes()).hexdigest() != "4962a47f67ce0cebc655026efed495eb17fc29e7072650ecab2cecc4f16c06dc":
        raise SystemExit("Unexpected SSIO timing PROM")
    sources.append((prom, f"cores/{core_id}/ssio.prom"))
    instructions = """Combined MCR Game Bub rev 4 - private hardware test

Extract this ZIP at the root of your Game Bub SD card. Merge cores/ and
roms/ with the existing folders. Launch Bally Midway MCR (alanswx.MCR).
This installs beside the proven Bally Midway MCR3 core (alanswx.MCR3).

Choose Tapper.rom, Timber.rom, or Domino.rom in roms/MCR.
ROM recognition selects MCR2 or MCR3 and the controls automatically.
The required sound PROM is already in the core folder.

All: D-pad move, Select coin, Start player 1.
Tapper: A fill, R player 2 start (alternating).
Timber: A axe right, B axe left. Single-player controls only.
Domino Man: A swat, R player 2 start (alternating).
Picture defaults to 4:3. Startup double-reset correction is included.
Version 0.2.1 restores MCR2's 18-source-pixel horizontal capture delay.

All three games run on hardware in the combined core. This update corrects
Domino Man's reported horizontal shift; please check its picture alignment.
High scores are not saved. MCR1, scrolling games, and MCR3 Mono are not
included yet. Other ROM revisions are not recognized.

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
