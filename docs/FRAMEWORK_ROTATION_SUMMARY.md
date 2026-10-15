# Game Bub framework: optional game-picture rotation

The MCR port adds an optional framebuffer read transform to the Game Bub
framework. It lets a core rotate its game picture at runtime without another
framebuffer. Portrait games can be shown upright while holding the Bub normally,
or played with the handheld turned in either direction. The firmware menu keeps
its normal orientation.

This is the implemented change used by the
[MCR Game Bub v0.6.0 release](https://github.com/alanswx/MCR_GameBub/releases/tag/v0.6.0).
The wider video-memory and scaling ideas in
[FRAMEWORK_CHANGES.md](FRAMEWORK_CHANGES.md) are design proposals, not additional
implemented framework features.

## Why it was needed

The rev 4 LCD is a portrait panel mounted sideways. The framework already
compensates for that mounting, but its `displayRotate` parameter is fixed when
the bitstream is built. It does not select the orientation of individual games.
MCR includes both landscape and portrait games, so we needed a separate,
runtime transform of the game layer.

Rotating framebuffer read addresses reuses the existing two framebuffers.
It avoids the RAM cost of storing another rotated copy of the picture.

## What changed in the framework

The patch changes three Scala files: 141 added lines and two removed lines.
Paths here are relative to the framework repository.

| File | Change |
|---|---|
| `src/main/scala/net/gamebub/framework/interface/VideoTransformV0.scala` | Optional `videoTransform` interface carrying a two-bit clockwise rotation request: 0, 90, 180 or 270 degrees. |
| `src/main/scala/lib/video/FramebufferTransform.scala` | Maps output coordinates back to the existing row-major framebuffer, computes picture bounds and centering, and latches orientation changes at frame boundaries. |
| `src/main/scala/platform/handheld/HandheldTop.scala` | Detects the optional interface, synchronizes its request, and connects the transform to LCD and HDMI framebuffer reads. Adds an informational register for opted-in cores. |

Quarter turns fit the rotated picture to the available display area using
constant-ratio nearest-pixel scaling. For MCR, the stored 320×240 picture becomes
a logical 240×320 portrait picture, displayed at 360×480. Zero and 180-degree
orientations retain the existing integer-scale behavior.

The address mapper accounts for framebuffer/filter read latency along the
output's scan axis. It preserves the coordinate widths when lookahead wraps
through blanking, including the LCD's column-oriented scan.

The two-bit request crosses clock domains through an XPM handshake, then takes
effect at an output frame boundary during blanking. This prevents orientation
changes partway through a visible frame. Register `0x0108` reports the core's
**requested** transform; it is informational, not a firmware rotation control,
and does not report the independently latched scanout state.

## Compatibility and memory

Cores opt in by declaring `videoTransform` as a `VideoTransformV0` interface.
Without it, elaboration retains the original read path and register map. For
an opted-in core requesting rotation zero, the original read-address path is
still selected.

The change leaves LCD mounting compensation, menu overlay composition,
framebuffer writes, double buffering and stored-frame readback on their
existing paths. LCD and HDMI both use the game transform; the menu is composed
separately and keeps its original orientation. Screenshot readback remains in
the stored framebuffer's orientation.

There is **no additional image RAM**. The added logic consists of coordinate
arithmetic, selection logic and synchronization/control registers. The original
combined MCR rotation build retained 90/135 BRAM tiles. The later v0.6.0 core
uses 128/135 after adding more board families and speech; that increase is not
an extra rotation framebuffer. No isolated LUT-cost measurement is claimed.

## What belongs to the MCR core

The MCR core supplies the user-facing portrait setting and maps the D-pad to
the selected grip. These are core changes, not framework or firmware changes:

| MCR portrait setting | Framework rotation for MCR's sideways source raster |
|---|---|
| Upright, normal handheld grip | 90 degrees clockwise |
| Hold sideways clockwise | 0 degrees |
| Hold sideways counterclockwise | 180 degrees |

The framework interface also supports 270 degrees. The MCR setting names
describe how to hold the handheld; the interface values describe how to
transform the source picture. No firmware update was needed.

## Validation and remaining upstream work

- The production address mapper passed 1,618,944 coordinate cases covering all
  four rotations, LCD/HDMI scan axes, picture bounds, fractional scaling,
  read lookahead and unsigned coordinate wraparound.
- Frame-boundary tests verified that a request does not change the active
  orientation during a visible frame.
- Generated default HDL for ColecoVision and Apple IIgs matched the upstream
  baseline exactly after excluding source comments: 14 modules per core.
- Coordinate-coded LCD/HDMI image rendering and the read-latency model passed.
  MCR builds passed routed timing without adding framebuffer RAM.
- The owner confirmed upright portrait video and both sideways grips on the
  handheld. Both sideways grips remain awkward to hold.

The regression entry point in the MCR repository is
`python3 scripts/check_rotation.py --defaults`, after sourcing `scripts/env.sh`.
Separate routed builds of the unchanged ColecoVision/Apple IIgs ports and
physical HDMI/dock and menu-overlay checks remain outstanding for an upstream
submission. Simulated HDMI coverage is not a physical dock test.

## Source and review links

- Framework fork and branch:
  [alanswx/framework, feature/video-rotation](https://github.com/alanswx/framework/tree/feature/video-rotation).
- Exact implementation:
  [6e5adf7ed3d8776f504d55e6dbb8d6fcc5cfa930](https://github.com/alanswx/framework/commit/6e5adf7ed3d8776f504d55e6dbb8d6fcc5cfa930),
  based on upstream `db9d3b0e7989db4a8edc66e47b843097d71f078c`.
- Complete review patch:
  [framework-video-rotation.patch](patches/framework-video-rotation.patch).
- Framework source remains a pinned submodule of
  [alanswx/MCR_GameBub](https://github.com/alanswx/MCR_GameBub).

The change is published in the fork and used by the MCR release. It has not
been merged upstream, and no upstream pull request has been opened.
