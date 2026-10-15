#!/usr/bin/env python3
"""Import official MCR1/MCR3 Mono, sharing the existing verified primitives."""
import argparse
from datetime import datetime,timezone
import hashlib
from pathlib import Path
import re
import subprocess
from import_mcr import ROOT,FILES,PROM_PORTS,replace,git

def static_ports(text, entity, replacements):
    declarations=''
    assignments=''
    for index,(old,width) in enumerate(replacements):
        name=f'gb_port_{index}'
        typ='std_logic' if width==1 else f'std_logic_vector({width-1} downto 0)'
        declarations+=f'signal {name} : {typ};\n'
        assignments+=f'{name} <= {old};\n'
        # Only change the selected actual, not similarly named assignments.
        text=replace(text, '=> '+old+',', '=> '+name+',')
    text=replace(text,f'architecture {"struct" if entity in ("mcr1","mcr3mono") else "rtl"} of {entity} is',f'architecture {"struct" if entity in ("mcr1","mcr3mono") else "rtl"} of {entity} is\n'+declarations)
    anchor='-- Z80-CTC (MK3882)' if entity in ('mcr1','mcr3mono') else ('-- U6' if entity=='sounds_good' else 'cpu09 : entity work.cpu09')
    return replace(text,anchor,assignments+anchor)

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--check',action='store_true');args=p.parse_args()
    outputs={};manifests={}
    for family in ('1','3Mono'):
        src=ROOT.parent/f'Arcade-MCR{family}_MiSTer';url=f'https://github.com/MiSTer-devel/Arcade-MCR{family}_MiSTer.git'
        if git(src,'status','--porcelain','--untracked-files=all'):raise SystemExit('Dirty source clone')
        commit=git(src,'rev-parse','HEAD');manifest=ROOT/f'scripts/import_mcr{family.lower()}.txt'
        if args.check:
            if f'Commit: {commit}\n' not in manifest.read_text():raise SystemExit('Source revision differs')
        else:
            remote=subprocess.check_output(['git','ls-remote','--symref',url,'HEAD'],text=True)
            if f'{commit}\tHEAD' not in remote:raise SystemExit('Update clean source to live HEAD first')
        for name in FILES:
            source=src/'rtl'/name
            if name=='mcr3.vhd' or not source.exists():continue
            if source.read_bytes()!=(ROOT.parent/'Arcade-MCR3_MiSTer/rtl'/name).read_bytes():raise SystemExit(f'Shared primitive differs: {name}')
        names=['mcr1.vhd'] if family=='1' else ['FX68K/fx68k.vhd','cpu09l_128a.vhd','pia6821.vhd','turbo_cheap_squeak.vhd','sounds_good.vhd','mcr3mono.vhd']
        for name in names:
            text=(src/'rtl'/name).read_text();entity=Path(name).stem
            if name=='FX68K/fx68k.vhd':
                text=replace(text,'package fx68k is','package gb_fx68k is')
            if entity=='mcr1':
                text=replace(text,'port(\n','port(\n'+PROM_PORTS)
                text=replace(text,'sound_board : entity work.mcr_sound_board\nport map(\n','sound_board : entity work.mcr_sound_board\nport map(\n prom_addr => prom_addr,\n prom_data => prom_data,\n prom_wr => prom_wr,\n')
                text=static_ports(text,entity,[('not pause',1),('not ctc_ce',1),('(dl_wr or dl_nvram_wr) and dl_nvram',1),('clock_40 and (not pause)',1)])
            elif entity=='mcr3mono':
                text=static_ports(text,entity,[('not ctc_ce',1),('(dl_wr or dl_nvram_wr) and dl_nvram',1),('cpu_addr(0) & cpu_do',9)])
            elif entity=='sounds_good':
                text=replace(text,'use work.fx68k.all;','use work.gb_fx68k.all;')
                text=static_ports(text,entity,[('ram_we and not cpu_uds_n',1),('ram_we and not cpu_lds_n',1),('cpu_addr(1)&cpu_addr(2)',2)])
            elif entity=='turbo_cheap_squeak':
                text=static_ports(text,entity,[('cpu_addr(0)&cpu_addr(1)',2)])
            outputs[ROOT/f'rtl/mcr{family.lower()}'/Path(name).with_suffix('.vhdl')]=text
        if family=='3Mono':
            chunks=[]
            for name in ('fx68k.sv','fx68kAlu.sv','uaddrPla.sv'):
                text=(src/'rtl/FX68K'/name).read_text()
                if name=='fx68k.sv':
                    # Keep the upstream simulation-only X propagation workaround
                    # while avoiding dependence on compilation-unit macros.
                    text=replace(text,'\t`define SIMULBUGX32 1','')
                    text=replace(text,"\t\t\t`ifdef SIMULBUGX32\n\t\t\t\tauReg <= auResult;\n\t\t\t`else\n\t\t\t\tauReg <= { Dbh, Dbl } + auInpMux;\n\t\t\t`endif", "\t\t\tbegin\n\t\t\t\tauReg <= { Dbh, Dbl } + auInpMux;\n// synthesis translate_off\n\t\t\t\tauReg <= auResult;\n// synthesis translate_on\n\t\t\tend")
                    text=re.sub(r'\n`ifdef FX68K_TEST\n.*?`endif\s*$', '\n',text,flags=re.S)
                    for file,array,width,count in (('microrom.mem','uRam',17,1024),('nanorom.mem','nRam',68,336)):
                        words=(src/'rtl/FX68K'/file).read_text().split();assert len(words)==count and all(re.fullmatch('[01]{'+str(width)+'}',w) for w in words)
                        text=replace(text,f'$readmemb("{file}", {array});','\n'.join(f"{array}[{i}] = {width}'b{word};" for i,word in enumerate(words)))
                macros=dict(re.findall(r'^\s*`define\s+(\w+)\s+([^\n]+)',text,re.M))
                text=re.sub(r'^\s*`define[^\n]*\n','\n',text,flags=re.M)
                for symbol,value in macros.items():text=re.sub(r'`'+re.escape(symbol)+r'\b',lambda m:value,text)
                if re.search(r'^\s*`(?:include|define|ifdef|else|endif)',text,re.M):raise SystemExit('Unexpanded preprocessor dependence')
                chunks.append(text)
            outputs[ROOT/'rtl/mcr3mono/fx68k.sv']='\n'.join(chunks)
        manifests[manifest]=f'Upstream: {url}\nCommit: {commit}\nVerified UTC: {datetime.now(timezone.utc).date()}\nPatches: static VHDL-93 port expressions; MCR1 SD-loaded shared SSIO PROM; FX68K self-contained CPU control-store initialization and macro expansion, preserving its simulation-only workaround.\nShared primitives: byte-identical to verified MCR3 source.\n'
    for target,text in {**outputs,**({} if args.check else manifests)}.items():
        if args.check:
            if target.read_text()!=text:raise SystemExit(f'Import differs: {target}')
        else:target.parent.mkdir(parents=True,exist_ok=True);target.write_text(text)
    print(f'{"Verified" if args.check else "Imported"} {len(outputs)} new board/CPU files')

if __name__=='__main__':main()
