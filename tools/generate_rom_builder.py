#!/usr/bin/env python3
"""Generate the self-contained offline builder from checked MCR MRA recipes."""
import argparse
import json
from pathlib import Path
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def generate():
    games = json.loads((ROOT / 'gamedb/games.json').read_text())
    recipes = []
    for game in games:
        path = (ROOT / game['mra_local']) if game.get('mra_local') else ROOT.parent / f"Arcade-MCR{game['family']}_MiSTer/releases" / game['mra']
        xml = ET.parse(path)
        rom = xml.find("rom[@index='0']")
        if rom is None or rom.get('md5') != game['md5']:
            raise ValueError(f'{path}: unexpected ROM identity')
        parts = []
        for part in rom:
            if part.tag != 'part' or set(part.attrib) - {'name', 'crc', 'repeat'}:
                raise ValueError(f'{path}: unsupported recipe: {ET.tostring(part)}')
            repeat = int(part.get('repeat', '1'), 0)
            if repeat < 1:
                raise ValueError('Invalid repeat')
            if part.get('name'):
                if not part.get('crc'):
                    raise ValueError('Named ROM needs a CRC')
                parts.append(dict(name=part.get('name'), crc=part.get('crc').lower(), repeat=repeat))
            else:
                fill = ''.join((part.text or '').split())
                bytes.fromhex(fill)
                if not fill:
                    raise ValueError('Empty fill')
                parts.append(dict(fill=fill, repeat=repeat))
        recipes.append({**{k: game[k] for k in ('key', 'name', 'size', 'crc32', 'md5', 'family')},
                        'set': xml.findtext('setname'), 'zips': rom.get('zip').split('|'), 'parts': parts})
    template = (ROOT / 'web/rom-builder.template.html').read_text()
    script = (ROOT / 'web/rom-builder.js').read_text()
    return template.replace('/* RECIPES */', 'const RECIPES = ' + json.dumps(recipes, separators=(',', ':')) + ';').replace('/* SCRIPT */', script)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    output = ROOT / 'web/MCR-ROM-Builder.html'
    generated = generate()
    if args.check:
        if not output.is_file() or output.read_text() != generated:
            raise SystemExit('ROM builder is stale; run tools/generate_rom_builder.py')
    else:
        output.write_text(generated)
    print(f'{output.relative_to(ROOT)}: {"verified" if args.check else "generated"}')


if __name__ == '__main__':
    main()
