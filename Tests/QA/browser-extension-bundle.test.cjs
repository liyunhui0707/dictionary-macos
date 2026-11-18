const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');
async function fixture(){
 const api=await import('../../scripts/browser-extension.mjs');
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'dictionary-extension-test-'));
 const source=path.join(root,'source');fs.mkdirSync(path.join(source,'icons'),{recursive:true});
 for(const file of api.browserExtensionFiles) fs.writeFileSync(path.join(source,file),file==='manifest.json'?JSON.stringify({manifest_version:3,name:'Wordlit Lookup'}):'synthetic '+file);
 return {api,root,source,destination:path.join(root,'bundled')};
}
test('bundled companion is complete and excludes unrelated files and token',async()=>{
 const f=await fixture();fs.writeFileSync(path.join(f.source,'token'),'PRIVATE_SENTINEL');
 f.api.bundleBrowserExtension(f.source,f.destination);
 for(const file of f.api.browserExtensionFiles) assert.deepEqual(fs.readFileSync(path.join(f.destination,file)),fs.readFileSync(path.join(f.source,file)));
 assert.equal(fs.existsSync(path.join(f.destination,'token')),false);
 assert.throws(()=>f.api.bundleBrowserExtension(f.source,f.destination));
});
test('missing source or symlink cannot publish a companion folder',async()=>{
 const f=await fixture();const link=path.join(f.root,'linked');fs.symlinkSync(f.source,link);
 assert.throws(()=>f.api.bundleBrowserExtension(link,f.destination),/Symlink/);
 assert.equal(fs.existsSync(f.destination),false);
 assert.throws(()=>f.api.bundleBrowserExtension(path.join(f.root,'absent'),f.destination));
 assert.equal(fs.existsSync(f.destination),false);
});
