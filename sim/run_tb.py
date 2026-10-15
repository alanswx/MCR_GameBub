#!/usr/bin/env python3
"""Run the combined MCR core in Xsim with local ROMs; no ROM data is included.

Source scripts/env.sh first. Paths are relative to the repository root.
Use --compile-only followed by --run-only if the simulator needs permissions
that the compiler does not (Xsim uses local IPC unavailable in some sandboxes).
"""
import argparse
from pathlib import Path
import subprocess
import sys
import zlib

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from check_rtl import main as check_rtl


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--trace-cpu", action="store_true")
    p.add_argument("--backend", choices=("xsim", "verilator"), default="xsim")
    p.add_argument("--rom", type=Path, default=Path("scratch/roms/tapper.rom"))
    p.add_argument("--prom", type=Path, default=Path("scratch/roms/ssio.prom"))
    p.add_argument("--out", type=Path, default=Path("scratch/tapper-frames"))
    p.add_argument("--frames", type=int, default=120)
    p.add_argument("--dump", type=int, default=30)
    p.add_argument("--portrait-sideways", type=int, choices=(0, 1), default=0)
    p.add_argument("--aspect", type=int, choices=(0, 1), default=1)
    p.add_argument("--coin", type=int, default=-1)
    p.add_argument("--start", type=int, default=-1)
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--compile-only", action="store_true")
    mode.add_argument("--run-only", action="store_true")
    args = p.parse_args()
    if args.frames < 1 or args.dump < 1:
        p.error("frames and dump must be positive")
    work = ROOT / ("build/check" if args.backend == "xsim" else "build/fast")
    work.mkdir(parents=True, exist_ok=True)

    def run(name, command):
        log = work / (name + ".log")
        with log.open("w") as f:
            result = subprocess.run(command, cwd=work, stdout=f, stderr=subprocess.STDOUT)
        if result.returncode:
            print(log.read_text()[-8000:])
            raise SystemExit(f"{name} failed: {log}")
        print(f"{name}: {log}", flush=True)
        return log.read_text()

    if not args.run_only and args.backend == "verilator":
        from fast_backend import build
        build(work, run)
    if not args.run_only and args.backend == "xsim":
        saved = sys.argv
        try:
            sys.argv = [saved[0]]
            check_rtl()
        finally:
            sys.argv = saved
        run("game_compile", ["xvlog", "--sv", str(ROOT / "sim/gb_clocks.sv"),
            str(ROOT / "sim/tb_gamebub.sv")])
        run("game_elaborate", ["xelab", "-L", "unisims_ver", "-L", "unimacro_ver",
            "--timescale", "1ns/1ps", "work.tb_gamebub", "work.glbl", "-s", "gamebub_test"])
    if args.compile_only:
        return
    for name, sizes in (("rom", (0x1c000, 0x3a000)), ("prom", (32,))):
        path = (ROOT / getattr(args, name)).resolve()
        if not path.is_file() or path.stat().st_size not in sizes:
            p.error(f"{name} must be a file of size {sizes}: {path}")
        setattr(args, name, path)
    args.out = (ROOT / args.out).resolve()
    args.out.mkdir(parents=True, exist_ok=True)
    command = (["xsim", "gamebub_test", "--runall"] if args.backend == "xsim"
               else [str(work / "obj/Vtb_gamebub")])
    for name in ("rom", "prom", "out", "frames", "dump", "aspect", "coin", "start", "portrait_sideways"):
        argument = f"{name}={getattr(args, name)}"
        command += ["--testplusarg", argument] if args.backend == "xsim" else ["+" + argument]
    if args.trace_cpu:
        command += ["--testplusarg", "trace_cpu"] if args.backend == "xsim" else ["+trace_cpu"]
    checksum = zlib.crc32(args.rom.read_bytes())
    known_games = {0x0f584827: (0, 0), 0x3f49e94e: (1, 0), 0x085cde56: (5, 1), 0xa2403144: (0, 1)}
    if checksum not in known_games:
        p.error(f"Unsupported ROM CRC {checksum:08x}")
    for argument in (f"expected_game={known_games[checksum][0]}", f"expected_family={known_games[checksum][1]}", f"expected_crc={checksum:08x}"):
        command += ["--testplusarg", argument] if args.backend == "xsim" else ["+" + argument]
    output = run("game_run", command)
    print(output[-4000:])
    if "GAMEBUB PASS" not in output:
        raise SystemExit("Simulation did not reach its success marker")


if __name__ == "__main__":
    main()
