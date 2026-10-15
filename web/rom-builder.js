/* Source for MCR-ROM-Builder.html. No ROM bytes or external runtime dependencies. */
'use strict';
const crcTable = Uint32Array.from({length:256}, (_, n) => {
  for (let k=0;k<8;k++) n=(n>>>1)^((n&1)?0xedb88320:0);
  return n>>>0;
});
function crc32(bytes) {
  let crc=0xffffffff;
  for (const byte of bytes) crc=(crc>>>8)^crcTable[(crc^byte)&255];
  return ((crc^0xffffffff)>>>0).toString(16).padStart(8,'0');
}
const MAX_ARCHIVE=128*1024*1024, MAX_ENTRY=4*1024*1024, MAX_TOTAL=128*1024*1024;
function zipEntries(bytes) {
  if (bytes.length>MAX_ARCHIVE) throw Error('ZIP exceeds the 128 MiB limit. Use individual game ZIPs.');
  const view=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength);
  let end=-1;
  for(let p=bytes.length-22;p>=Math.max(0,bytes.length-65557);p--)
    if(view.getUint32(p,true)===0x06054b50 && p+22+view.getUint16(p+20,true)===bytes.length){end=p;break;}
  if(end<0) throw Error('Not a valid ZIP archive.');
  const count=view.getUint16(end+10,true), directorySize=view.getUint32(end+12,true), directory=view.getUint32(end+16,true);
  if(count===65535 || directory===0xffffffff || directorySize===0xffffffff) throw Error('ZIP64 is unsupported.');
  if(view.getUint16(end+4,true)||view.getUint16(end+6,true)||view.getUint16(end+8,true)!==count)
    throw Error('Split ZIP archives are unsupported.');
  if(directory+directorySize>end) throw Error('Invalid ZIP directory.');
  const entries=[]; let p=directory,total=0;
  for(let i=0;i<count;i++) {
    if(p+46>directory+directorySize || view.getUint32(p,true)!==0x02014b50) throw Error('Invalid ZIP directory entry.');
    const flags=view.getUint16(p+8,true),method=view.getUint16(p+10,true),crc=view.getUint32(p+16,true).toString(16).padStart(8,'0');
    const compressed=view.getUint32(p+20,true),size=view.getUint32(p+24,true),nl=view.getUint16(p+28,true),el=view.getUint16(p+30,true),cl=view.getUint16(p+32,true),offset=view.getUint32(p+42,true);
    const name=new TextDecoder().decode(bytes.subarray(p+46,p+46+nl));
    if(p+46+nl+el+cl>directory+directorySize) throw Error('Truncated ZIP directory.');
    if(flags&1) throw Error('Encrypted ZIP files are unsupported.');
    if(method!==0 && method!==8) throw Error('ZIP uses unsupported compression. Repack with Deflate or Store.');
    if(size>MAX_ENTRY || (total+=size)>MAX_TOTAL) throw Error('ZIP expands beyond the game-file size limits.');
    if(offset+30>directory || view.getUint32(offset,true)!==0x04034b50) throw Error('Invalid ZIP file header.');
    const start=offset+30+view.getUint16(offset+26,true)+view.getUint16(offset+28,true);
    if(start+compressed>directory) throw Error('Truncated ZIP file data.');
    if(!name.endsWith('/')) entries.push({name,crc,size,method,compressed:bytes.subarray(start,start+compressed)});
    p+=46+nl+el+cl;
  }
  return entries;
}
async function unpack(entry) {
  if(entry.data) return entry.data;
  let data;
  if(entry.method===0) data=entry.compressed;
  else {
    let stream;
    try {stream=new DecompressionStream('deflate-raw');}
    catch {throw Error('This browser cannot open Deflate ZIP files. Open this HTML in a current Chrome, Edge, Firefox or Safari.');}
    const reader=new Blob([entry.compressed]).stream().pipeThrough(stream).getReader();
    const chunks=[];let size=0;
    try {for(;;){const {done,value}=await reader.read();if(done)break;size+=value.length;if(size>entry.size){await reader.cancel();throw Error('ZIP decompressed size mismatch.');}chunks.push(value);}}
    finally {reader.releaseLock();}
    data=new Uint8Array(size);let position=0;for(const chunk of chunks){data.set(chunk,position);position+=chunk.length;}
  }
  if(data.length!==entry.size || crc32(data)!==entry.crc) throw Error(`Corrupt ZIP entry: ${entry.name}`);
  entry.data=data;return data;
}
async function assemble(recipe, entries) {
  const chunks=[];let size=0;
  for(const part of recipe.parts) {
    let data;
    if(part.name) {
      const candidates=entries.get(part.crc)||[];
      if(!candidates.length) throw Error(`Missing ${part.name} (CRC ${part.crc})`);
      // Prefer the original name, but identify renamed/merged ROMs by their verified CRC.
      const entry=candidates.find(e=>e.name.split('/').pop()===part.name)||candidates[0];
      data=await unpack(entry);
    } else data=Uint8Array.from(part.fill.match(/../g),s=>parseInt(s,16));
    size+=data.length*part.repeat;
    if(size>recipe.size) throw Error('Assembled ROM exceeds expected size.');
    for(let n=0;n<part.repeat;n++)chunks.push(data);
  }
  if(size!==recipe.size)throw Error('Assembled ROM size does not match the configured core.');
  const result=new Uint8Array(size);let offset=0;
  for(const chunk of chunks){result.set(chunk,offset);offset+=chunk.length;}
  if(crc32(result)!==recipe.crc32)throw Error('Assembled ROM checksum does not match the configured core.');
  return result;
}
function storeZip(files) {
  // Uncompressed ZIP export keeps the page independent of compression libraries.
  const chunks=[],central=[];let offset=0,centralSize=0;
  for(const {name,data} of files){
    const filename=new TextEncoder().encode(name),crc=parseInt(crc32(data),16);
    const header=new Uint8Array(30+filename.length),h=new DataView(header.buffer);
    h.setUint32(0,0x04034b50,true);h.setUint16(4,20,true);h.setUint16(6,0x800,true);h.setUint16(12,0x21,true);h.setUint32(14,crc,true);h.setUint32(18,data.length,true);h.setUint32(22,data.length,true);h.setUint16(26,filename.length,true);header.set(filename,30);
    const record=new Uint8Array(46+filename.length),r=new DataView(record.buffer);
    r.setUint32(0,0x02014b50,true);r.setUint16(4,20,true);r.setUint16(6,20,true);r.setUint16(8,0x800,true);r.setUint16(14,0x21,true);r.setUint32(16,crc,true);r.setUint32(20,data.length,true);r.setUint32(24,data.length,true);r.setUint16(28,filename.length,true);r.setUint32(42,offset,true);record.set(filename,46);
    chunks.push(header,data);central.push(record);offset+=header.length+data.length;centralSize+=record.length;
  }
  const end=new Uint8Array(22),e=new DataView(end.buffer);
  e.setUint32(0,0x06054b50,true);e.setUint16(8,files.length,true);e.setUint16(10,files.length,true);e.setUint32(12,centralSize,true);e.setUint32(16,offset,true);
  return new Blob([...chunks,...central,end],{type:'application/zip'});
}
// Export just the pure operations for dependency-free Node regression tests.
if(typeof module!=='undefined')module.exports={crc32,zipEntries,unpack,assemble,storeZip};
if(typeof document!=='undefined') {
  const $=id=>document.getElementById(id),entries=new Map(),outputs=new Map(),urls=[];
  let prom=null,busy=false,added=0;
  function download(name,data){const url=URL.createObjectURL(new Blob([data]));const link=document.createElement('a');link.href=url;link.download=name;document.body.append(link);link.click();link.remove();setTimeout(()=>URL.revokeObjectURL(url),60000);}
  function refreshSummary(){ $('summary').textContent=`${outputs.size} of ${RECIPES.length} games ready · ${added} file${added===1?'':'s'} added`; $('save').disabled=busy||!outputs.size; }
  async function render(){
    for(const url of urls)URL.revokeObjectURL(url);urls.length=0;$('games').replaceChildren();
    for(const game of RECIPES){
      const row=document.createElement('tr'),title=document.createElement('td'),set=document.createElement('td'),status=document.createElement('td');
      title.textContent=game.name;set.textContent=game.zips.join(' + ');row.append(title,set,status);$('games').append(row);
      const missing=game.parts.filter(part=>part.crc&&!entries.has(part.crc));
      if(missing.length){status.className='missing';status.textContent=`Missing ${missing.length} chip${missing.length===1?'':'s'}`;const details=document.createElement('details'),label=document.createElement('summary');label.textContent='Show files';details.append(label);for(const part of missing){const line=document.createElement('div');line.textContent=`${part.name} · ${part.crc}`;details.append(line);}status.append(details);continue;}
      try{const data=outputs.get(game.key)||await assemble(game,entries);outputs.set(game.key,data);const link=document.createElement('a'),url=URL.createObjectURL(new Blob([data]));urls.push(url);link.href=url;link.download=game.key+'.rom';link.textContent='Download .rom';status.append(link);status.className='good';}
      catch(error){status.textContent=error.message;status.className='error';}
    }
  }
  async function add(files){
    if(busy)return;busy=true;$('files').disabled=true;$('clear').disabled=true;refreshSummary();const errors=[];
    try{
      for(const file of files){try{
        if(file.size>MAX_ARCHIVE)throw Error('File exceeds 128 MiB.');
        const bytes=new Uint8Array(await file.arrayBuffer());
        if(bytes.length===32 && crc32(bytes)==='e1281ee9'){prom=bytes;added++;continue;}
        if(!file.name.toLowerCase().endsWith('.zip'))throw Error('Expected a MAME ZIP or the matching 32-byte SSIO PROM.');
        const list=zipEntries(bytes);
        for(const entry of list){const matches=entries.get(entry.crc)||[];matches.push(entry);entries.set(entry.crc,matches);}
        const found=list.find(e=>e.size===32&&e.crc==='e1281ee9');if(found)prom=await unpack(found);
        added++;
      }catch(error){errors.push(`${file.name}: ${error.message}`);}}
      await render();
      $('notice').textContent=[...errors,prom?'Sound timing PROM ready.':'Keep ssio.prom from your core installation, or add your own file.'].join(' ');
      $('notice').className=errors.length?'error':'';
    }finally{busy=false;$('files').disabled=false;$('clear').disabled=false;refreshSummary();}
  }
  $('files').addEventListener('change',event=>{add([...event.target.files]);event.target.value='';});
  $('drop').addEventListener('dragover',event=>{event.preventDefault();$('drop').classList.add('over');});
  $('drop').addEventListener('dragleave',()=>$('drop').classList.remove('over'));
  $('drop').addEventListener('drop',event=>{event.preventDefault();$('drop').classList.remove('over');add([...event.dataTransfer.files]);});
  $('clear').addEventListener('click',()=>{entries.clear();outputs.clear();prom=null;added=0;$('notice').textContent='';render();refreshSummary();});
  $('save').addEventListener('click',()=>{const files=RECIPES.filter(g=>outputs.has(g.key)).map(g=>({name:`roms/MCR/${g.name}.rom`,data:outputs.get(g.key)}));if(prom)files.push({name:'cores/alanswx.MCR/ssio.prom',data:prom});download('MCR-GameBub-ROMs.zip',storeZip(files));});
  render();
}
