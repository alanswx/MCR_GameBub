# Bally Midway MCR for Game Bub

Work in progress: the first target is **Tapper on Game Bub rev 4**, from
Dar's MiSTer MCR3 core. Other MCR3 games and the MCR1/MCR2/MCR3 Mono boards
are planned. See [the port plan](docs/PORT_PLAN.md) for scope and current
validation. The first hardware test ran Tapper after a manual Reset; the
startup-reset correction still needs a cold-launch hardware test.

The baseline uses the unmodified Game Bub framework, SRAM for sound and
sprite ROMs, and 320×240 video with either 4:3 stretching or native-width
black borders. Select inserts a coin, Start starts player 1, R starts
player 2, A fills, and the d-pad moves. High scores are not yet saved.

## Local ROM preparation

No game ROMs or sound PROM data are included. Supply your own Tapper set.
Build sebdel's `mra-tools-c` in the sibling directory and clone
`MiSTer-devel/Arcade-MCR3_MiSTer` there as described in `CLAUDE.md`.

```sh
python3 tools/prepare_tapper.py \
  --zip /path/to/tapper.zip \
  --prom-vhdl ../Arcade-MCR3_MiSTer/rtl/midssio_82s123.vhd
```

This runs `mra -A` on the upstream Tapper MRA, checks the assembled ROM's
size and MD5, and writes `scratch/roms/tapper.rom` and `ssio.prom`.
Alternatively pass `--prom /path/to/ssio.prom` for an existing 32-byte
SSIO timing PROM. The PROM is separate from the MRA's index-0 ROM; it must
be loaded for sound to function. These files stay out of Git.

## Validation and build

```sh
source scripts/env.sh
python3 scripts/import_mcr.py --check
scripts/lint.sh --test
python3 sim/run_tb.py --frames 120 --dump 30
./mill root.buildCore --target gamebub_rev4
```

The mixed-language tests use Vivado Xsim and simulate both Z80s and the
sound chips. The full-core test uses a functional 40 MHz clock; lint and
FPGA implementation check the production MMCM. Captured images are PPMs
under `scratch/tapper-frames`. `--aspect 0` selects native width;
`--coin 120 --start 140 --frames 300` exercises starting a game.

Xsim and Mill use local IPC and may require execution outside a restricted
sandbox. For Xsim, `--compile-only` and `--run-only` separate compilation
from simulation. A simulator exit code alone is insufficient: the runners
also require their testbench success marker.

The experimental `--backend verilator` uses GHDL 4.1 conversion and
Verilator 5.052, but has shown boot differences from Xsim. Use Xsim for
validation until that discrepancy is resolved.

The bitstream is
`build/MCR3-gamebub_rev4/MCR3-gamebub_rev4.bit`. No packaged release is
available yet. Once the build passes routed timing, stage a local hardware
test with `python3 scripts/package.py`. Copy `build/sdcard/cores/alanswx.MCR3`
to your SD card's `cores/` folder and put your `ssio.prom` inside it. Choose
your `tapper.rom` when launching the core.

Upstream licence notices are retained; publication and the
repository licence remain to be settled with the owner.
