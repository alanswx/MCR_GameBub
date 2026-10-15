"""GHDL 4.1 VHDL conversion for the optional Verilator simulation backend."""
from pathlib import Path
import re
import subprocess

from import_mcr import FILES, ROOT


def build(work, run):
    options = ["--std=08", "-frelaxed", "-fsynopsys", "-fexplicit"]
    files = [str(ROOT / "rtl/mcr3" / Path(f).with_suffix(".vhdl")) for f in FILES]
    run("ghdl_analyze", ["ghdl", "-a", *options, *files])
    generated = work / "mcr3.v"
    with generated.open("w") as output, (work / "ghdl_synth.log").open("w") as log:
        subprocess.run(["ghdl", "--synth", *options, "--out=verilog", "mcr3"],
                       cwd=work, stdout=output, stderr=log, check=True)
    # GHDL 4.1 emits a malformed prefixed escaped name and redundant wires
    # where instance-output aliases have the same name as the parent signal.
    # Normalize only generated simulation code, never the imported VHDL.
    text = generated.read_text().replace("u0_\\reg ", "u0_reg ")
    text = text.replace("video_Vblank", "video_vblank")
    seen = set()
    lines = []
    for line in text.splitlines():
        if line.startswith("module "):
            seen.clear()
        if re.fullmatch(r"  wire .*;", line):
            if line in seen:
                continue
            seen.add(line)
        if re.match(r"  assign (\w+) = \1;", line):
            continue
        lines.append(line)
    generated.write_text("\n".join(lines) + "\n")
    sv = sorted(str(p) for p in (ROOT / "rtl/gamebub").glob("*.sv") if p.name != "gb_clocks.sv")
    run("verilator_build", ["verilator", "--binary", "--timing", "-j", "8", "-O3",
        "-Wno-fatal", "-Wno-lint", "-Wno-style", "-Wno-TIMESCALEMOD", "+1364-2005ext+v",
        "--top-module", "tb_gamebub", "--Mdir", str(work / "obj"), "-o", "Vtb_gamebub",
        str(generated), *sv, str(ROOT / "sim/gb_clocks.sv"), str(ROOT / "sim/tb_gamebub.sv")])
