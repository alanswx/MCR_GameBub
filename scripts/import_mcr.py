#!/usr/bin/env python3
"""Import MCR3 from live MiSTer-devel HEAD; --check verifies a pinned import offline.

No MiSTer platform, PLL, SDRAM, sample player, ROM images or initialized
sound PROM are copied. Upstream notices are retained. Patches fail closed.
"""
import argparse
from datetime import datetime, timezone
import hashlib
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
URL = "https://github.com/MiSTer-devel/Arcade-MCR3_MiSTer.git"
FILES = [
    "T80/T80_ALU.vhd", "T80/T80_MCode.vhd", "T80/T80_Reg.vhd",
    "T80/T80.vhd", "T80/T80s.vhd",
    "Z80CTC/ctc_controler.vhd", "Z80CTC/ctc_counter.vhd", "Z80CTC/z80ctc_top.vhd",
    "gen_ram.vhd", "dpram.vhd", "YM2149_linmix_sep.vhd",
    "midssio_82s123.vhd", "mcr_sound_board.vhd", "mcr3.vhd",
]


def replace(text, old, new, count=1):
    if text.count(old) != count:
        raise ValueError(f"patch expected {count} matches: {old!r}")
    return text.replace(old, new)


PROM_PORTS = """ prom_addr : in std_logic_vector(4 downto 0);
 prom_data : in std_logic_vector(7 downto 0);
 prom_wr   : in std_logic;
"""


def patch(name, text):
    # Quartus accepts omitted ENTITY on direct instantiations; Vivado does not.
    for unit in {"T80/T80.vhd": ("T80_MCode", "T80_ALU", "T80_Reg"),
                 "T80/T80s.vhd": ("T80",)}.get(name, ()):
        text = replace(text, ": work." + unit + "\n", ": entity work." + unit + "\n")
    if name == "T80/T80.vhd":
        # IEEE logical vector operators require equal operand widths.
        text = replace(text, 'ioq and x"7"', 'ioq and "000000111"')
    if name == "dpram.vhd":
        # Xilinx's dual-clock, write-first RAM template. A signal driven by
        # two processes resolves to X in simulation; a shared variable models
        # the single physical array. Same-address dual writes remain undefined.
        text = replace(text, "signal ram: ramDef;", "shared variable ram: ramDef;")
        text = replace(text, "ATTRIBUTE ramstyle OF ram : SIGNAL", "ATTRIBUTE ramstyle OF ram : VARIABLE")
        text = replace(text, "ram(to_integer(unsigned(addr_a))) <= d_a;", "ram(to_integer(unsigned(addr_a))) := d_a;")
        text = replace(text, "ram(to_integer(unsigned(addr_b))) <= d_b;", "ram(to_integer(unsigned(addr_b))) := d_b;")
    elif name == "midssio_82s123.vhd":
        start = text.index("\tsignal rom_data: rom := (")
        end = text.index(");", start) + 2
        # Digest guards an exact-text removal without embedding ROM bytes here.
        expected = "9a036672462e2c32fccd88216b86ab94f08ff162f432522f7637f01901764936"
        if hashlib.sha256(text[start:end].encode()).hexdigest() != expected:
            raise ValueError("sound PROM initializer changed upstream")
        text = replace(text, text[start:end], "\tsignal rom_data: rom;")
        text = replace(text, "port (\n", "port (\n" + PROM_PORTS)
        text = replace(text, "\t\tdata <= rom_data(to_integer(unsigned(addr)));",
                       "\t\tif prom_wr = '1' then\n"
                       "\t\t\trom_data(to_integer(unsigned(prom_addr))) <= prom_data;\n"
                       "\t\tend if;\n\t\tdata <= rom_data(to_integer(unsigned(addr)));")
    elif name in ("mcr3.vhd", "mcr_sound_board.vhd"):
        text = replace(text, "port(\n", "port(\n" + PROM_PORTS)
        instance = "sound_board : entity work.mcr_sound_board" if name == "mcr3.vhd" else "midssio : entity work.midssio_82s123"
        text = replace(text, instance + "\nport map(\n", instance + "\nport map(\n"
                       " prom_addr => prom_addr,\n prom_data => prom_data,\n prom_wr => prom_wr,\n")
    if name == "mcr3.vhd":
        # VHDL-93 requires static names for these input port actuals.
        text = replace(text, "architecture struct of mcr3 is", "architecture struct of mcr3 is\n"
                       "signal gb_ctc_ce_n, gb_nvram_we : std_logic;\n"
                       "signal gb_palette_data : std_logic_vector(8 downto 0);")
        for expression, signal in (("not ctc_ce", "gb_ctc_ce_n"),
                                   ("(dl_wr or dl_nvram_wr) and dl_nvram", "gb_nvram_we"),
                                   ("cpu_addr(0) & cpu_do", "gb_palette_data")):
            text = replace(text, "=> " + expression + ",", "=> " + signal + ",")
            text = replace(text, "-- Z80-CTC (MK3882)",
                           signal + " <= " + expression + ";\n-- Z80-CTC (MK3882)")
    return text


def git(src, *args):
    return subprocess.check_output(["git", "-C", str(src), *args], text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--src", type=Path, default=ROOT.parent / "Arcade-MCR3_MiSTer")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    src = args.src.resolve()
    if git(src, "status", "--porcelain", "--untracked-files=all"):
        raise SystemExit("Source clone is dirty; preserve its changes before importing.")
    commit = git(src, "rev-parse", "HEAD")
    manifest_path = ROOT / "scripts/import_mcr.txt"
    if args.check:
        manifest = manifest_path.read_text()
        if f"Commit: {commit}\n" not in manifest:
            raise SystemExit("Source HEAD differs from recorded import.")
    else:
        remote = subprocess.check_output(["git", "ls-remote", "--symref", URL, "HEAD"], text=True)
        head = next(line.split()[0] for line in remote.splitlines() if line.endswith("\tHEAD") and not line.startswith("ref:"))
        branch = next(line.split()[1] for line in remote.splitlines() if line.startswith("ref:"))
        if commit != head:
            raise SystemExit(f"Source HEAD {commit} is not live {branch} {head}; update the clean clone first.")
        manifest = (f"Upstream: {URL}\nBranch: {branch}\nCommit: {commit}\n"
                    f"Verified UTC: {datetime.now(timezone.utc).date()}\n"
                    "Patches: explicit T80 ENTITY instantiations and 9-bit I/O parity mask; shared-variable dual-port RAM; static VHDL-93 port signals; SD-loaded SSIO timing PROM.\n"
                    "Omitted: MiSTer top/platform, PLL, SDRAM, sample player, ROM images.\n")
    # Validate every patch before writing any file.
    outputs = {ROOT / "rtl/mcr3" / Path(name).with_suffix(".vhdl"):
               patch(name, (src / "rtl" / name).read_text()) for name in FILES}
    for path, data in outputs.items():
        if args.check:
            if not path.exists() or path.read_text() != data:
                raise SystemExit(f"Import differs: {path.relative_to(ROOT)}")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(data)
    extras = set((ROOT / "rtl/mcr3").rglob("*.*")) - set(outputs)
    if extras:
        raise SystemExit(f"Unexpected imported files: {sorted(extras)}")
    if not args.check:
        manifest_path.write_text(manifest)
    print(f"{'Verified' if args.check else 'Imported'} {len(outputs)} files from {commit}")


if __name__ == "__main__":
    main()
