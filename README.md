# Bally Midway MCR for Game Bub

Work in progress: **one combined MCR2/MCR3 core on Game Bub rev 4**,
supporting Tapper, Timber, Domino Man, and Satan's Hollow (Set 1). It uses Dar's current MiSTer board
engines and the Tang port's MCR2 full-height video adjustment, while
retaining MiSTer's 18-pixel horizontal pipeline compensation. Choose a
`.rom` from the file browser; CRC32 recognition
selects the correct controls automatically. Supported files are the stock
MRAs' index-0 outputs listed in [gamedb/games.tsv](gamedb/games.tsv).
Unknown or damaged images are rejected instead of using the wrong controls.

Tapper, Timber, and Domino Man are hardware-confirmed to run in the combined core.
Version 0.2.1's corrected Domino Man alignment is also hardware-confirmed;
Tapper and Timber continue to look correct. Automatic ROM recognition and the
double-reset startup fix are retained. See the
[port plan](docs/PORT_PLAN.md) for validation details.

All three games use D-pad movement, Select for coin, and Start for player 1.
Tapper uses A to fill and R for player 2 start. Timber uses A for axe right
and B for axe left; its second joystick is inactive in this build.
Domino Man uses A to swat and R for player 2 start.
Satan's Hollow uses Left/Right, A fire, and B shield. **Portrait games**
defaults to **Upright**, a 360x480 picture with side borders when holding the
Bub normally. **Hold sideways (CW)** fills the landscape game area; turn the
Bub clockwise and use Down/Up for screen left/right. **Hold sideways (CCW)**
turns the picture the other way: turn the Bub counterclockwise, with the
joypad at the bottom, and use Up/Down for screen left/right. Neither sideways
option uses additional image RAM. The menu retains its normal orientation.
The previous portrait build looks good on the device; the new CCW grip
needs a hardware check. Allow a few
seconds for Satan's Hollow's startup memory/color tests and delayed restart.

High scores are not yet saved. MCR1, MCR3Scroll, and MCR3 Mono are not yet
integrated.

The confirmed 0.2.1 baseline uses the unmodified framework. The 0.3.2 test
branch adds an optional frame-buffer read transform with no extra image RAM.
See [the framework design](docs/FRAMEWORK_CHANGES.md). Both use SRAM for sound and sprite ROMs,
and 320×240 video with either 4:3 stretching or native-width black borders.

## Local ROM preparation

No game ROMs or sound PROM data are included. Supply your own game sets.
Build sebdel's `mra-tools-c` in the sibling directory and clone
`MiSTer-devel/Arcade-MCR3_MiSTer` there as described in `CLAUDE.md`.

```sh
python3 tools/prepare_mcr3.py --game tapper \
  --zip /path/to/tapper.zip \
  --prom-vhdl ../Arcade-MCR3_MiSTer/rtl/midssio_82s123.vhd
```

Repeat with `--game timber --zip /path/to/timber.zip` for Timber or
`--game domino --zip /path/to/domino.zip` for Domino Man. Domino Man also
requires the sibling `Arcade-MCR2_MiSTer` source clone. Use
`--game shollow --zip /path/to/shollow.zip` for Satan's Hollow.
This runs `mra -A` on the selected upstream MRA, checks the assembled ROM's
size and MD5, and writes the selected `.rom` and `ssio.prom` under `scratch/roms`.
Alternatively pass `--prom /path/to/ssio.prom` for an existing 32-byte
SSIO timing PROM. The PROM is separate from the MRA's index-0 ROM; it must
be loaded for sound to function. These files stay out of Git.

## Validation and build

```sh
source scripts/env.sh
python3 scripts/import_mcr.py --check
python3 scripts/import_mcr2.py --check
scripts/lint.sh --test
python3 scripts/check_rotation.py --defaults
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

Capture files contain the stored native raster. To preview the LCD's rotated
read path, including scaling and borders:

```sh
python3 sim/render_rotated.py scratch/shollow-reference/frame_0060.ppm \
  --out scratch/shollow-reference/upright.ppm
```

Pass `--hdmi` for the HDMI geometry or `--rotation 0` for sideways play.

The experimental `--backend verilator` uses GHDL 4.1 conversion and
Verilator 5.052, but has shown boot differences from Xsim. Use Xsim for
validation until that discrepancy is resolved.

The bitstream is
`build/MCR3-gamebub_rev4/MCR3-gamebub_rev4.bit`. No packaged release is
available yet. Once the build passes routed timing, stage a local hardware
test with `python3 scripts/package.py`. Copy `build/sdcard/cores/alanswx.MCR`
to your SD card's `cores/` folder (beside the original MCR3 core), put your
`ssio.prom` inside it, and launch **Bally Midway MCR**. Choose
`Tapper.rom`, `Timber.rom`, `Domino.rom`, or `Satan's Hollow.rom` when launching the core.

For a private SD-card ZIP containing your local ROMs and PROM:

```sh
python3 scripts/package.py --roms scratch/roms \
  --zip build/MCR_GameBub_portrait_v0.3.2.zip
```

The ZIP includes only this core, four ROMs, the PROM, installation notes,
and checksums. It leaves existing settings and other cores untouched.
It contains local ROM data and is not a public release.

Upstream licence notices are retained; publication and the
repository licence remain to be settled with the owner.
