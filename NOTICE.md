# Source provenance

This project ports Dar's Bally Midway MCR FPGA cores to Game Bub. Imported
sources retain their copyright and licence notices; publication here does
not replace those terms with a blanket project licence.

The source repositories and exact revisions are recorded in
`scripts/import_mcr.txt`, `scripts/import_mcr2.txt`,
`scripts/import_mcr1.txt` and `scripts/import_mcr3mono.txt`:

- [MCR1](https://github.com/MiSTer-devel/Arcade-MCR1_MiSTer)
- [MCR2](https://github.com/MiSTer-devel/Arcade-MCR2_MiSTer)
- [MCR3](https://github.com/MiSTer-devel/Arcade-MCR3_MiSTer)
- [MCR3 Mono](https://github.com/MiSTer-devel/Arcade-MCR3Mono_MiSTer)

These include CPU, sound and support components by their credited authors,
including T80, FX68K and the AY-3-8910/YM2149 implementation. Dar's MCR
sources carry educational-use and ROM redistribution restrictions. The
import scripts record and reproduce the adaptations to Game Bub.

The [Game Bub framework](https://github.com/gamebub/framework) is a separate
submodule with its own `LICENSE`. The `alanswx/framework` fork contains the
optional rotation change used by this port; its complete patch is also
retained in `docs/patches/framework-video-rotation.patch`.

The standalone ROM builder contains recipes, filenames and checksums derived
from the official MRA descriptions. It contains no game ROM, PROM or sample
bytes. Users supply their own data. CPU microcode in the imported FX68K
source is part of the CPU implementation, not a game ROM.
