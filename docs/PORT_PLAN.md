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
