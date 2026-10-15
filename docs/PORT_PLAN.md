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
capture byte for byte. An extended Domino boot run with coin/start input
is still in progress.

Next integration boundaries: add MCR1 with a fresh upstream verification,
retain per-family reset isolation, and measure the cost before hoisting
memories. Bring in the Tang shared graphics/scratch interfaces only where
the resource report justifies them. MCR3Scroll needs separate review of its
Cheap Squeak Deluxe audio/68000 ROM routing. Portrait games also need a
usable orientation/control plan. Each step must keep stock-ROM recognition
and the three-game baseline passing; a family engine's presence alone does
not make every game supported.
