#!/usr/bin/env bash
# Compile and elaborate the complete SV + VHDL core, including both Z80s
# and both AY chips. Real Xilinx primitives resolve from Vivado's libraries.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
python3 scripts/check_rtl.py "$@"
