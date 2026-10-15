# Offline MCR ROM builder

Open **MCR-ROM-Builder.html** directly in a modern browser, then drop your own
MAME ZIP files onto it. Everything runs locally; no server or upload is involved.
The single HTML file can be copied or shared on its own.

The page recognizes the 19 exact game recipes in `gamedb/games.json`. It accepts
multiple ZIPs for merged or split sets, matches chip files by verified CRC even
when renamed, repeats/fills the MRA parts in order, and checks each assembled
ROM's size and CRC against the core's catalog. Other revisions need their own
catalog entry and core support; renaming their ZIP will not convert them.

Download games individually, or download a ZIP with the SD-card paths already
set up. Keep `cores/alanswx.MCR/ssio.prom` from the core installation, or supply
your own matching 32-byte timing PROM. The builder can also extract that PROM
from an uploaded ZIP when present. It contains no ROM or timing PROM bytes.
Install the FPGA core separately. Environmental Discs of Tron needs version
0.6.0 or later for its speech board.

ZIP input supports Store and Deflate. Compressed input needs the browser's
native `DecompressionStream("deflate-raw")`. Encrypted, split-volume and ZIP64
archives are rejected. Limits: 128 MiB per archive, 4 MiB per chip, 128 MiB total
expanded size per archive. These limits allow the supported individual game
sets; use individual ZIPs instead of an entire MAME collection archive.

## Development

Edit `rom-builder.js` and `rom-builder.template.html`, then regenerate the
standalone page using the official upstream MRA clones next to this repo:

```sh
python3 tools/generate_rom_builder.py
python3 tools/generate_rom_builder.py --check
```

The generator deliberately rejects MRA operations beyond those used by these
19 recipes. It does not pretend to interpret arbitrary MRA files.

The local regression uses your existing MAME ZIPs and ROM files previously
built by `mra-tools-c` (defaults documented in `CLAUDE.md`):

```sh
python3 tools/check_rom_builder.py
python3 tools/check_rom_builder.py --browser
```

The first command needs Node, compares all 19 outputs byte for byte and by MRA
MD5, and checks renamed/missing/corrupt chips, malformed ZIPs and ZIP export.
Node 19 uses its own zlib adapter because its stream API lacks raw Deflate.
The browser option additionally uses Chrome/Chromium and Python's
`websocket-client` to test actual native Deflate, SHA-256 of all 19 outputs,
the file upload UI, and timing PROM upload/extraction over `file://`.
Temporary test files and the preview screenshot stay in ignored `scratch/`.
