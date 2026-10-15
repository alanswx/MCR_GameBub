"""GHDL 4.1 VHDL conversion for the optional Verilator simulation backend."""
from pathlib import Path
import re
import subprocess

from import_mcr import FILES, ROOT


def build(work, run):
    options = ["--std=08", "-frelaxed", "-fsynopsys", "-fexplicit"]
    files = [str(ROOT / "rtl/mcr3" / Path(f).with_suffix(".vhdl")) for f in FILES] + [str(ROOT / "rtl/mcr2/mcr2.vhdl"), str(ROOT / "rtl/mcr1/mcr1.vhdl"),
        *[str(ROOT / "rtl/mcr3mono" / f) for f in ("FX68K/fx68k.vhdl","cpu09l_128a.vhdl","pia6821.vhdl","turbo_cheap_squeak.vhdl","sounds_good.vhdl","mcr3mono.vhdl")]]
    run("ghdl_analyze", ["ghdl", "-a", *options, *files])
    generated = work / "mcr_combined.v"
    chunks = []
    # Namespace each independently synthesized hierarchy. GHDL assigns local
    # generated names, so merging its two outputs without renaming is unsafe.
    for board in ("mcr3", "mcr2", "mcr1", "mcr3mono"):
        raw = work / (board + ".v")
        with raw.open("w") as output, (work / (board + "_ghdl.log")).open("w") as log:
            subprocess.run(["ghdl", "--synth", *options, "--out=verilog", board],
                           cwd=work, stdout=output, stderr=log, check=True)
        chunk = raw.read_text()
        # Keep the mixed-language sound CPU external for Verilator binding.
        chunk = re.sub(r"(?ms)^module fx68k\b.*?^endmodule\s*", "", chunk)
        names = re.findall(r"^module (\w+)", chunk, re.M)
        for name in sorted(names, key=len, reverse=True):
            if name != board and name != "fx68k":
                chunk = re.sub(r"\b" + re.escape(name) + r"\b", board + "__" + name, chunk)
        chunks.append(chunk)
    generated.write_text("\n".join(chunks))
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
    # Verilator requires packed structs when distinct fields have continuous
    # and clocked drivers. These three CPU structs contain only packed bits.
    fx68k = work / "fx68k_sim.sv"
    fx68k.write_text((ROOT / "rtl/mcr3mono/fx68k.sv").read_text().replace("typedef struct {", "typedef struct packed {"))
    # Inactive boards are held in reset and cannot affect selected outputs.
    # Keep their clocks during loading (for download RAM ports), then quiesce
    # them during play. The selected engine retains the exact 40 MHz clock.
    top = work / "mcr3_gamebub_sim.sv"
    top_text = (ROOT / "rtl/gamebub/mcr3_gamebub.sv").read_text()
    for family in range(4):
        before = f".clock_40(clk_sys), .reset(machine_reset || game_family != {family})"
        assert top_text.count(before) == 1
        top_text = top_text.replace(before, f".clock_40(clk_sys && (core_reset || game_family == {family})), .reset(machine_reset || game_family != {family})")
    top.write_text(top_text)
    sv = sorted(str(p) for p in (ROOT / "rtl/gamebub").glob("*.sv") if p.name not in ("gb_clocks.sv", "mcr3_gamebub.sv"))
    run("verilator_build", ["verilator", "--binary", "--timing", "-j", "8", "-O3", "-CFLAGS", "-O3",
        "--no-assert-case", "-Wno-fatal", "-Wno-lint", "-Wno-style", "-Wno-TIMESCALEMOD", "+1364-2005ext+v",
        "--top-module", "tb_gamebub", "--Mdir", str(work / "obj"), "-o", "Vtb_gamebub",
        str(generated), str(fx68k), str(top), *sv, str(ROOT / "sim/gb_clocks.sv"), str(ROOT / "sim/tb_gamebub.sv")])
