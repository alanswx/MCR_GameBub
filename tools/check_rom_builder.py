#!/usr/bin/env python3
"""Check offline builder against local MAME ZIPs and mra-tools-produced ROMs.

No test ROM bytes are saved outside ignored scratch/. Uses Node and optionally
native headless Chrome; ZIPs and reference ROMs must be supplied locally.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--mame-dir', type=Path, default=Path.home() / 'mister/cardbackup/MiSTer_Data/games/mame')
    p.add_argument('--reference-dir', type=Path, default=ROOT / 'scratch/roms')
    p.add_argument('--browser', action='store_true', help='also test native browser ZIP decoding and file upload UI')
    args = p.parse_args()
    subprocess.run(['python3', str(ROOT / 'tools/generate_rom_builder.py'), '--check'], check=True)
    html = (ROOT / 'web/MCR-ROM-Builder.html').read_text()
    script = html.split('<script>\n', 1)[1].split('</script>', 1)[0]
    cases = []
    for game in json.loads((ROOT / 'gamedb/games.json').read_text()):
        path = args.mame_dir / game.get('mame_zip', game['key'] + '.zip')
        reference = args.reference_dir / (game['key'] + '.rom')
        data = reference.read_bytes()
        if hashlib.md5(data).hexdigest() != game['md5']:
            raise SystemExit(f'Bad reference ROM: {reference}')
        cases.append(dict(key=game['key'], zip=str(path.resolve()), reference=str(reference.resolve()),
                          sha256=hashlib.sha256(data).hexdigest()))
    scratch = ROOT / 'scratch'
    scratch.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='rom-builder-test-', dir=scratch) as folder:
        folder = Path(folder)
        (folder / 'builder.cjs').write_text(script + '\nmodule.exports.recipes = RECIPES;\n')
        (folder / 'cases.json').write_text(json.dumps(cases))
        test = r'''
const assert=require('node:assert/strict'),fs=require('node:fs'),crypto=require('node:crypto'),zlib=require('node:zlib');
// Node 19 lacks deflate-raw DecompressionStream. Browser mode below tests the native API.
global.DecompressionStream=class {constructor(format){assert.equal(format,'deflate-raw');const parts=[];const stream=new TransformStream({transform(chunk){parts.push(chunk);},flush(c){c.enqueue(zlib.inflateRawSync(Buffer.concat(parts)));}});this.readable=stream.readable;this.writable=stream.writable;}};
const api=require('./builder.cjs'),cases=require('./cases.json');
async function rejects(action,pattern){await assert.rejects(action,pattern);}
(async()=>{
const combined=new Map(),files=[];
for(const test of cases){
 const data=fs.readFileSync(test.zip),entries=api.zipEntries(data);
 for(const entry of entries){const list=combined.get(entry.crc)||[];list.push(entry);combined.set(entry.crc,list);}
 const recipe=api.recipes.find(g=>g.key===test.key),result=await api.assemble(recipe,combined);
 assert.deepEqual(Buffer.from(result),fs.readFileSync(test.reference));
 assert.equal(crypto.createHash('md5').update(result).digest('hex'),recipe.md5);
 files.push({name:`roms/MCR/${recipe.name}.rom`,data:result});
 console.log(`PASS ${test.key}: byte-identical to MRA tool output`);
}
const kick=api.recipes.find(g=>g.key==='kick');
await rejects(()=>api.assemble(kick,new Map()),/Missing/);
const renamed=new Map([...combined].map(([crc,list])=>[crc,list.map(e=>({...e,name:'renamed.bin'}))]));
assert.equal(api.crc32(await api.assemble(kick,renamed)),kick.crc32);
const broken=new Map(combined),first=kick.parts.find(p=>p.crc),entry=combined.get(first.crc)[0];
broken.set(first.crc,[{...entry,data:undefined,method:0,compressed:new Uint8Array(entry.size)}]);
await rejects(()=>api.assemble(kick,broken),/Corrupt ZIP entry/);
assert.throws(()=>api.zipEntries(new Uint8Array(50)),/valid ZIP/);
let zip=new Uint8Array(await api.storeZip(files).arrayBuffer());
const exported=api.zipEntries(zip);assert.equal(exported.length,cases.length);
for(let i=0;i<files.length;i++)assert.deepEqual(await api.unpack(exported[i]),files[i].data);
fs.writeFileSync('export.zip',zip);
// Reject encryption, unsupported compression, oversized entries, ZIP64, and truncation.
const eocd=zip.length-22,dir=new DataView(zip.buffer).getUint32(eocd+16,true);
for(const [offset,width,value,pattern] of [[dir+8,2,1,/Encrypted/],[dir+10,2,99,/compression/],[dir+24,4,0x1000000,/size limits/],[eocd+10,2,65535,/ZIP64/]]){
 const damaged=zip.slice(),view=new DataView(damaged.buffer);view[width===2?'setUint16':'setUint32'](offset,value,true);assert.throws(()=>api.zipEntries(damaged),pattern);
}
assert.throws(()=>api.zipEntries(zip.subarray(0,zip.length-1)),/valid ZIP/);
console.log('PASS renamed CRC matching, missing/corrupt chips, malformed ZIPs, SD ZIP round-trip');
})().catch(error=>{console.error(error);process.exitCode=1;});
'''
        (folder / 'test.cjs').write_text(test)
        subprocess.run(['node', 'test.cjs'], cwd=folder, check=True)
        with zipfile.ZipFile(folder / 'export.zip') as archive:
            if archive.testzip() is not None or len(archive.namelist()) != len(cases):
                raise SystemExit('Export file count or ZIP integrity is invalid')
        if args.browser:
            browser = shutil.which('google-chrome') or shutil.which('chromium')
            if not browser:
                raise SystemExit('Chrome/Chromium not found')
            browser_cases = [{**case, 'zip': base64.b64encode(Path(case['zip']).read_bytes()).decode()}
                             for case in cases]
            harness = r'''
(async()=>{
try {
 const cases=CASES;
 const all=new Map();let verified=0;
 for(const test of cases){
   const data=Uint8Array.from(atob(test.zip),c=>c.charCodeAt(0));
   for(const entry of zipEntries(data)){const list=all.get(entry.crc)||[];list.push(entry);all.set(entry.crc,list);}
   const result=await assemble(RECIPES.find(g=>g.key===test.key),all);
   const sha=[...new Uint8Array(await crypto.subtle.digest('SHA-256',result))].map(v=>v.toString(16).padStart(2,'0')).join('');
   if(sha!==test.sha256)throw Error('SHA mismatch: '+test.key);
   verified++;
 }
 const upload=new DataTransfer();
 for(const test of cases)upload.items.add(new File([Uint8Array.from(atob(test.zip),c=>c.charCodeAt(0))],test.key+'.zip'));
 const input=document.getElementById('files');input.files=upload.files;input.dispatchEvent(new Event('change'));
 for(let attempt=0;attempt<1000;attempt++){
   if(!input.disabled)break;
   await new Promise(resolve=>setTimeout(resolve,10));
 }
 const links=document.querySelectorAll('#games a[download]');
 if(links.length!==cases.length||document.getElementById('save').disabled)throw Error('File upload UI did not prepare all configured games');
 const promBytes=Uint8Array.from(atob(PROM_BASE64),c=>c.charCodeAt(0));
 const promUpload=new DataTransfer();promUpload.items.add(new File([promBytes],'ssio.prom'));
 input.files=promUpload.files;input.dispatchEvent(new Event('change'));
 for(let n=0;n<1000&&input.disabled;n++)await new Promise(resolve=>setTimeout(resolve,10));
 if(!document.getElementById('notice').textContent.includes('Sound timing PROM ready'))throw Error('PROM upload failed');
 document.getElementById('clear').click();
 const promZip=new DataTransfer();promZip.items.add(new File([storeZip([{name:'82s123.bin',data:promBytes}])],'timing.zip'));
 input.files=promZip.files;input.dispatchEvent(new Event('change'));
 for(let n=0;n<1000&&input.disabled;n++)await new Promise(resolve=>setTimeout(resolve,10));
 if(!document.getElementById('notice').textContent.includes('Sound timing PROM ready'))throw Error('PROM ZIP extraction failed');
 input.files=upload.files;input.dispatchEvent(new Event('change'));
 for(let n=0;n<1000&&input.disabled;n++)await new Promise(resolve=>setTimeout(resolve,10));
 const done=document.createElement('pre');done.id='test-result';done.textContent='BROWSER PASS: '+verified+' native Deflate/CRC/SHA matches; catalog upload UI; PROM upload and ZIP extraction';document.body.append(done);
}catch(error){const done=document.createElement('pre');done.id='test-result';done.textContent='BROWSER FAIL: '+error.stack;document.body.append(done);}
})();
'''.replace('CASES', json.dumps(browser_cases)).replace('PROM_BASE64', json.dumps(base64.b64encode((args.reference_dir / 'ssio.prom').read_bytes()).decode()), 1)
            page = folder / 'browser-test.html'
            page.write_text(html.replace('</script>', harness + '\n</script>'))
            # Wait on the live browser, rather than --dump-dom virtual time, which
            # may finish before asynchronous native ZIP streams are drained.
            import time
            import urllib.request
            import websocket
            profile = folder / 'chrome-profile'
            process = subprocess.Popen([browser, '--headless', '--no-sandbox', '--disable-gpu',
                                        '--disable-dev-shm-usage', '--no-first-run',
                                        '--remote-debugging-port=0', '--remote-allow-origins=*',
                                        f'--user-data-dir={profile}', page.as_uri()],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            connection = None
            try:
                for _ in range(200):
                    if (profile / 'DevToolsActivePort').is_file():
                        break
                    if process.poll() is not None:
                        raise RuntimeError('Chrome exited before startup (sandbox IPC may require escalation)')
                    time.sleep(.05)
                port = (profile / 'DevToolsActivePort').read_text().splitlines()[0]
                with urllib.request.urlopen(f'http://127.0.0.1:{port}/json') as response:
                    tabs = json.load(response)
                tab = next(tab for tab in tabs if tab.get('type') == 'page')
                connection = websocket.create_connection(tab['webSocketDebuggerUrl'], timeout=60)
                time.sleep(1)  # Allow the initial file:// navigation to replace about:blank.
                expression = """(async()=>{for(let n=0;n<3000;n++){
                  const result=document.getElementById('test-result');if(result)return result.textContent;
                  await new Promise(resolve=>setTimeout(resolve,10));}return 'Timed out';})()"""
                connection.send(json.dumps(dict(id=1, method='Runtime.evaluate',
                                                params=dict(expression=expression, awaitPromise=True, returnByValue=True))))
                while True:
                    message = json.loads(connection.recv())
                    if message.get('id') == 1:
                        break
                outcome = message.get('result', {}).get('result', {}).get('value', str(message))
                if not outcome.startswith('BROWSER PASS:'):
                    raise RuntimeError(outcome)
                print(outcome)
                connection.send(json.dumps(dict(id=2, method='Page.captureScreenshot', params=dict(format='png'))))
                while True:
                    message = json.loads(connection.recv())
                    if message.get('id') == 2:
                        break
                (scratch / 'rom-builder-preview.png').write_bytes(base64.b64decode(message['result']['data']))
            finally:
                if connection:
                    connection.close()
                process.terminate()
                process.wait(timeout=10)
                time.sleep(.5)  # Chrome helpers finish writing their temporary profile.
    print('ROM builder checks passed. No test ROM data was committed.')


if __name__ == '__main__':
    main()
