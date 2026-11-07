const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const api = import('../../scripts/release-app.mjs');

test('public payload audit rejects private paths, QA metadata, credentials and symlinks', async () => {
  const {auditPublicApp} = await api;
  for(const mode of ['path','qa','key','symlink','safe']) {
    const app = fs.mkdtempSync(path.join(os.tmpdir(),'dictionary-public-audit-'));
    const resources=path.join(app,'Contents/Resources'); fs.mkdirSync(resources,{recursive:true});
    const name=mode==='qa'?'qa-build.json':'payload';
    if(mode==='symlink') fs.symlinkSync('/Applications',path.join(resources,name));
    else fs.writeFileSync(path.join(resources,name),mode==='path'?'/Users/synthetic/private':
      mode==='key'?'sk-'+ 'a'.repeat(30):'synthetic public payload');
    if(mode==='safe') assert.equal(auditPublicApp(app).length,1);
    else assert.throws(()=>auditPublicApp(app),/refused/i);
  }
});

test('public packaging omits private QA metadata and preserves resources and version', async () => {
  const {packageApp,signingOptions} = await import('../../scripts/qa-app.mjs');
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'dictionary-public-package-'));
  const bin=path.join(root,'bin'); fs.mkdirSync(bin);
  const resource=path.join(bin,'DictionaryApp_DictionaryApp.bundle/EnglishDictionary'); fs.mkdirSync(resource,{recursive:true});
  fs.writeFileSync(path.join(resource,'oewn-2025.json.gz'),'synthetic dictionary');
  fs.writeFileSync(path.join(resource,'../AppIcon.icns'),'synthetic icon');
  const executable=path.join(bin,'DictionaryApp'); fs.writeFileSync(executable,'synthetic executable');
  const out=path.join(root,'out'); fs.mkdirSync(out);
  const app=packageApp(out,executable,{productVersion:'0.2.0',privatePath:'not for public'},()=>'',signingOptions(),false);
  assert(!fs.existsSync(path.join(app,'Contents/Resources/qa-build.json')));
  assert.match(fs.readFileSync(path.join(app,'Contents/Info.plist'),'utf8'),/<string>0\.2\.0<\/string>/);
  assert((await api).auditPublicApp(app).some(file=>file.path.endsWith('EnglishDictionary/oewn-2025.json.gz')));
});
