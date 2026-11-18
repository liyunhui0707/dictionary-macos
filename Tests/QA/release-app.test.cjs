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
  const resource=path.join(bin,'Wordlit_DictionaryApp.bundle/EnglishDictionary'); fs.mkdirSync(resource,{recursive:true});
  fs.writeFileSync(path.join(resource,'oewn-2025.json.gz'),'synthetic dictionary');
  fs.writeFileSync(path.join(resource,'../AppIcon.icns'),'synthetic icon');
  fs.writeFileSync(path.join(resource, '../ReadingSample.html'), 'synthetic reading sample');
  const pronunciation=path.join(resource,'../Pronunciation'); fs.mkdirSync(pronunciation);
  const files={'cmudict.dict':'bank B AE1 NG K','LICENSE':'synthetic license'};
  const provenance={files:{}};
  for(const [name,text] of Object.entries(files)) {
    fs.writeFileSync(path.join(pronunciation,name),text);
    provenance.files[name]={sha256:require('node:crypto').createHash('sha256').update(text).digest('hex')};
  }
  fs.writeFileSync(path.join(pronunciation,'provenance.json'),JSON.stringify(provenance));
  const executable=path.join(bin,'DictionaryApp'); fs.writeFileSync(executable,'synthetic executable');
  const out=path.join(root,'out'); fs.mkdirSync(out);
  const app=packageApp(out,executable,{productVersion:'0.2.0',privatePath:'not for public'},()=>'',signingOptions(),false);
  assert.equal(path.basename(app),'Wordlit.app');
  const plist=fs.readFileSync(path.join(app,'Contents/Info.plist'),'utf8');
  assert.match(plist,/<key>CFBundleName<\/key><string>Wordlit<\/string>/);
  assert.match(plist,/<key>CFBundleIdentifier<\/key><string>com\.liyunhui\.DictionaryApp<\/string>/);
  assert(!fs.existsSync(path.join(app,'Contents/Resources/qa-build.json')));
  assert.equal(JSON.parse(fs.readFileSync(path.join(app,'Contents/Resources/BrowserExtension/manifest.json'))).name,'Wordlit Lookup');
  assert(fs.existsSync(path.join(app,'Contents/Resources/BrowserExtension/service-worker.js')));
  assert.match(fs.readFileSync(path.join(app,'Contents/Info.plist'),'utf8'),/<string>0\.2\.0<\/string>/);
  assert((await api).auditPublicApp(app).some(file=>file.path.endsWith('EnglishDictionary/oewn-2025.json.gz')));
});
