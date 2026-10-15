# Bally Midway MCR for Game Bub

Work in progress: **one combined MCR core on Game Bub rev 4**,
with 18 official MRA game sets across MCR1, MCR2, MCR3 and MCR3 Mono configured. Choose a `.rom` from the
file browser; CRC32 recognition selects the board, controls, DIP defaults
and portrait orientation automatically. Stock MRA index-0 outputs are
listed in [the game catalog](gamedb/games.tsv); [games.json](gamedb/games.json)
is the source for the hardware decoder and preparation/package tools.
Unknown or damaged images are rejected.

Tapper, Timber, Domino Man, and Satan's Hollow are hardware-confirmed.
Both sideways directions and upright portrait video work on the device;
the sideways grip remains awkward. Rotation is complete for now.
Version 0.5.0 enables fourteen more games, which need device gameplay checks.
It retains the corrected Domino Man alignment and startup reset sequence.

Select inserts a coin. Use Start for player 1 unless noted below. Controls are:

| Game | Handheld controls |
|---|---|
| Tapper | D-pad move, A fill, R start player 2 |
| Timber | D-pad move, A axe right, B axe left; player 1 only |
| Domino Man | D-pad move, A swat, R start player 2 |
| Satan's Hollow | Left/Right move, A fire, B shield, R start player 2 |
| Tron | D-pad move, A fire, L/R spinner |
| Two Tigers (Tron Conversion) | Left/Right or L/R turn, A shoot, B bomb, X dogfight; player 1 controls only |
| Wacko | D-pad trackball; A zap right, B down, X up, Y left; R start player 2 |
| Kozmik Krooz'r | D-pad ship, A fire, B shield, L/R turret |
| Discs of Tron | D-pad move, A toss, B deflect, X/Y aim up/down, L/R rotate |
| Journey | D-pad move, A fire, R start player 2 |
| Kick | Left/Right or L/R trackball, A kick, B faster movement; Start+R starts P2 |
| Solar Fox | D-pad move, A fire, B speed/select, also used to start |
| Rampage | D-pad move, A punch/join, B jump |
| Sarge | D-pad single-stick tank steering, A/B weapons |
| Power Drive | L/R wheels, B wheelie, A toggle 2WD/4WD |
| Max RPM | Up throttle, Left/Right steering, A shift up, B shift down |
| Demolition Derby (Mono) | Left/Right or L/R steer, A forward, B reverse; Start+R starts P2 |
| Star Guards | D-pad move, A fire right, B down, X up, Y left |

Tron, Two Tigers, Kozmik Krooz'r and Discs of Tron use **Start+R** for
player 2 start, leaving R available for rotation during play. Spinner and
trackball buttons are substitutes for the arcade controls. Journey has its
normal SSIO sound; its separate *Separate Ways* music sample is not yet
implemented. Discs of Tron uses the upright ROM set, without speech; the
Environmental version's Squawk & Talk board is not implemented. High scores
are not saved. MCR3 Mono provides player 1 controls only. Rampage and Power Drive use
coin and action buttons to join, as on the arcade. Scrolling MCR hardware
is a separate integration.

**Portrait games** applies to Kick, Solar Fox, Satan's Hollow, Tron and Journey. **Upright**
is the default: normal grip and a 360x480 picture with side borders.
**Hold sideways (CW)** fills the landscape game area; turn the Bub clockwise.
**Hold sideways (CCW)** turns it the other way, with the joypad at the bottom.
D-pad directions follow the grip; the firmware menu keeps its normal
orientation. Allow a few seconds for startup memory/color tests and reset.

The confirmed 0.2.1 baseline uses the unmodified framework. This branch
adds an optional framebuffer read transform with no extra image RAM.
See [the framework design](docs/FRAMEWORK_CHANGES.md). The core uses SRAM
for sound and sprite ROMs, and 320×240 video. **Picture → Auto** preserves
MCR1's nearly square original picture and uses 4:3 for the other boards.
Manual 4:3 and native-width overrides remain available.

## Local ROM preparation

No game ROMs or sound PROM data are included. Supply your own game sets.
Build sebdel's `mra-tools-c` in the sibling directory and clone
`MiSTer-devel/Arcade-MCR3_MiSTer` there as described in `CLAUDE.md`.

```sh
python3 tools/prepare_mcr3.py --game tapper \
  --zip /path/to/tapper.zip \
  --prom-vhdl ../Arcade-MCR3_MiSTer/rtl/midssio_82s123.vhd
```

Repeat with `--game` set to `timber`, `domino`, `shollow`, `tron`,
`twotiger`, `wacko`, `kroozr`, `dotron`, `journey`, `kick`, `solarfox`,
`rampage`, `sarge`, `powerdrv`, `maxrpm`, `demoderm` or `stargrds`, supplying that game's
local zip. The MCR2 games need the sibling `Arcade-MCR2_MiSTer` clone too.
MCR1 and Mono games need their respective source clones. Demolition Derby
uses the **MCR-3 Mono Board Version**, `demoderb.zip` or `demoderm.zip`.
Two Tigers uses the **Tron Conversion** set from the merged `twotiger.zip`.
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
python3 scripts/import_remaining.py --check
python3 tools/generate_gamedb.py --check
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

Pass `--hdmi` for HDMI geometry, `--rotation 0` for the CW handheld grip,
or `--rotation 2` for the CCW grip. These numbers describe the framebuffer
transform, rather than the direction you turn the handheld.

The experimental `--backend verilator` uses GHDL 4.1 conversion and
Verilator 5.052, but has shown boot differences from Xsim. Use Xsim for
validation until that discrepancy is resolved.

The bitstream is
`build/MCR3-gamebub_rev4/MCR3-gamebub_rev4.bit`. No packaged release is
available yet. Once the build passes routed timing, stage a local hardware
test with `python3 scripts/package.py`. Copy `build/sdcard/cores/alanswx.MCR`
to your SD card's `cores/` folder (beside the original MCR3 core), put your
`ssio.prom` inside it, and launch **Bally Midway MCR**. Choose
any ROM from `roms/MCR` when launching the core. The private ZIP includes
all 18 configured game sets, a controls guide and the required SSIO PROM.

For a private SD-card ZIP containing your local ROMs and PROM:

```sh
python3 scripts/package.py --roms scratch/roms \
  --zip build/MCR_GameBub_games_v0.5.0.zip
```

The ZIP includes only this core, four ROMs, the PROM, installation notes,
and checksums. It leaves existing settings and other cores untouched.
It contains local ROM data and is not a public release.

Upstream licence notices are retained; publication and the
repository licence remain to be settled with the owner.

For a catalog identity/DIP/orientation check using the experimental fast model:

```sh
python3 sim/run_tb.py --backend verilator --compile-only
python3 sim/check_games.py
# Add --frames 90 to smoke-test startup; this is not an Xsim/audio validation.
```
