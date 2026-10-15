# Source this file: puts the build tools for this repo on the PATH.
export PATH="$HOME/opt/verilator-5.052/bin:$PATH"

# Vivado: the last settings64.sh found wins, so ~/vivado (this box) comes last.
for settings in /tools/Xilinx/*/Vivado/settings64.sh /tools/Xilinx/Vivado/*/settings64.sh \
                "$HOME"/Xilinx/*/Vivado/settings64.sh "$HOME"/Xilinx/Vivado/*/settings64.sh \
                "$HOME"/vivado/*/Vivado/settings64.sh "$HOME"/vivado/Vivado/*/settings64.sh; do
    [ -f "$settings" ] && vivado_settings="$settings"
done
if [ -n "$vivado_settings" ]; then
    . "$vivado_settings"
else
    echo "env.sh: Vivado not found (install Vivado ML Standard, Artix-7 only)" >&2
fi
unset settings vivado_settings
