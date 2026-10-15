# Bally Midway MCR for Game Bub

Ports of the Bally Midway MCR arcade cores (MiSTer-devel `Arcade-MCR*_MiSTer`,
by Dar) to the Game Bub handheld. MCR3 first (Tapper, Timber, Discs of Tron,
Journey), then MCR2, MCR3 Mono and MCR1. The user has authorized one combined Game Bub core (`alanswx.MCR`) with
ROM auto-detection. MCR2 and MCR3 are integrated first; expand incrementally
using the Tang merge as a reference. The original MCR3 ZIP is the hardware
baseline. Read `docs/PORT_PLAN.md` first: it is the brief, with
the constraints, the design, the phases and the questions to ask the user.
`docs/FRAMEWORK_CHANGES.md` explains the video limits and how we change the
framework so that the changes can go upstream.

Two finished ports are the working templates; copy their patterns:
* `../../adam/ColecoVision_GameBub`: newest and smallest. Host protocol,
  SRAM, CRC-keyed game list, on-screen keypad and controls card, testbench,
  import script, package script, release.
* `../../iigs/Apple-IIgs_GameBub`: SDRAM controller with IDELAY tuning (read
  timing tuned on this board), SDRAM testbench model, `gb_video_out` pair
  averaging.

## Environment (misterubuntu)

* `source scripts/env.sh` puts Verilator 5.052 and Vivado 2025.2 on the PATH.
* `./mill root.buildCore --target gamebub_rev4` builds the default core
  (`MCR3`); `./mill root.buildCore --target gamebub_rev4 --core-class X`
  builds another.
* The upstream cores are cloned next to this repo:
  `../Arcade-MCR1_MiSTer`, `../Arcade-MCR2_MiSTer`, `../Arcade-MCR3_MiSTer`,
  `../Arcade-MCR3Mono_MiSTer`. Import from them with a script; never edit
  the clones.
* `../mra-tools-c` is sebdel's MRA tool (MiST), built: `../mra-tools-c/mra
  -A game.mra` in a folder holding the MRA and the MAME zip writes
  `<name>.rom` and `<name>.arc`. The `.rom` is the MRA's `index="0"` data
  only; `MOD=` and `DEFAULT=` (the DIP switches) go to the `.arc`. Rebuild
  with `make CFLAGS="-O2 -D_FORTIFY_SOURCE=0 -DHAVE_ZLIB -Isrc/junzip
  -Isrc/sxmlc -Isrc/md5"`: Ubuntu's default fortify aborts a plain build in
  `write_rom` (its output is then identical to `release/linux/mra`). Don't
  modify that clone either.
* MAME ROM sets for testing: `~/mister/cardbackup/MiSTer_Data/games/mame/`
  (also `games/hbmame/`, `_tapper/mame/tapper.zip`, `_mcrtwo/mame/`,
  `_mcrone/mame/`, and `timber.zip` at the `MiSTer_Data/` root). Built ROM
  files go in the ignored `scratch/`.
* A MiSTer at `root@10.0.2.126` runs the upstream cores
  (`/dev/MiSTer_cmd` takes `load_core` and `screenshot`), for comparison
  pictures.

## Rules

* **`framework/` is a submodule of `alanswx/framework`, pinned to rotation
  commit `6e5adf7` based on upstream `db9d3b0`.** Framework
  changes are allowed only as `docs/FRAMEWORK_CHANGES.md` describes: on a
  branch of a fork, opt-in, default behaviour bit-identical, written to be
  sent upstream. Never push to `gamebub/framework`. The user authorized the
  public fork and source push; the rotation branch is `feature/video-rotation`.
  A bitstream built on a modified framework
  falls under CERN-OHL-S (`framework/LICENSE`), so nothing built on it is
  released until the change is merged upstream, unless the user decides
  otherwise.
* Imported upstream RTL is copied by a script with exact-text patches and
  never hand-edited. Record the upstream commit it came from.
* Before starting each MCR board's port or refreshing its import, check
  the live default-branch HEAD at `MiSTer-devel/Arcade-MCR*_MiSTer` with
  `git ls-remote --symref`. Start from that newest commit, not an old
  planning pin or a cached remote-tracking ref. Verify the source clone
  is clean and its HEAD matches; if behind, fetch and fast-forward it
  without altering upstream source files. Record the full commit and
  verification date in `docs/PORT_PLAN.md` and the import manifest.
* No `` `include `` or `` `define `` reliance in `rtl/`; `.vhd` must become
  `.vhdl` (the build only collects `.v/.sv/.vhdl/.xdc`, and collects every
  one of them under `rtl/` for every core class); only RTL and `.xdc`
  files under `rtl/`.
* Never commit ROMs, MAME zips, built `.rom` files, NVRAM saves or sound
  samples. MRA files (XML, no ROM data) may be committed.
* Licence: Dar's MCR files say "Educational use only / Do not redistribute
  synthesized file with roms". MiSTer distributes these bitstreams without
  ROMs. Settle the licence for this repo with the user before publishing
  bitstream releases. The user authorized public source publication under
  the existing component notices; see `NOTICE.md`.
* Use the scratchpad or `scratch/` for temporary files, not `/tmp`.
* Commit locally after each working step. The user authorized creating and
  pushing the public source repository `alanswx/MCR_GameBub`. Keep private
  ROM-containing hardware-test bundles out of it.
* Keep `docs/PORT_PLAN.md` up to date with findings, as the other ports do.
