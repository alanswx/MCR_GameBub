# MCR Game Bub v0.6.0

Combined Bally Midway MCR core for **Game Bub rev 4**, supporting 19 game sets
across MCR1, MCR2, MCR3 and MCR3 Mono. Environmental Discs of Tron speech has
been confirmed on the handheld. This package contains no game ROMs, sound
PROM data or music samples. Supply your own matching MAME sets.

## Install

1. Extract this release ZIP on your computer. Copy its `cores` folder to the
   root of your Game Bub SD card, merging it with the existing folder.
2. Open the included `MCR-ROM-Builder.html` in a current Chrome, Edge, Firefox
   or Safari browser. It works locally, even offline; it does not upload files.
3. Drop your MAME ZIPs onto the page. Multiple parent/clone ZIPs can be dropped
   together. Download the SD-card ZIP, then extract it at the SD card root,
   merging `roms` and `cores` with the existing folders.
4. **The 32-byte SSIO timing PROM is required**, including for normal sound.
   The converter extracts it from supplied MAME ZIPs when present, or you can
   drop your existing `ssio.prom` onto the page before downloading its ZIP.
   Check that `cores/alanswx.MCR/ssio.prom` exists on the card. You can also
   retain that file from an existing installation. The matching PROM has
   CRC32 `e1281ee9`; no PROM is included in this release.
5. Safely eject the SD card, insert it into the Bub, launch **Bally Midway MCR**,
   and choose a `.rom` from `roms/MCR`. The core recognizes the game and sets
   the board and controls automatically. No separate game-selection menu or
   firmware update is required for speech.

Individual `.rom` downloads from the converter can instead be copied manually
to `roms/MCR`. The converter's ZIP contains your converted ROMs and the PROM
when supplied; it does not contain the FPGA core.

## Supported sets

The converter lists the 19 exact supported revisions. Other MAME revisions
may need different chips; renaming a ZIP will not change its contents. Missing
chip messages identify what is still needed. Supply merged sets or both parent
and clone archives when appropriate. `supported-games.tsv` lists expected outputs.

Two Tigers uses the **Tron Conversion** set. Demolition Derby uses the
**MCR-3 Mono Board Version**. Tapper uses **Budweiser 840127**; Rampage uses
**Rev 3**; Max RPM uses **v2**. Environmental Discs of Tron can be extracted
from a merged `dotron.zip`; its speech firmware is included in the converted
Environmental `.rom`, with no separate speech file needed.

Extract any outer collection ZIP first, then drop the individual MAME ZIPs onto
the converter. ZIP Store/Deflate are supported; encrypted, ZIP64 and split-volume
archives are not. Use individual game archives rather than a whole collection.

## Controls and display

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
| Discs of Tron (Environmental) | Same controls as upright, with speech |
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
implemented. Upright Discs of Tron has no speech. Choose **Discs of Tron
(Environmental)** for the Squawk & Talk board, ported from the
[MCR3 speech branch](https://github.com/alanswx/Arcade-MCR3_MiSTer/tree/squawk-n-talk-speech).
Allow startup to finish, then start a game to hear its greeting. In the
Environmental version, Start also inserts a coin as in the source wrapper.
The optional cabinet
backdrop from that branch is not included. No firmware update is needed. High scores
are not saved. MCR3 Mono provides player 1 controls only. Rampage and Power Drive use
coin and action buttons to join, as on the arcade. Scrolling MCR hardware
is a separate integration.

**Portrait games** applies to Kick, Solar Fox, Satan's Hollow, Tron and Journey. **Upright**
is the default: normal grip and a 360x480 picture with side borders.
**Hold sideways (CW)** fills the landscape game area; turn the Bub clockwise.
**Hold sideways (CCW)** turns it the other way, with the joypad at the bottom.
D-pad directions follow the grip; the firmware menu keeps its normal
orientation. Allow a few seconds for startup memory/color tests and reset.

## Source and notices

The release preserves the exact owner-tested v0.6.0 bitstream, built from
source commit `80ab2884e1a2` with framework commit
`6e5adf7ed3d8776f504d55e6dbb8d6fcc5cfa930`. Later release changes are packaging,
documentation and tests. `SHA256SUMS.txt` verifies the files in this ZIP.

Source and build instructions:
https://github.com/alanswx/MCR_GameBub/tree/v0.6.0

The framework source, including the rotation changes:
https://github.com/alanswx/framework/tree/6e5adf7ed3d8776f504d55e6dbb8d6fcc5cfa930

Clone the source with `git clone --recursive https://github.com/alanswx/MCR_GameBub.git`
and check out `v0.6.0` to inspect this release. Exact imported revisions and
reproducible adaptations are recorded in `scripts/import_*.txt` and their
corresponding import scripts. The framework patch is also retained under
`docs/patches/` in the source repository.

See `NOTICE.md`, the source file notices and `licenses/` for component terms.
Imported MCR cores are by Dar; the speech implementation includes jt680x by
Jose Tejada and TMS5200 by zeldin/Mega99. No blanket licence replaces those
component terms. Keep game data and private test bundles out of public uploads.
