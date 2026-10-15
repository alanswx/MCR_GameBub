#!/usr/bin/env python3
"""Stage a local hardware-test SD-card folder; excludes ROMs and PROM data."""
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]


def main():
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
    print("Copy your ssio.prom into that folder, and select your Tapper ROM at launch.")
    print("No ROM data was included. Publication/licensing approval is still pending.")


if __name__ == "__main__":
    main()
