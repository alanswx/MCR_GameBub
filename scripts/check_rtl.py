#!/usr/bin/env python3
"""Mixed-language compile/elaboration; --test also runs platform regressions."""
import argparse
import os
from pathlib import Path
import subprocess
from import_mcr import FILES, ROOT


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--test", action="store_true")
    args = parser.parse_args()
    subprocess.run(["python3", str(ROOT / "tools/generate_gamedb.py"), "--check"], check=True)
    work = ROOT / "build/check"
    work.mkdir(parents=True, exist_ok=True)

    def run(name, command):
        log = work / f"{name}.log"
        with log.open("w") as output:
            result = subprocess.run(command, cwd=work, stdout=output, stderr=subprocess.STDOUT)
        if result.returncode:
            print(log.read_text()[-12000:])
            raise SystemExit(f"{name} failed: {log}")
        print(f"{name}: passed ({log.relative_to(ROOT)})", flush=True)

    run("vhdl", ["xvhdl", *[str(ROOT / "rtl/mcr3" / Path(f).with_suffix(".vhdl")) for f in FILES], str(ROOT / "rtl/mcr2/mcr2.vhdl")])
    sv = sorted(str(p) for p in (ROOT / "rtl/gamebub").glob("*.sv"))
    run("sv", ["xvlog", "--sv", *sv, str(Path(os.environ["XILINX_VIVADO"]) / "data/verilog/src/glbl.v")])
    run("elaborate", ["xelab", "-L", "unisims_ver", "-L", "unimacro_ver",
                       "--timescale", "1ns/1ps", "work.mcr3_gamebub", "work.glbl", "-s", "mcr3_check"])
    if args.test:
        run("test_compile", ["xvlog", "--sv", str(ROOT / "sim/tb_platform.sv")])
        run("test_elaborate", ["xelab", "--timescale", "1ns/1ps", "work.tb_platform", "-s", "platform_test"])
        run("test_run", ["xsim", "platform_test", "--runall"])
        if "PLATFORM PASS" not in (work / "test_run.log").read_text():
            raise SystemExit("Platform test did not reach its success marker")
        run("raster_compile", ["xvlog", "--sv", str(ROOT / "sim/tb_mcr2_raster.sv")])
        run("raster_elaborate", ["xelab", "--timescale", "1ns/1ps", "work.tb_mcr2_raster", "-s", "mcr2_raster_test"])
        run("raster_run", ["xsim", "mcr2_raster_test", "--runall"])
        if "MCR2 RASTER PASS" not in (work / "raster_run.log").read_text():
            raise SystemExit("MCR2 raster test did not reach its success marker")
        run("inputs_compile", ["xvlog", "--sv", str(ROOT / "sim/tb_mcr2_inputs.sv")])
        run("inputs_elaborate", ["xelab", "--timescale", "1ns/1ps", "work.tb_mcr2_inputs", "-s", "mcr2_inputs_test"])
        run("inputs_run", ["xsim", "mcr2_inputs_test", "--runall"])
        if "MCR2 INPUT PASS" not in (work / "inputs_run.log").read_text():
            raise SystemExit("MCR2 input test failed")
        run("controls_compile", ["xvlog", "--sv", str(ROOT / "sim/tb_mcr_controls.sv")])
        run("controls_elaborate", ["xelab", "--timescale", "1ns/1ps", "work.tb_mcr_controls", "-s", "mcr_controls_test"])
        run("controls_run", ["xsim", "mcr_controls_test", "--runall"])
        if "MCR CONTROLS PASS" not in (work / "controls_run.log").read_text():
            raise SystemExit("MCR control test failed")
        run("family_reset_build", ["verilator", "--binary", "--timing", "-j", "8", "-O3",
            "-Wno-fatal", "-Wno-lint", "-Wno-style", "--top-module", "tb_reset_families",
            "--Mdir", str(work / "reset_obj"), str(ROOT / "rtl/gamebub/gb_mcr_reset.sv"),
            str(ROOT / "sim/tb_reset_families.sv")])
        run("family_reset_run", [str(work / "reset_obj/Vtb_reset_families")])
        if "FAMILY RESET PASS" not in (work / "family_reset_run.log").read_text():
            raise SystemExit("Family restart timing test failed")
    print("Combined MCR mixed-language checks passed.")


if __name__ == "__main__":
    main()
