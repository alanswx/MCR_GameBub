# Framework changes: video memory and scaling

Why MCR does not fit the Game Bub framework as it is, and how we change the
framework so the changes are worth sending to its author: opt-in,
general-purpose, and harmless to every existing core. This file is the
working design and, later, the draft of the upstream pull request. Keep it
current.

Framework: `framework/` = github.com/gamebub/framework `db9d3b0` (v1.1-beta).
Paths below are relative to it; line numbers are for `db9d3b0`.

## 1. How video works today

* **It is built per core.** `HandheldTop` (`src/main/scala/platform/handheld/
  HandheldTop.scala`) is a Chisel program run with the core class and the
  board revision. It asks the core which interfaces it declares
  (`core.getInterface(...)`) and builds itself around them. Every
  bitstream carries its own copy.
* **The firmware sees the result through registers:** framework version
  `0x0000` (`B0000001`, line 443), video size `0x0100` (447), colour depth
  `0x0104` (449). The menu overlay is written at `0xF2…` and the picture
  can be read back at `0xF3…` (489-490).
* **Frame store** (line 541):
  * two `SRAM(videoWidth * videoHeight, colour bits)` memories, which
    Vivado makes block RAM;
  * the core writes one on its own clock, with x/y counters reset by
    hblank/vblank (849-890);
  * at vblank the buffers swap and `regLastFrameComplete` names the
    finished one (874).
* **Read side, on `clock_av`** (569):
  * `clock_av` is a `BUFGMUX_CTRL` (`verilog/handheld/top.sv:165`) between
    the core's LCD clock `clk_dpi` and the framework's 27 MHz HDMI clock.
    `common.xdc:38` makes them exclusive by name, which is why cores must
    call the net `clk_dpi`.
  * Scale = `min(screenW / W, screenH / H)`, one whole number for both axes
    (676 for HDMI at 720 x 480; 720 for the LCD at 800 x 480,
    `displayOffsetX = -28`), centred.
  * Address = `(y / scale) * W + x / scale`, with the read latency (3) plus
    the filter's latency added on the scan axis.
* **The rev 4 LCD is a 480 x 800 portrait panel mounted sideways**
  (`displayRotate = true`, line 73 on; the axes are swapped at 713). It
  scans down the columns of the picture while the core writes along the
  rows.
  * That is the real reason for a full frame store: a line buffer cannot
    turn rows into columns.
  * HDMI scans rows, but at a fixed 720 x 480 at 60 Hz, independent of the
    core's frame rate, so it also needs a whole stored frame.
* **Frame pacing:** the LCD driver (`display/ILI9806E.scala`) stretches its
  vertical blanking to follow the core's frame period, and switches
  buffers only between frames (`lastRenderedFrame` / `displayFrame`), so
  there is no tearing. HDMI takes the last complete frame at the start of
  each of its frames.
* **Firmware menu:**
  * a separate overlay memory (360 x 240, 2 bits per pixel), written by the
    MCU over SPI;
  * scaled by its own factor and drawn over the picture after scaling;
  * independent of how the core's picture is stored.
* **Picture readback** (`0xF3`, line 822): the MCU reads the last complete
  frame through the write port's read/write port, and core writes stall
  meanwhile. Presumably for screenshots; check how the firmware uses it.
* **Video filter** (`interface/VideoFilterBasicV0.scala`, used at 240):
  * optional core logic between the frame store and the scaler;
  * clocked by `clock_av`, stored bits in, RGB888 out, with a declared
    latency;
  * so core logic already runs inside the display path.

## 2. The cost, and the problems it causes

Frame store = 2 x W x H x colour bits, from 135 BRAM36 on the XC7A100T:

| Picture | Bits | BRAM36 | Problem |
|---|---|---|---|
| 284 x 240 (ColecoVision) | 9 | ~34 | fine; 1:1 pixels, narrower than 4:3; border on/off needs a fixed size |
| 320 x 200 (IIgs, halved from 640) | 9 | ~32 | 640 x 200 would show 1x as a squashed strip; 640 x 400 would need ~4.6 Mbit |
| 512 x 480 (MCR) | 9 | ~135 | all of the chip |
| 512 x 480 (MCR, palette index) | 6 | ~90-96 if packed well | tight; 20% too narrow at 1x |
| 224 x 288 (vertical arcade) | any | small | shows 1x, a small picture in the middle |

Summary for the author:
* Screen size, aspect and memory all follow from the declared W x H.
* A core cannot choose where the frames live (block RAM, SRAM, SDRAM),
  single or double buffering, separate axis scales, a fractional stretch,
  a crop window or rotation.

## 3. Rules for our changes

1. **Opt-in, and bit-identical by default.** A core that declares what it
   declares today (`VideoV0`, optionally `VideoFilterBasicV0`) gets exactly
   today's hardware. New features come as new optional parameters with
   today's values as defaults, or as a new interface version (`VideoV1`)
   matched next to `VideoV0`, the way `getInterface` matching already
   works.
2. **The framework keeps owning:**
   * LCD and HDMI timing, the `clock_av` switch and docking;
   * scaling, centring and rotation;
   * the overlay and mixing it in;
   * frame pacing;
   * the SPI register map and memory map.
   Nothing a core opts into may break the firmware's menu, HDMI, the LCD or
   readback. If a mode cannot support readback, say so in a register; don't
   return garbage.
3. **Additive firmware contract.** Existing registers keep their meaning
   (`0x0100` stays the stored frame size). New information goes into
   unused read-only registers (for example the active crop, scale per
   axis, rotation, store kind and capability bits). Runtime controls are
   new read-write registers. Bump the version register only if the author
   wants that.
4. **Small, separate, reviewable commits,** one feature each, each with its
   reason, its cost and a test. No reformatting of untouched code.
5. **Useful beyond MCR:** every change is justified by at least two cores.
   The table above has the ColecoVision and IIgs cases.
6. **Proved:**
   * a scanout testbench for the read path (none exists today);
   * ColecoVision and IIgs rebuilt on the modified framework with the new
     options off, showing identical behaviour and resource use;
   * the user's hardware test on the LCD, HDMI (dock) and the firmware menu
     over a game.

## 4. Candidate changes, in order

1. **Scaling in the read-address path.** Pure arithmetic, no memory
   change:
   * **separate horizontal and vertical scale:** 640 x 200 at 1 x 2 (IIgs
     at full width), 512 x 240 at 1 x 2;
   * **optional fractional horizontal stretch** (nearest pixel, a small
     step counter instead of the divide), for pixel aspect: 4:3 for MCR,
     ColecoVision, NES;
   * **runtime crop window inside the declared maximum** (border on/off,
     overscan, machines that change mode);
   * **rotation 0/90/180/270:** the rev 4 path already swaps axes, so
     rotating the source is nearly free. Vertical games fill the screen
     with the handheld on its side.

   Scales are recomputed for each output (800 x 480 LCD, 720 x 480 HDMI)
   and exposed in registers. Settable from the core (parameters and
   ports) and, where it makes sense, from the firmware.
2. **Frame store packing:** build narrow pixel widths (5-7 bits) from
   power-of-two-wide block RAMs instead of letting Vivado use 9-bit-wide
   primitives. Document the "palette index + `VideoFilterBasicV0`" pattern
   for palette machines. This makes MCR (6 bits) fit at full resolution.
3. **Store options:**
   * **single buffering** (half the RAM, tearing documented: mild on HDMI,
     diagonal on the sideways LCD);
   * **an external store,** for cores that don't use the SRAM (512 KiB: one
     512 x 480 x 16-bit frame) or the SDRAM (needs a small tile cache,
     because the LCD reads columns).
4. **Frame store interface (`VideoV1`), the general answer:**
   * the framework sends read requests (frame, x, y) on `clock_av` in the
     active output's order;
   * the core answers after a declared latency, reports "frame N
     complete", and declares whether it supports readback;
   * the framework keeps timing, scaling, rotation, overlay, docking,
     pacing and registers;
   * today's two block RAMs become the default implementation, used by
     every `VideoV0` core.

   This lets vector games, palette machines, SDRAM frames and future
   designs pick their own storage. Propose it to the author before
   building it.
5. **Not video, found on the way:**
   * per-core RTL folders for repos with several core classes
     (`build_core.py` takes all of `rtl/` for every class);
   * a framework-owned LCD PLL (removes the `clk_dpi` naming rule and the
     porch limit);
   * MacLC's issues #3-#7.

## 5. Process

* **Fork** `gamebub/framework` to `alanswx/framework` (ask the user first),
  with one branch per change based on `db9d3b0`.
* **This repo:** a branch here points the submodule at the fork. `main`
  stays on upstream.
* **Licence:** a modified framework puts the bitstream under CERN-OHL-S
  (`framework/LICENSE`, the CERN-OHL-W grant needs the framework
  unmodified). Our cores are GPL-3.0 and contain Dar's "educational use"
  files, so no bitstream built on the fork is released until the change
  is merged upstream, unless the user decides otherwise.
* **Before writing code for each change,** add a short design note here,
  covering:
  * the problem, with at least two cores;
  * the interface (Scala parameters, ports, registers);
  * the default (unchanged);
  * the cost in LUTs and block RAM;
  * the test.
* **When a change is proven,** write the upstream description from that
  note, and give it to the user to send. Don't open pull requests or
  issues on `gamebub/framework` yourself.

## 6. Portrait game rotation: concrete design

The user authorized continuing the combined core with Satan's Hollow and
requested both upright and sideways play, defaulting to upright because
holding the Bub sideways may be awkward. The existing `displayRotate` is a
board build parameter for the LCD mounting, not a runtime orientation
control. A game-specific transform belongs in frame-store read addressing.

Implement an optional `VideoTransformV0` interface with a two-bit rotation
(0, 90 clockwise, 180, 90 counterclockwise). Cores that omit the interface
retain exactly the original elaborated read path. For an opted-in core,
rotate only the game layer; LCD mounting correction and firmware overlay
remain as before. CDC the request coherently and latch it at an output
frame boundary. Fit quarter-turn pictures to the screen using a constant
rational scale: MCR's stored 320x240 becomes upright 240x320, displayed at
360x480 on both LCD and HDMI. Rotation zero uses the legacy integer scale.
This reuses both existing frame stores and adds no image memory. The only
cost is address arithmetic, muxing, and a small control CDC. Expose the
active requested transform as an additive informational register.

This is useful for portrait MCR games (Satan's Hollow, Tron, MCR1) and for
other arcade ports that emit a native sideways raster. Ordinary cores such
as ColecoVision and Apple IIgs must elaborate identically without opting in.

Tests: generate their baseline and modified Verilog and compare exactly;
exercise the synthesized address mapper with asymmetric coordinate-coded
images, all four rotations, both output scan axes, borders and read delay;
check that runtime changes latch only on frame boundaries. Then route the
MCR bitstream, recheck the existing games and capture Satan's Hollow.
Changes stay on local feature branches for review. No remote fork, push,
or public release is created by this work.

Implementation is local framework commit `6e5adf7` on `feature/video-rotation`.
The complete source change is also preserved in
`docs/patches/framework-video-rotation.patch` for review/reproduction before
any remote fork is created. Apply it to clean framework `db9d3b0` when the
local feature commit is unavailable. `scripts/check_rotation.py --defaults`
runs the mapper regression and checks unchanged-core elaboration.


The final MCR portrait build passes routed timing at unchanged frame-store
RAM use (90/135 BRAM tiles total for the combined core). Coordinate-coded
LCD/HDMI image rendering through the actual mapper plus read-latency model
also passes. Hardware LCD/HDMI/menu validation and separate routed builds
of the unchanged Coleco/IIgs ports remain prerequisites for an upstream
submission; the byte-identical default HDL checks are already complete.


The 0.3.2 MCR setting also exposes the opposite sideways grip. Holding the
handheld clockwise requests transform 0; holding it counterclockwise
requests transform 2 (180 degrees relative to the raw raster). Upright
requests transform 1. These use the existing four-way framework interface,
with no further framework changes and no additional framebuffer memory.
