# Bally Midway MCR on Game Bub: port plan

Written 2026-10-14 as the brief for the agent doing the port. Read all of
it, then `docs/FRAMEWORK_CHANGES.md`, then the ColecoVision port it leans on
(`../../adam/ColecoVision_GameBub`: `CLAUDE.md`, `docs/PORT_PLAN.md`,
`rtl/gamebub/`, `sim/`, `tools/`, `scripts/`).

## 1. Goal

Game Bub cores for the Bally Midway MCR arcade boards, from the MiSTer cores
by Dar (MiSTer-devel `Arcade-MCR*_MiSTer`). The user is a MiSTer-devel
admin of all four.

| Order | Core id | Upstream | Games (MRA `<rotation>`) |
|---|---|---|---|
| 1 | `alanswx.MCR3` | `Arcade-MCR3_MiSTer` `1ec8944` | Tapper, Timber, Discs of Tron (horizontal); Journey (vertical) |
| 2 | `alanswx.MCR3Mono` | `Arcade-MCR3Mono_MiSTer` `6c82a4b` | Rampage, Sarge, Max RPM, Demolition Derby, Power Drive, Star Guards (all horizontal) |
| 3 | `alanswx.MCR2` | `Arcade-MCR2_MiSTer` `6a8c78f` | Domino Man, Wacko, Two Tigers (horizontal); Tron, Satan's Hollow, Kozmik Krooz'r (vertical) |
| 4 | `alanswx.MCR1` | `Arcade-MCR1_MiSTer` `1621677` | Kick, Solar Fox (vertical) |

### Upstream freshness requirement

Start each board's port from the newest source on its official
`MiSTer-devel` default branch. Recheck the live remote before each initial
import or import refresh; the revisions below are a dated verification,
not permanent pins. Check the remote with this command (substitute the
board name):

```sh
git ls-remote --symref https://github.com/MiSTer-devel/Arcade-MCR3_MiSTer.git HEAD
```

Require a clean source clone whose HEAD matches, and record
the full revision in the import manifest. If a clone is behind, fetch and
fast-forward it before importing; preserve any local changes or divergent
history rather than resetting them.

Verified **2026-10-14** directly against GitHub: all four default branches
are `master`, and all four local clones are clean and match the live HEAD.
No source updates were needed.

| Upstream repository | Verified full commit |
|---|---|
| [Arcade-MCR3_MiSTer](https://github.com/MiSTer-devel/Arcade-MCR3_MiSTer) | `1ec8944c939ba5fcb4bcdfc5dd3e051a6273d141` |
| [Arcade-MCR3Mono_MiSTer](https://github.com/MiSTer-devel/Arcade-MCR3Mono_MiSTer) | `6c82a4bc9a830b05a94a780c0c3091167b98a9b8` |
| [Arcade-MCR2_MiSTer](https://github.com/MiSTer-devel/Arcade-MCR2_MiSTer) | `6a8c78f91229339306834d53bebf3434aefedf61` |
| [Arcade-MCR1_MiSTer](https://github.com/MiSTer-devel/Arcade-MCR1_MiSTer) | `16216779fd849f37b5541339790a7452817a77d0` |

### Core scope

* Name "Bally Midway MCR3" (etc.), author "Alan Steremberg"; confirm the
  ids and names with the user.
* Best on a d-pad: Tapper, Timber, Rampage, Domino Man. The rest want a
  spinner, wheel, trackball or two sticks; they get a best-effort button
  mapping.
* Three deliverables besides the cores:
  1. a way for users to build the ROM files (section 5);
  2. framework changes made the upstreamable way (section 6);
  3. later, an offline HTML/JS ROM builder (section 7).

## 2. Where things are (misterubuntu)

| Path | What |
|---|---|
| `~/mister/mcr/MCR_GameBub` | this repo (git, `framework/` submodule pinned to `db9d3b0`, `build.mill` default core class `MCR3`; no GitHub remote) |
| `~/mister/mcr/Arcade-MCR{1,2,3,3Mono}_MiSTer` | upstream clones (full history). Import from these |
| `~/mister/mcr/mra-tools-c` | sebdel's MRA tool, built (see `CLAUDE.md` for the fortify workaround). Licence: "do whatever you want with it" |
| `~/mister/adam/ColecoVision_GameBub` | the newest port: copy its host protocol, SRAM controller, game list, keypad/osk, controls card, testbench, scripts |
| `~/mister/iigs/Apple-IIgs_GameBub` | SDRAM controller + IDELAY tuned on this board, SDRAM testbench model |
| `~/mister/iigs/MacLC_GameBub/docs/FRAMEWORK_ISSUES.md` | framework bugs to work around |
| `~/mister/iigs/gamebub` | firmware source (`firmware/handheld/src/core/mod.rs`: file loading and saving) |
| `~/mister/cardbackup/MiSTer_Data/games/mame` etc. | MAME ROM sets (see `CLAUDE.md`) |
| `root@10.0.2.126` | MiSTer with the upstream cores, for comparison screenshots |
| `~/opt/verilator-5.052`, `~/vivado/2025.2`, `/usr/bin/ghdl` (4.1) | tools |

## 3. Game Bub constraints (learned on three ports)

* FPGA XC7A100T: ~63k LUT6, 135 BRAM36 (4.9 Mbit). SDRAM W9825G6KH 32 MiB
  (16-bit; the second chip is not wired: MacLC issue #7). SRAM 512 KiB,
  16-bit, 10 ns.
* The core owns one MMCM. It supplies:
  * the system clock (the framework runs on it);
  * an SPI clock of at least 160 MHz;
  * an LCD dot clock, whose net must be called `clk_dpi` (MacLC issue #4).
    It must keep `floor(framePeriod * clk / 808) <= 612` (issue #3), which
    is about 29.7 MHz at 60 Hz.
* **Video:** see `docs/FRAMEWORK_CHANGES.md`.
  * The framework stores two full frames of the declared `W x H x bits` in
    block RAM.
  * The LCD (800 x 480, a portrait panel mounted sideways) and HDMI
    (720 x 480) each use one whole-number scale for both axes.
  * The firmware's menu is a separate overlay.
* **Audio:** signed 16-bit L/R, sampled at 48 kHz.
* **Input:** 12 buttons. No analog, no spinner.
* **Files:**
  * At most 8 in `files.json`, each copied whole into core memory at start.
  * The core sees the size, never the name. There is no MRA or zip support.
  * The MCU streams at a fixed rate, so use ColecoVision's posted-write
    queue.
  * An optional, writable file with `"initialize": true` is cleared when
    missing. On exit the firmware asks the core for its size
    (FileReadStart) and writes it back (`core/mod.rs` `persist_files`).
    Use this for NVRAM high scores: a `dependent_on_0` file with extension
    `nv`.
* **Settings:** at most 16; actions are writes to an address.
* **Build:**
  * The build collects only `.v/.sv/.vhdl/.xdc` under `rtl/`: rename
    `.vhd` to `.vhdl`.
  * It collects **all** of `rtl/` for every core class, so modules with
    the same name but different contents across MCR boards will collide.
    The four upstreams share T80, Z80CTC, `gen_ram`, `dpram`, `spinner`
    and `mcr_sound_board` verbatim, but `sdram.sv`, `pll`,
    `midssio_82s123`, `cmos_ram` and the board files differ.
  * Plan for this when adding the second board: import shared files once
    and rename the differing ones per board in the import script. A small
    framework option for per-core RTL folders is the alternative
    (`docs/FRAMEWORK_CHANGES.md`).

## 4. The MCR3 upstream core, as it relates to the port

From `Arcade-MCR3.sv` and `rtl/mcr3.vhd`:

* **Clocks:** `clk_sys` 40 MHz (pixel enable at 20 MHz), `clk_80M` for its
  SDRAM.
* **CPUs:** Z80 main CPU (T80, VHDL) with Z80 CTC, and the "Super Sound"
  board (`mcr_sound_board.vhd`: Z80 + two AY-3-8910, `YM2149_linmix_sep`).
  Journey also plays a WAV sample (`sepways.wav`, MRA `index="2"`), which
  can come later.
* **Video:**
  * 512 x 480. The original is 15 kHz interlaced; the MiSTer core can scan
    progressive at 31 kHz (`tv15Khz_mode = 0`: 634 x 525 at 20 MHz, about
    60.1 Hz).
  * Every pixel is a 6-bit index into a 64-entry palette of 9-bit RGB.
  * Backgrounds are 8 x 8 tiles drawn 2 x 2, so they are really 256 x 240.
    Sprites (32 x 32) use the full 512 x 480.
* **ROM file** (MRA `index="0"`, built by `mra`), from the comment in
  `Arcade-MCR3.sv`:

  | Offset | Size | What | Where upstream keeps it |
  |---|---|---|---|
  | 00000 | 56 KiB | main CPU | block RAM (`dpram #(8,16)`) |
  | 0E000 | 16 KiB | sound CPU | SDRAM (`cpu1` port) |
  | 12000 | 128 KiB | sprites | SDRAM, read 32 bits wide |
  | 32000 | 32 KiB | backgrounds | block RAM inside `mcr3.vhd` |

  Tapper's `.rom` is 237,568 bytes.
* **Game select:** the MRA's `<rom index="1">` "mod" byte: 0 Tapper,
  1 Timber, 2 Discs of Tron, 3 Journey. It sets the input mapping,
  `landscape`, `mcr2p5` and the audio routing.
* **DIP switches:** `index="254"`, bytes `sw[0..7]`, defaults from the
  MRA `<switches default=...>`.
* **NVRAM:** `index="4"`, 2 KiB (`<nvram index="4" size="2048">`),
  `dl_nvram_*` ports.
* **Inputs per game** (`always @(*)` block):
  * Tapper: 4-way + Fill.
  * Timber: 8-way + chop left/right.
  * Discs of Tron: 4 buttons + aim up/down, with a spinner or "Rotate
    CW/CCW" buttons (`spinner.sv`).
  * Journey: 4-way + fire.
  * All: Coin, Start 1, Start 2, Service.
* **Memory choice for the port:** the whole ROM file is about 232 KiB.
  * Recommended start: keep upstream's block RAMs (main CPU, backgrounds)
    and put sound and sprite ROMs in the **SRAM**. That is the simplest
    controller, proven by the ColecoVision port.
  * The sprite fetch wants 32 bits at the pixel rate. Check the access
    pattern; two 16-bit SRAM reads at 40 MHz or more should keep up.
  * The alternative is the SDRAM, via upstream's `sdram.sv` or the IIgs
    port's controller and IDELAY setup. Use it if block RAM or SRAM is
    needed elsewhere, for example for a frame store.
  * Measure the block RAM before deciding: the video in section 6 may need
    most of it.

## 5. ROM files and the game list

* **Users build ROM files** with `mra -A <game>.mra` and the MAME zip, the
  same `.rom` MiST uses. The MRAs ship in each upstream `releases/` folder.
  Document the steps in the README; ROMs are never distributed.
* **The core must recognise the game from the file alone,** since it sees
  no name and the `.rom` holds no mod byte or DIPs. Use the ColecoVision
  approach:
  * a CRC32 of the loaded ROM, computed in the core;
  * looked up in `gamedb.bin`, built from `gamedb/games.tsv` by
    `tools/mkgamedb.py`;
  * giving the mod byte, DIP defaults, button map and a controls-card hint
    per game.
* **Seed the list from the MRAs** with a script: run `mra` on each MRA and
  ROM set available, CRC the output, and record the mod and DIP defaults
  (`DEFAULT=` in the `.arc`). Unknown ROM: show its CRC on the controls card
  or PMOD beacon.
* **Alternative to weigh:** a small header that our own tool prepends. This
  only works with the section 7 builder, not stock `mra`, so it is not the
  primary path.
* **Files** (draft):

  | id | file | notes |
  |---|---|---|
  | 0 | game ROM (`rom`), user selected, read-only | |
  | 1 | NVRAM (`nv`), `dependent_on_0`, optional, writable, `initialize` | 2 KiB |
  | 2 | `gamedb.bin`, fixed name, optional | |
  | 3 | Journey's sample, later | |

* **Settings** (draft): Reset, Service, Buttons (auto/default), Controls
  Card, Volume, Video mode (section 6), and DIP switches (Demo Sounds,
  Cabinet...) as lists, with "auto (game list)" first.
* **Controls** (defaults; the game list overrides): d-pad = joystick;
  A, B, X, Y = fire A-D; L, R = rotate CCW/CW (Discs of Tron);
  Start = Start 1; Select = Coin. Holding Select opens an on-screen panel
  for Start 2, Service and DIPs, as on ColecoVision. Tapper and Timber
  alternate two players.

## 6. Video: the core problem

`docs/FRAMEWORK_CHANGES.md` has the details. In short: MCR is 512 x 480, and
the framework's two frames in block RAM cost about 120-135 BRAM36 at 9 bits
a pixel. Work in this order:

1. **Baseline with the unmodified framework** (shippable):
   * **(B)** 256 x 240: halve the picture (backgrounds stay exact, sprites
     lose half their detail), shown 2x as 512 x 480. About 20-25 BRAM36.
   * **(C)** the same, stretched 5:4 to 320 x 240, shown 2x as 640 x 480:
     the correct 4:3 shape.
   * One bitstream can do both: declare 320 x 240 and pad (B) with black
     columns, chosen by a setting.
2. **Full resolution with the unmodified framework, if it fits (A):**
   * declare 512 x 480 at 6 bits (`colorDepth 2/2/2` carrying the palette
     index);
   * give the core a `VideoFilterBasicV0` that maps the index to RGB
     through a copy of the palette readable on `clock_av` (the core writes
     palette changes on `clk_sys`; mind the clock crossing);
   * measure what Vivado infers. About 90-96 BRAM36 if it packs a 6-bit
     width well, about 120 if it uses 9-bit-wide primitives.
   * The picture fills the panel height but is 20% too narrow (1x, square
     pixels).
3. **Framework changes,** only after the baseline works, done as
   `docs/FRAMEWORK_CHANGES.md` describes:
   * packing for narrow pixel widths, if (A) wastes block RAM;
   * fractional horizontal scaling for aspect;
   * rotation, for Journey, Tron and the other vertical games;
   * a crop window.

   Each change must make sense for every core, not only MCR.

Keep the video pipeline modular (the ColecoVision `gb_vdp_border` ->
`gb_osk` -> `gb_video_out` chain), so a later on-screen panel or controls
card works in all three modes.

## 7. Later: an offline HTML ROM builder

A single self-contained HTML page (no network, no CDN; inline everything)
that works in any modern browser:

* The user drops MRA files and MAME zips on the page.
* Zips are read with the browser's own `DecompressionStream("deflate-raw")`
  (no libraries).
* The page assembles `index="0"` exactly as `mra` does: part order,
  offsets, `repeat`, interleave, `map`, patches, and md5 or CRC checks.
* It outputs the `.rom` files (and optionally a zip of the SD-card folder).
* **Test:** byte-identical output to `mra-tools-c` for every MCR MRA, with a
  node or browser test script.
* Write it from the MRA format itself. `mra-tools-c`'s licence permits
  reuse, but a clean implementation is easier to maintain.
* It could later recognise games by CRC, warn about missing ROM sets, and
  serve other Game Bub arcade ports.
* Ask the user where to publish it (GitHub Pages or an artifact).

## 8. Phases (MCR3 first)

1. **Import and skeleton:**
   * `scripts/import_mcr.py` copies the MCR3 RTL with exact-text patches
     (`.vhd` -> `.vhdl`, Altera IP -> behavioural or Xilinx, the PLL
     replaced by our MMCM), recording the upstream commit in
     `scripts/import_mcr.txt`.
   * Write `rtl/gamebub/` (top, clocks, host, ROM memory, inputs, audio,
     video), `chisel/src/MCR3.scala` and `metadata/`.
   * Goal: lint passes.
2. **Simulation:**
   * The core is mostly VHDL (T80, CTC, `mcr3.vhd`, the sound board), which
     Verilator cannot read. Choose:
     * GHDL 4.1 `--synth --out=verilog` to turn the VHDL into Verilog for a
       Verilator testbench (fast, reuses the ColecoVision testbench);
     * or Vivado `xsim` mixed-language (slow, no conversion).
   * Start from the ColecoVision testbench: MCU host model, SRAM model,
     frame capture, `+press`.
   * Goal: Tapper's attract mode. Compare with a MiSTer screenshot.
3. **First bitstream, video option B/C:**
   * build, meet timing, package;
   * ask the user to test on hardware (LCD and HDMI dock).
4. **Game list, controls, NVRAM, DIPs, controls card.**
5. **Option A** (full resolution, palette in the filter), unmodified
   framework: measure the fit.
6. **Framework track** (`docs/FRAMEWORK_CHANGES.md`): fork, branch,
   changes, scanout testbench, regression on ColecoVision and IIgs, then a
   write-up for the author.
7. **MCR3 Mono, MCR2, MCR1** (module-name collisions, section 3).
8. **The offline ROM builder** (section 7).
9. **Release:** README, then ask the user before creating the GitHub repo.
   No bitstream built on a modified framework is released (CERN-OHL-S)
   unless the user decides otherwise.

## 9. Open questions for the user

* Core ids and names (`alanswx.MCR3` ...), and one repo for all boards.
* The repo licence, given Dar's "educational use" terms (section 1 of
  `CLAUDE.md`).
* When to create the GitHub repo and the framework fork.
* Where to publish the HTML ROM builder.

### Resumed implementation (2026-10-14)

* MCR3 import and Tapper platform are implemented, using upstream commit
  `1ec8944c939ba5fcb4bcdfc5dd3e051a6273d141`. The import manifest records
  verification in UTC (2026-10-15); the earlier tables use local dates.
  `python3 scripts/import_mcr.py --check` verifies all 14 imported files
  against the clean source clone without refreshing the import.
* `scripts/lint.sh --test` compiles/elaborates the full mixed-language core
  with Vivado and tests the host, ROM routing, 10 ns SRAM, sprite deadlines,
  and both B/C video modes with synthetic data. All platform tests pass.
  The script is now executable. On this host Xsim needs execution outside
  the Codex sandbox for its local IPC; sandbox startup itself is repaired.
* The baseline is **Tapper only**, with 40 MHz system, 200 MHz SPI, and
  28.571 MHz LCD clocks. Video is 320x240 RGB333, with either nearest-pixel
  4:3 stretching or a centred 256-pixel picture. The framework is unchanged.
* A required 32-byte `ssio.prom` is loaded as file 1. Upstream embeds this
  sound timing PROM in VHDL; the import removes those bytes and exposes a
  load port. It is not part of the MRA's index-0 ROM. For local testing,
  the PROM is extracted from the upstream source into ignored `scratch/`.
  No PROM bytes or game ROMs are committed. File 1 is consequently not yet
  the planned NVRAM file: persistence, CRC game selection, other games,
  controls card, and final file layout remain subsequent work.
* NVRAM is cleared at platform reset; it is not saved. Controls currently
  map Select to coin, Start to player 1, R to player 2, A to fill, and the
  d-pad to movement. Firmware focus suppresses gameplay input.
* `sim/run_tb.py` runs the full core with a functional 40 MHz clock and
  both VHDL CPUs/sound chips. It streams local ROMs through the host,
  models SRAM delay, checks every output frame, captures PPMs, and accepts
  frame-numbered `--coin` / `--start` presses. Example:

  ```sh
  source scripts/env.sh
  python3 sim/run_tb.py --frames 120 --dump 30
  ```

  Defaults: `scratch/roms/tapper.rom`, `scratch/roms/ssio.prom`, output
  `scratch/tapper-frames/`. `--aspect 0` checks native width. Compilation
  and execution can be separated with `--compile-only` / `--run-only`.
  Full-core attract-mode validation is in progress; see build results below.
* `tools/prepare_tapper.py` builds the index-0 ROM with stock `mra -A`,
  verifies its MRA MD5/size, and writes a supplied or locally extracted
  SSIO PROM. Its output was checked byte-for-byte against the initial
  local test files. `README.md` documents the reproducible commands.
* First synthesis found a T80 logical-width mismatch (`ioq and x"7"`).
  The import now pads the mask to nine bits. The live upstream HEAD was
  rechecked before this refresh and is unchanged. Synthesis then passed
  with zero errors and zero critical warnings.
* Rev 4 implementation with SRAM I/O-register constraints passed: WNS
  +0.414 ns, WHS +0.014 ns, 74.5/135 BRAM tiles and about 6.8k LUTs.
  The constraints follow the working ColecoVision port. The bitstream and
  local test SD-card folder are under `build/`; no hardware test yet.
* `scripts/package.py` stages only metadata and the bitstream into
  `build/sdcard/cores/alanswx.MCR3`, rejecting stale hardware sources or a
  failed routed timing report. The user supplies `ssio.prom` separately.
* Optional `sim/run_tb.py --backend verilator` converts the VHDL with
  GHDL 4.1 (`--std=08 -fsynopsys -frelaxed -fexplicit`) and uses Verilator
  5.052. `sim/fast_backend.py` normalizes GHDL's generated identifier and
  duplicate-alias issues without changing imported RTL. Xsim remains the
  four-state reference. Both backends use the same host/SRAM/frame tests.
  Xsim captures show Tapper's startup patterns; both backends' frame 30
  matched byte-for-byte (black during startup).

### Hardware startup correction (2026-10-14)

The user tested the first SD-card build: the initial launch was black,
then the firmware Reset action made the game work. The user confirmed
that picture, controls, and sound all worked after Reset. The upstream
`Arcade-MCR3.sv` reset wrapper explicitly runs the board for 65535 clocks
and then pulses reset a second time. Our initial wrapper instead held
reset for that entire interval, losing the second edge after the board
had clocked.

`gb_mcr_reset.sv` now reproduces upstream's registered reset and delayed
one-cycle pulse for launch and manual Reset. The platform test checks the
entire interval, pulse width, and absence of extra pulses on both paths.
All platform regressions pass. This is a likely fix for the reported
hardware behavior; a cold-launch hardware retest is still needed.

The experimental GHDL/Verilator backend's earlier 300-frame run stayed
black and failed its success check. Xsim produced different startup
patterns at matching frame numbers. A black-frame match at frame 30 is
therefore not evidence of backend equivalence. Use Xsim for validation
until the conversion discrepancy is resolved.

After the reset correction, both Xsim and the converted Verilator model
passed a complete 10-frame startup test, and frame 10 matched byte for
byte (the visible grid test pattern). Longer boot equivalence remains
unverified. The platform reset test covers both cold launch and manual
reset; hardware confirmation of automatic cold launch is still pending.

The corrected rev 4 bitstream built successfully and meets routed timing:
WNS +0.202 ns, WHS +0.037 ns. The local SD-card staging folder has been
updated; the card is currently in the handheld, so it has not received
this correction yet.

### Automatic game recognition and private ZIP (2026-10-14)

* The user requested choosing ordinary ROM files from one folder, with no
  separate game-selection setting. The current build recognizes stock
  Tapper (Budweiser 840127) and Timber MRA index-0 outputs by CRC32:
  `0f584827` and `3f49e94e`. `gamedb/games.tsv` records CRCs, mod bytes,
  DIP defaults, and MRA MD5s. These two entries are built into the host;
  an external `gamedb.bin` remains future work as the supported list grows.
* CRC is updated exactly once for each acknowledged ROM byte, in address
  order, and checked after the posted-write queue drains. Wrong-size,
  incomplete, out-of-order, and unrecognized images cannot become runnable.
  The PROM cannot alter the recognized identity. Diagnostics expose the
  CRC at `0x818` and recognition/mod bits at `0x81c`.
* Timber uses upstream's bit-5/right-axe and bit-4/left-axe mapping: A and
  B respectively. Its second joystick is idle, and R does not start an
  uncontrollable second player. Tapper retains A fill and R start 2.
  Both supported MRAs use DIP defaults FF 00. No user game selector exists.
* The synthetic platform test checks the standard CRC32 known answer,
  an independently calculated full-ROM CRC, identity stability across PROM
  loading, rejected unknown images, both input maps and focus gating,
  in addition to the existing reset/memory/video tests. All pass in Xsim.
  Timber's actual ROM was built with `mra -A`, checked against the MRA MD5,
  and auto-detected in Xsim, with ten complete startup frames captured.
  This is startup validation, not a hardware gameplay claim.
* `tools/prepare_mcr3.py --game tapper|timber` handles both local sets;
  `prepare_tapper.py` remains a compatibility entry point.
  `scripts/package.py --roms scratch/roms --zip build/MCR3_GameBub_Tapper_Timber_test.zip`
  creates the requested private SD-card bundle, including the user's local
  ROMs and PROM, installation notes, and checksums. It validates archive
  contents byte-for-byte. No ROM data or ZIP is committed or published.

### Candidate next architecture: the user's Tang merge

Reviewed `alanswx/Arcade-MCR2-TangFPGA` at
`60363fa2a2a5e50e07c48bfe084bb61e00b1d393` (read-only clone under scratch).
The user asked whether it makes more sense than separate MiSTer-style cores.
Recommendation: aim for one user-facing MCR core with ROM auto-detection;
retain individual builds for debugging. The merged Tang top selects MCR1,
MCR2, MCR3, and MCR3Scroll and shares ROM/scratch/video memories. MCR3Mono
is parked separately under `future/`, so this is not yet every family.

Reuse that board integration incrementally while keeping Game Bub's host,
file browser, clocks, memory interfaces, video/audio adapters, and reset
work. First candidate expansion is MCR2/Domino Man. Measure Vivado fit and
timing with the Bub framebuffer before committing to one combined binary;
Tang resource counts are not directly transferable. No Tang RTL has been
imported and the current ZIP remains the two-game MCR3 baseline. Future
imports still need source freshness checks and reconciliation with current
MiSTer changes, as required above.

The Tapper/Timber rev 4 build meets routed timing (WNS +0.134 ns,
WHS +0.076 ns). The requested private ZIP was generated and each archived
payload compared with its local source. It preserves existing settings;
copy its cores/ and roms/ directories to the SD-card root.

Tapper's matching actual-ROM Xsim regression also passed: mod 0,
CRC 0f584827, ten complete startup frames. Both supported game identities
have therefore been checked through the real host download path. Timber
playability and automatic cold launch still await hardware confirmation.

### Hardware confirmation: two-game baseline (2026-10-14)

The user tested the Tapper/Timber ZIP and reported: "both games start up
and work well". This confirms both supported games, automatic recognition,
and normal startup with the double-reset correction on the Game Bub.
It supersedes the pending hardware checks above. No further manual Reset
workaround was reported. This is the working baseline for the proposed
merged MCR expansion; other families and NVRAM persistence remain future work.

### Combined-family implementation (2026-10-14)

The user authorized tackling the combined core after confirming Tapper and
Timber on hardware. The user-facing direction is now one `alanswx.MCR`
core; the separate-core plan above is superseded. The first testable
increment combines current official MCR2 and MCR3 engines, with Domino Man
joining Tapper and Timber. Keep the existing two-game ZIP as the known-good
hardware reference. The new core installs beside it with a different ID.

Live HEAD verification: official MCR2 remains
`6a8c78f91229339306834d53bebf3434aefedf61`; the clean sibling clone matches.
The Tang merge remains `60363fa2a2a5e50e07c48bfe084bb61e00b1d393`.
`scripts/import_mcr2.py` imports the board reproducibly, verifies shared
primitives against MCR3 and verifies the SSIO PROM contents match. It adds
the external PROM ports and static VHDL port expressions, and carries over
the Tang MCR2 progressive 512x480 active window. MiSTer's 478-line window
would only produce 239 lines in our half-resolution capture.

The two board engines share the main-program BRAM and SRAM sound interface.
MCR2 sound starts at ROM offset C000; MCR3 sound starts at E000. The loader
writes both board graphics destinations in parallel before identification,
so ordinary headerless MRA outputs can still identify themselves only at
EOF. Unselected engines remain in reset. MCR2 retains its internal graphics
BRAMs for this increment; the first synthesis uses 90/135 BRAM tiles and
about 11.1k LUTs. This leaves room to evaluate MCR1 before needing the Tang
merge's scratch/graphics memory sharing. MCR3Scroll and MCR3Mono remain later
integrations; no claim is made that the entire Tang roster is playable yet.

Domino Man is stock MRA output, size 0x1c000, MD5
`112359d5a207884821f6df0f0c1c4d2c`, CRC32 `085cde56`, MCR2 mod 5, DIPs FF 00.
The loader validates both the actual byte count and reported size against
the detected game's expected length. File metadata no longer forces the
MCR3 size on MCR2. D-pad/Select/Start map movement/coin/start; A swats and R
starts the alternating second player. No separate game-selection setting.

Platform regressions pass, including an in-place MCR3-to-MCR2 family switch,
CPU and sound reads at both layouts, and rejection of mismatched file size.
The full-core test permits undefined palette pixels during startup but
requires zero undefined pixels and visible content in the final frame;
timing and frame dimensions are checked throughout. Domino's first capture
at frame 5 has a fully defined startup grid. Longer startup runs, baseline
regressions, and final routed implementation are in progress.

The corrected combined rev 4 implementation meets routed timing: WNS
+0.352 ns, WHS +0.047 ns, zero failing endpoints, 90/135 BRAM tiles and
10,787 LUTs. Build log: `build/combined-build.log`. The private three-game
archive is `build/MCR_GameBub_combined_test.zip` (about 601 KiB), verified
against each source payload. The original two-game ZIP is unchanged.

Domino Man passes ten complete Xsim startup frames with no undefined
pixels in the final frame. The experimental converted backend also passes
120 frames through the grid/color-pattern boot sequence; this is not a
hardware gameplay claim. Tapper's combined-core ten-frame Xsim capture is
byte-identical to the previous auto-detection baseline. Timber also passes ten Xsim frames and matches its previous startup
capture byte for byte. The experimental converted backend also passed 300 frames with coin/start
injection; captures still show diagnostic color patterns, so that run alone
does not establish gameplay or audio correctness. Hardware feedback below
is stronger evidence of playability.

Next integration boundaries: add MCR1 with a fresh upstream verification,
retain per-family reset isolation, and measure the cost before hoisting
memories. Bring in the Tang shared graphics/scratch interfaces only where
the resource report justifies them. MCR3Scroll needs separate review of its
Cheap Squeak Deluxe audio/68000 ROM routing. Portrait games also need a
usable orientation/control plan. Each step must keep stock-ROM recognition
and the three-game baseline passing; a family engine's presence alone does
not make every game supported.


### MCR2 horizontal alignment correction (2026-10-14)

The user tested the combined ZIP: "tapper and timber look good. domino man
works but the screen seems shifted", then requested restoring the 18-pixel
start delay. This confirms all three games run on hardware, while exposing
a capture alignment error. The Tang board's zero-based horizontal blanking
is paired with a separate `cap_delay` in its framebuffer wrapper; importing
only the zero-based blanking lost that RGB-pipeline compensation on Game Bub.

The MCR2 import now retains upstream's horizontal start at 18 and exclusive
end at 530, while preserving the full 480-line vertical window. This changes
only MCR2 capture timing, not the MCR3 path, ROM data, or controls. Metadata
version is 0.2.1. `sim/tb_mcr2_raster.sv` checks the real board's blanking at
every pixel of a 634x525 frame, including the 18-pixel lead-in and exactly
512x480 active pixels. This raster test and all platform regressions pass.
Corrected Domino Man Xsim validation passes ten complete frames with zero
undefined pixels in the final capture. Rev 4 routed timing also passes:
WNS +0.363 ns, WHS +0.049 ns, no critical warnings or errors. The bitstream
records source revision `b1c962c990c9`. The verified private update ZIP is
`build/MCR_GameBub_combined_v0.2.1.zip`; the prior combined ZIP is retained
for comparison. Hardware confirmation is recorded below.


### Combined v0.2.1 hardware confirmation

The user retested the alignment update and reported: "the video look
perfect - the other games look good". This confirms the corrected Domino
Man capture alignment and continued correct video for Tapper and Timber.
Version 0.2.1 is the confirmed combined MCR2/MCR3 baseline. The bitstream
is unchanged; documentation and private ZIP installation notes now reflect
the result. Other families remain subsequent integration work.


### Portrait games and Satan's Hollow (feature branch)

The user authorized continuing and requested upright and sideways settings,
defaulting to upright because a sideways grip may be awkward. Confirmed
that framework `displayRotate` is a compile-time LCD mounting correction;
there is no runtime rotation register. Implemented optional
`VideoTransformV0.rotation` and a framebuffer read-address transform on local
`feature/video-rotation` (framework) and `feature/portrait-video` (this repo).
The existing two frame stores are reused; no additional image RAM is needed.
Upright MCR is a clockwise turn, 240x320 logically, scaled by 3/2 to 360x480.
The LCD mounting compensation, overlay, stored-frame readback and frame
buffering remain under the framework's existing paths. HDMI uses the same
orientation and aspect. Requests cross through XPM handshake and latch on
output blanking; the menu remains in its normal orientation.

Core register `0x210` selects Upright (0, default) or Sideways (1). Sideways
uses the original full landscape picture and assumes a clockwise handheld
turn; Down/Up become game Left/Right. It affects portrait games only.
An optional framework informational register `0x0108` reports the core's
requested transform. Cores without the interface keep the old register map.

Satan's Hollow (Set 1) is the ordinary MCR2 MRA output: size 0x1c000,
MD5 `cc2c7141ad992cffa1bd34ee74952152`, CRC32 `a2403144`, mod 0, DIPs FF 00,
clockwise portrait rotation. Controls match upstream (A fire, B shield).
The existing verified MCR2 board import is unchanged.

Rotation unit tests pass 1,618,944 coordinate cases across all four turns,
LCD/HDMI scan axes, bounds, fractional scale, read lookahead including
unsigned blanking wrap, and frame-boundary mode changes. Initial testing
caught the need to preserve the LCD coordinate width when adding read
lookahead across zero; this is now covered by the regression. Generated
ColecoVision and Apple IIgs default HDL matches the db9d3b0 baselines exactly
once source comments are removed (14 modules each). The non-opted-in MCR
HDL was also checked before adding the optional interface. Compatibility
checks use the sibling declarations without modifying the source repos;
no separate routed Coleco/IIgs rebuild has been performed.

Existing host/SRAM/reset/video/raster tests and the new MCR2 controls tests
pass. Satan's Hollow auto-detection and its clockwise transform request pass. Its
first ten simulated frames have an uninitialized palette, unlike the other
games; a longer reference boot run is investigating the startup interval.
The portrait bitstream's synthesis still uses 90/135 BRAM tiles (11,546
LUTs); final routed timing is in progress. This is a private local prototype, with no
remote fork, push or public release. Public release remains subject to the
framework process and licensing decisions already documented above.


The startup investigation found two compatibility details. Official MCR2
uses a 40,000,000-clock delayed second reset, versus MCR3's 65,535 clocks.
The combined wrapper had reused the short interval. Reset sequencers now
retain each family's interval, and the regression checks every clock across
cold and manual resets (80 million clocks total for the long counter).
The full-core frame collector now discards any partial frame interrupted
by a restart. Startup may legitimately fade to black between color tests;
the checker requires at least one fully defined visible frame during the
run and no undefined pixels in its final frame, rather than requiring that
an arbitrary last frame be nonblack. This remains a display/boot check, not
a gameplay assertion.

Inferred VHDL RAM was also uninitialized in the four-state model, while
Vivado's RAMB36E1 defaults its INIT parameters to zero. Satan's Hollow backs
up and restores RAM during its startup test, propagating undefined video
state in that model. The import now explicitly initializes the common
single/dual-port RAM arrays to zero to match FPGA power-up. This is only
power-up initialization; CPU resets continue to preserve their contents.
The live MCR3 upstream HEAD was rechecked and remains
`1ec8944c939ba5fcb4bcdfc5dd3e051a6273d141`; the import manifest records the
additional exact-text patch. No game ROM or PROM data is embedded.

`sim/render_rotated.py` renders a captured native framebuffer through the
production mapper and a three-cycle read-pipeline model. Coordinate-coded
full-image checks pass on LCD clockwise and HDMI counterclockwise output,
including the first visible pixels across wrapped blanking and all borders.
The prototype is now 0.3.1, superseding the earlier 0.3.0 preview ZIP.
Corrected full-core boot validation and the final build are in progress.


Final portrait candidate validation: the corrected four-state Xsim run
passes 60 complete frames with zero undefined pixels in its final frame,
including the MCR2 one-second delayed restart. Initial black frames now
have zero unknown pixels, consistent with FPGA power-up. The faster model
passes 240 frames and reaches Satan's Hollow's credits/insert-coin screen.
The production mapper renders that capture as readable upright text on LCD
and HDMI, confirming the MRA's clockwise rotation direction. The sampled
CPU addresses, reset state, and selected ROM data match between backends
for 630 reference samples (pass). ROM-port data during RAM/I/O accesses
is not compared because that port is unselected then. This does not prove
full backend/audio equivalence or hardware playability.

All final platform regressions pass, including the cold/manual full-length
family reset test. `scripts/check_rotation.py --defaults` also passes the
mapper, boundary latch, blanking-wrap and unchanged-core elaboration tests.
The final build records code revision `096d9bd5de9a`, WNS +0.328 ns,
WHS +0.060 ns, 11,252 LUTs and 90/135 BRAM tiles, with no critical warnings
or errors. The verified private archive is
`build/MCR_GameBub_portrait_v0.3.1.zip` (four ROMs and the SSIO PROM).
Source/metadata remain on `feature/portrait-video`; framework rotation is
local commit `6e5adf7` with the reviewable patch preserved in this repo.
Hardware testing of Satan's Hollow, both orientations, overlay, controls,
sound and docking remains the next external validation step.


### Opposite sideways grip (0.3.2)

The user reports that the portrait build looks good on the device. The CW
sideways grip leaves the joypad at the top; they requested the opposite grip.
Setting 0x210 now accepts 0 = upright, 1 = hold CW (existing saved value),
2 = hold CCW. Invalid value 3 falls back to upright. Upright remains default.
For Satan's Hollow these request framework turns 1, 0, 2 respectively:
the opposite grip needs a 180-degree framebuffer read relative to the raw
raster, rather than another quarter-turn. Both sideways grips retain the
landscape game area and Picture setting. The firmware menu stays unchanged.
CCW maps physical Up/Down to screen Left/Right; CW retains Down/Up.
Other games retain their original video and controls regardless of setting.
The framework already supports these transforms, so no framework change or
additional image RAM is needed. The previous build used 90/135 BRAM tiles.
Targeted input tests cover both grips, unused axes, focus and Domino controls;
platform tests cover all setting values and invalid-value fallback.
All mixed-language platform, raster, input and full-length family-reset
regressions pass (`build/portrait-ccw-platform.log`). The production mapper
passes all 1,618,944 coordinate checks and frame-boundary latch tests
(`build/portrait-ccw-rotation.log`). Full-core Verilator integration loads
the real Satan's Hollow and Domino Man ROMs, auto-detects them, and sweeps
all three settings: the portrait core requests turns 1/0/2, while Domino
stays at turn 0 (`build/portrait-ccw-integration.log`,
`build/portrait-ccw-domino.log`). These short integration tests stop before
CPU startup; they are not another full game-boot or audio test.
A real credits capture rendered through turn 2 has the expected opposite
sideways direction (`scratch/shollow-attract/ccw_lcd.png`).
The routed build from source commit `06e7565` passes all timing constraints:
WNS +0.241 ns, WHS +0.043 ns, zero failing endpoints, 11,248 LUTs and
90/135 BRAM tiles. No additional framebuffer RAM was used. The new CCW
grip still needs on-device confirmation. The private archive
`build/MCR_GameBub_portrait_v0.3.2.zip` passes package freshness, timing,
ROM/PROM checksums, ZIP integrity and per-file byte verification. The build
finished without errors or critical warnings.


### Rotation confirmed; remaining MCR2/MCR3 games (0.4.0)

The user confirms that the opposite sideways grip works on the device.
Both directions remain awkward to hold, but they consider rotation complete
for now and authorized loading/configuring the remaining games. Proceeding
first with all official games on the two already integrated boards; MCR1,
MCR3 Mono and MCR3Scroll remain separate hardware-port work.

All ten stock MRA index-0 ROMs assemble from the user's local sets and match
the upstream MD5s. The catalog now lives in `gamedb/games.json`; the TSV and
synthesizable identity decoder are generated by `tools/generate_gamedb.py`.
The host retains streaming CRC/error checks, then latches board, mod,
portrait flag and DIP defaults from the decoder after a valid file load.
Tron needs F8 00, unlike the other nine sets' FF 00. Its trigger also
appears on input 3 bit 7, and the spinner is duplicated on input 4 as in
the official wrapper. Kozmik Krooz'r is horizontal according to its MRA,
correcting the earlier planning table. Journey uses the existing MCR2.5
mode in the MCR3 engine. Discs of Tron enables the upstream horizontal flip.
Imported board RTL and framework are unchanged.

`gb_mcr_controls` retains the original four games' maps and adds all five
SSIO input ports. Frame-driven counters substitute for the arcade spinners
and Wacko's trackball, using the upstream fixed-point increments: Tron and
Krooz'r 25/4, Two Tigers 55/4, Discs 10/4 and Wacko 10/4 per frame.
Krooz'r uses the upstream analog centers/extremes (100, 37, 163).
The portrait grip remaps all four directions for Tron and Journey too.
Spinner games use Start+R for player 2 start; R continues to start player 2
on the existing games. Two Tigers uses the Tron Conversion ROM and has
player 1 controls only. Journey's separate WAV music path is not implemented;
its normal SSIO sound stays connected. No high-score persistence is added.

The ROM preparation tool accepts all ten keys and validates the MRA MD5;
it locates the one generated ROM rather than assuming the tool's output
basename (Two Tigers has a different/truncated name). Packaging includes
all ten local ROMs with full MRA names, the PROM and controls/install notes.
Build, startup and routed timing validation are in progress.


### All four board families authorized (0.5.0)

The user explicitly selected including MCR1 and MCR3 Mono now. Rechecked
live official default-branch HEADs before importing: MCR1 remains
`16216779fd849f37b5541339790a7452817a77d0`, MCR3 Mono remains
`6c82a4bc9a830b05a94a780c0c3091167b98a9b8`; both source clones were clean.
`scripts/import_remaining.py` reproduces eight additional board/CPU files,
sharing the byte-identical existing Z80/CTC/RAM/SSIO primitives. Exact
patches name non-static VHDL-93 port expressions, add the MCR1 PROM ports,
rename the FX68K declaration package for mixed-language binding, expand
preprocessor constants and embed the CPU's own microcode from its source
files. These are processor control stores, not game ROMs. The upstream
simulation-only arithmetic workaround remains simulation-only. No upstream
clone is edited. Import manifests record revisions and verification dates.

All 18 MRA index-0 images assemble and match their declared MD5s. The eight
new sets are Kick, Solar Fox, Demolition Derby (Mono), Max RPM, Power Drive,
Rampage, Sarge and Star Guards. Mono sets are 0x48000 (Turbo Cheap Squeak)
or 0x80000 (Sounds Good); MCR1 sets are 0x1a000. The PROM moves to
0x100f0000 to avoid overlap with the larger ROM file. Update core metadata
and bitstream together. The largest SG set uses 256 KiB sprites and
128 KiB sound in SRAM; the board layout also supports up to 256 KiB sound.
The earlier estimate of full 512 KiB external storage was the layout's
capacity, rather than the actual 384 KiB used by these SG MRA sets.

A generated checksum decoder recognizes the first 256 ROM bytes to select
loading layout before any game-specific address ranges begin. The full-ROM
CRC, exact byte count and file size still gate startup. Unknown/damaged
files cannot start a board. The early identities are all distinct in the
catalog. The main CPU ROM remains shared BRAM. Runtime SRAM retains the
three-slot sprite-low/sprite-high/sound schedule. Mono uses the upper SRAM
half for sound and lower half for transposed sprite planes, with the
upstream SG byte-plane sound ordering. MCR1 has a distinct 0x8000 sound base.
MCR1's 4-bit RGB is reduced to RGB333 for the shared framebuffer. Both
sideways settings extend to Kick and Solar Fox. Existing board engines,
video capture correction and optional framework transform remain intact.

Handheld controls cover all games, with player 1 maps for Mono. Single-stick
Sarge steering follows the upstream optional tank steering mode. Max RPM
honors the game-selected ADC channel and edge-triggered gearbox. Derby
honors the four-player wheel mux with other players idle. Sounds Good status
bits feed the game input ports as in the official wrapper. Normal sound
hardware is included for every board; Journey's separate WAV music remains
unimplemented, as previously documented. High scores are not persisted.
The controls/install guide is included in the private ZIP.

Mixed-language elaboration now includes actual FX68K, 6809 and all four
Z80 video engines. The widened regression address bus needed an explicit
unsigned/masked cast; the old 14-bit signed cast had sign-extended into the
new 18-bit bus. The original MCR2/MCR3 platform tests then pass. New tests
verify SG/TCS 32-bit sprite plane packing through full-width boundaries,
16-bit sound byte order and eight-clock deadlines, MCR1's sound bank, all
18 input maps, gear edges, Max RPM ADC capture/hold, Derby mux and sound
status. The experimental fast model packs the CPU's three bit-only structs
in generated simulation code because Verilator rejects mixed continuous
and clocked drivers on distinct members of an unpacked struct. Production
RTL keeps the upstream struct representation.
Startup/capture checks and routed resource/timing checks are in progress.


The first four-family synthesis fits at 127/135 BRAM tiles and 23,493 LUTs
(37%). The current SG MRA sets need only 128 KiB sound, leaving 128 KiB
external SRAM free. A Picture Auto option is being finalized: MCR1 uses
native width to preserve its nearly square original image, while the
other families keep 4:3. Existing manual values 0/1 retain their meanings.
The firmware may retain a previous manual setting; selecting Auto once
activates the family default. The testbench ROM buffer is widened to
512 KiB plus a guard byte. The fast backend disables unique-case assertions
that otherwise fire at time zero inside the held-reset FX68K; testbench
fatal checks remain enabled. This does not establish audio equivalence.


The final 18-game loading/identity sweep passes: board and early layout,
full CRC/size, DIP defaults, SG selection and all three grip requests
(`build/four-families-identities-final.log`). The complete mixed-language
suite passes with Picture Auto, and the focused host test additionally
passes MCR1 automatic aspect and both manual override/restore checks.
The strengthened memory test switches to fresh addresses in every read
phase and still meets all eight-clock deadlines. These checks use Xsim
for platform/control/memory behavior and the experimental fast model for
catalog loading. New-board CPU startup and the four-state Rampage sound
reference are still in progress. The first routed candidate predates
Picture Auto; rebuild from the final source commit before packaging.


To reduce smoke-test runtime, the fast backend now clocks inactive engines
only during loading/reset, then holds their already-reset clocks quiet
during play. The selected board always sees the original 40 MHz clock;
all boards keep their download clocks while loading. This is generated
simulation code only. A manual-4:3 Kick frame 30 matches the original
ungated model byte-for-byte (SHA256
`1c64b6a552b303828c6ba07ea14bb377c55a516e55dede1735aeee347ff958e5`).
The final-source fast sweep uses Auto picture mode and checks undefined
audio after the first two frames. Primary Xsim still uses the unchanged
production clocks and actual unpacked FX68K structs. Source register names
and checks remain intact; no game CPU or sound system is replaced by a stub.

The user has tested the private v0.5.0 bundle on the handheld and reports
uncertain Discs of Tron speech and missing Journey sampled music. This does
not establish every game's controls or audio as fully verified. The shipped
Discs MRA uses `dotron.zip` (upright), not the Environmental `dotrone` set.
MAME's `src/mame/bally/mcr.cpp` configures the upright without Squawk & Talk
and the Environmental version with that additional sound board. The current
official MCR3 FPGA source implements only SSIO, without that speech board.

Journey's ordinary SSIO sound is connected, but its `sepways.wav` path is
absent from this port. The official wrapper loads index 2, stores the WAV in
SDRAM, loops `wave_sound` under `output_4[0]` control and mixes its PCM with
SSIO. The checked local Game Bub firmware's `core/mod.rs::load_files`
already accepts optional extra files and transfers them to configured FPGA
addresses with file start/end notifications. Firmware WAV decoding is not
required for that approach: the missing work is FPGA sample storage,
playback/control and mixing, plus optional sample metadata. No firmware
upgrade requirement has been established. README and future ZIP guides now
state both audio limitations explicitly.

### Located speech implementation and public source repository

The user correctly recalled implementing Squawk & Talk. A live GitHub check
found `alanswx/Arcade-MCR3_MiSTer` branch `squawk-n-talk-speech` at
`09c8a26ee6e2c828f8cb12cd1b317235c758bcd1`, 11 commits ahead of upstream's
unchanged `1ec8944c939ba5fcb4bcdfc5dd3e051a6273d141`. Its first commit
`5ebc9c4a0f6e583c1ec3b759727a269160f955a7` implements MC6802/jt680x,
two PIAs, TMS5200 and AD558, adds Environmental mod 4, and records working
DE10-Nano speech. Later commits record phrase comparisons and a backdrop.
The upstream repository's full pull-request list contains no speech PR.
`alanswx/Arcade-MCR2-TangFPGA` main also contains `src/rtl/squawk_n_talk.sv`
and the TMS5200 modules. This code is not yet imported into Game Bub; the
current 18-set catalog still intentionally contains only upright `dotron`.
The earlier upstream-only investigation missed this existing feature branch.

The user requested a public `alanswx/MCR_GameBub` repository and proposed
forking the framework. The `alanswx/framework` fork now publishes the tested
`feature/video-rotation` commit `6e5adf7ed3d8776f504d55e6dbb8d6fcc5cfa930`.
The MCR submodule URL points to that fork, making recursive clones complete
without applying a private commit. No PR or push to `gamebub/framework` was
made. Historical local-only instructions above are superseded by this
explicit publication authorization. Only source and ROM recipes are being
published, not the private ROM-containing ZIP or a bitstream release.

The routed v0.5.0 build from `06fc15c` meets timing: WNS +0.272 ns, WHS
+0.023 ns, 22,940 LUTs and 127/135 BRAM tiles. The eight new-board startup
checks pass 90 frames with Auto aspect (`build/four-families-startup-auto.log`);
this is a startup check, not proof of every attract sequence or audio path.
The unsuccessful four-state sound probe and its experimental reset patch
are preserved only in ignored `scratch/sound-board-investigation/`; neither
is part of the production import or a passing-test claim. Production imported
RTL remains the same as the hardware-test bundle.

The requested offline builder is `web/MCR-ROM-Builder.html`, a generated
standalone page with no runtime dependencies or embedded ROM data. It uses
the 18 catalog identities and official index-0 recipes, recognizes ZIP chip
contents by CRC, supports merged/parent inputs, exports individual `.rom`
files or an SD-layout ZIP, and accepts or extracts the matching SSIO PROM.
`tools/check_rom_builder.py --browser` verifies all 18 outputs byte-for-byte
against local mra-tools results and MRA MD5s, renamed/missing/corrupt inputs,
malformed/encrypted/unsupported/ZIP64 archives, exported ZIP integrity and
native Chrome decompression plus file-selection/PROM UI. Source/template
and generation instructions are in `web/README.md`. Environmental `dotrone`
is intentionally not offered before the speech board is actually ported.

Before the initial public push, all 230 existing historical blobs were
checked for game/data/build extensions and private-key/token signatures:
none were found. Ignore rules now also exclude stand-alone bitstreams,
Vivado reports/checkpoints, simulator objects, local agent state, credentials
and additional archive formats. Checks cover 21 excluded paths and 11
permitted source paths, including the HTML and MRA recipes. The source
provenance notice preserves component terms without inventing a blanket
licence for imported code.

### Environmental Discs of Tron / Squawk & Talk port (0.6.0)

The user authorized merging the existing speech implementation into Game
Bub. Live verification still finds official MCR3 master at `1ec8944c939b`
and the speech feature branch at `09c8a26ee6e2c828f8cb12cd1b317235c758bcd1`.
`scripts/import_speech.py` imports that clean branch's jt680x, shared PIA
interface, TMS5200 and speech board with reproducible adaptations. CPU/chip
control tables are inlined; Altera-only JTAG blocks are omitted. CPU control
signals are declared before the expanded control-store code to prevent
implicit-net truncation/redeclaration. TMS flop/SRL zero power-up values are
explicit, preserving the source's nonzero noise LFSR and initialized tables;
this matches Vivado's default INIT and prevents startup X from contaminating
the reconstruction IIR in four-state simulation. No game bytes are embedded.

The nineteenth catalog entry is `dotrone`, MCR3 mod 4, size 0x3e000, full CRC
`59674db7`, prefix CRC `aabe522c`, MD5 `979cb63d85f917cdae2179c515111a24`.
Its checked-in MRA derives from the feature branch's index-0 recipe without
the unrelated inline cabinet artwork. Local `mra-tools-c` output matches the
catalog. The offline builder and CLI preparation tool accept this local
recipe. Its main program and SSIO revisions differ from upright `dotron`.

The speech ROM extension at file 0x3a000..0x3dfff loads into SRAM words
0xa000..0xbfff, avoiding additional ROM BRAM. Only Environmental mode adds a
fourth runtime read slot; the other games retain their three-slot scheduler.
Both sprite halves, SSIO and speech still meet eight-clock deadlines for
all four phases and boundary/byte-lane probes. The Environmental input strap
is IP2 bit 7 low; spinner/start-chord mapping and horizontal flip match the
upright. SSIO OP4 drives the board command/strobe inputs. The source's 5/6
MC6802 enable correction, TMS cadence/filter and saturated audio mixing are
retained. Existing SSIO/audio/video routes bypass speech for other games.

The complete mixed-language platform, raster, control, memory-layout and
family-reset regressions pass. The 19-game browser builder comparison passes
byte-for-byte/MRA MD5 and native Chrome UI/decompression checks. Four-state
real-firmware speech/reference, in-game command generation, routed timing
and handheld validation are being checked separately; these are not implied
by the platform/recipe tests. Journey's sampled music and the optional
cabinet backdrop remain outside this speech port.

The first routed speech build (`55af35d`) meets timing at +0.023 ns WNS and
+0.037 ns WHS, using 128/135 BRAM tiles. A final source-wrapper parity fix
makes Environmental Start/Start2 also assert coin, as upstream does; the
upright mapping is retained. Rebuild after that change before packaging.
The ROM's exhaustive RAM, PIA and TMS initialization lasts about 2.65 seconds
in the reference test. A cue at 20 ms was premature, and a 3-second test
guard expired during the now-audible phrase. The final test waits for the
firmware's CLI and allows the complete startup plus playback check. The
initial full-core game test pressed coin/start during startup/title animation
and did not establish in-game speech; later input timing is being tested.

The final routed production source is `80ab2884e1a2`: WNS +0.046 ns, WHS
+0.029 ns, zero failing endpoints, 24,900 LUTs and 128/135 BRAM tiles. The
private `build/MCR_GameBub_games_v0.6.0.zip` contains all 19 verified ROMs,
PROM, metadata, bitstream and install/checksum files; it is not uploaded to
GitHub. The bitstream embeds revision `80ab2884e1a2`; subsequent validation
and documentation changes do not change production RTL.

`build/speech-reference-final.log` passes the primary four-state comparison:
real firmware, MC6802/PIAs/TMS5200, actual SRAM pin timing/scheduler versus
the source one-clock ROM, identical CPU bus execution and audio throughout
startup and a phrase segment. Audio changes 21,820 times across 136,747
captured samples; the command handler reads the correct two nibbles. A
separate reset probe also passes with MCR's one-clock delayed restart; the
reset hypothesis was ruled out and no production reset change was made.

The full host upload is checked against all 16,384 speech-ROM bytes in SRAM,
not just CRC recognition. A focused MCR3 game snapshot keeps the actual
host/memory, MCR3 video/main CPU, SSIO, controls and speech board, omitting
only the three unselected engines. Its frame 120 is byte-identical to the
full four-family snapshot (SHA256
`dfc1d5fbd49508f7b834f5fd1b953976f5d6993f91b146fa3b7a3a638d844c1c`).
Natural coin/start input during the title sequence did not establish speech.
The final command-path check uses the branch's MAME reference mechanism:
request $2B via E4D6 and E420 bit 4, leaving the real game CPU and SSIO to
generate OP4. This mechanism was cross-checked with local MAME, which emits
OP4=1B then 02 through the game's own routines. The first combined run
already produced streaming, nonzero speech, but its test assertion used the
source's `seen` debug flag. That two-bit edge counter saturates only after
three edges, so a single complete command pulse (two edges) leaves it low.
The corrected check requires the actual command counter, streaming and
nonzero TMS audio. It does not weaken speech into an address-bus-only test.

The corrected end-to-end check passes in
`build/speech-game-verified.log`: the real Environmental main CPU and SSIO
generate a command from the software request, the speech CPU streams LPC,
the TMS produces nonzero audio, and 162 complete frames pass all raster and
audio checks. The frame-120 full/focused parity check also passes. The
updated full-core testbench compiles/elaborates under Xsim as well
(`build/speech_tb_compile.log`, `build/speech_tb_elaborate.log`). These are
simulation results; handheld gameplay and listening remain a device test.
The hardware-test ZIP was provided to the owner while checks finished.


## 2026-10-15: device speech confirmation and public v0.6.0 packaging

The owner reports speech sounds great and explicitly requests a ROM-free
release with a README and standalone HTML converter. This authorizes the
binary release using the published rotation framework fork. Preserve the
exact tested bitstream built from 80ab288; hardware sources have not changed.
The public packager uses an explicit file allowlist independent of private
SD-card staging, and includes metadata, offline converter, installation and
control instructions, supported-output catalog, component notices and hashes.
No game ROM, SSIO PROM or sound sample is included. The owner also requests
a separate private archive of their local MAME ZIPs for converter testing;
that archive must never be uploaded to GitHub.

Release checks pass: public ZIP integrity, exact allowlist and per-file
SHA-256 verification; all core metadata and bitstream bytes match the
owner-tested private v0.6.0 bundle. The private converter pack contains 18
original MAME archives covering 19 supported games, plus the existing user
PROM and standalone converter. After extracting that pack, the converter
regression produces all 19 files byte-identical to their MRA references;
renamed/missing/corrupt chip and malformed/export ZIP checks also pass.

The owner requested a shareable framework-change write-up and short Discord
bullets. `docs/FRAMEWORK_ROTATION_SUMMARY.md` describes the exact three-file
rotation patch, opt-in interface and requested-status register, scaling,
clock-domain transfer, unchanged menu/readback paths, no-extra-framebuffer
cost, MCR grip mapping, existing verification and outstanding upstream checks.
It distinguishes implemented rotation from the broader video design proposals.
