const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const api = import('../../scripts/qa-app.mjs');
const staging = import('../../scripts/testing-app.mjs');
const fingerprint = 'A'.repeat(40);
const signature = '# designated => identifier "com.liyunhui.DictionaryApp.testing" and anchor apple generic\nCDHash=abc';

function fixture() {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'dictionary-stage-test-')));
  function create(id, sig=signature) {
    const out=path.join(root, 'build/qa', id);
    fs.mkdirSync(path.join(out,'Dictionary.app'), {recursive:true});
    fs.writeFileSync(path.join(out,'Dictionary.app','fixture.json'), JSON.stringify({id, sig}));
    return out;
  }
  function identify(app) {
    const {id,sig}=JSON.parse(fs.readFileSync(path.join(app,'fixture.json')));
    return {executable:path.join(app,'Contents/MacOS/DictionaryApp'), bundleID:'com.liyunhui.DictionaryApp.testing',
      uuid:id, sha256:id, signature:sig};
  }
  const verify=out=>({buildID:path.basename(out), channel:'testing', identity:identify(path.join(out,'Dictionary.app'))});
  const idle=()=>({processes:[],listeners:[]});
  return {root,create,identify,verify,idle};
}

test('testing requires an exact available certificate and never falls back to ad hoc', async () => {
  const {signingOptions,assertSigningIdentityAvailable}=await api;
  assert.throws(()=>signingOptions('testing'),/require/);
  for (const value of ['-', 'Apple Development', '', 'A'.repeat(39)])
    assert.throws(()=>signingOptions('testing',value),/fingerprint/);
  const options=signingOptions('testing',fingerprint.toLowerCase());
  assert.equal(options.identity,fingerprint);
  assert.equal(options.bundleID,'com.liyunhui.DictionaryApp.testing');
  assert.throws(()=>assertSigningIdentityAvailable(fingerprint,'0 valid identities found'),/not available/);
  assert.doesNotThrow(()=>assertSigningIdentityAvailable(fingerprint,`  1) ${fingerprint} "Example"\n 1 valid identities found`));
});

test('packaging passes the selected certificate and isolates testing bundle name/ID', async () => {
  const {packageApp,signingOptions}=await api;
  const f=fixture(); const out=f.create('package');
  const packageOut=path.join(f.root,'build/package');fs.mkdirSync(packageOut);
  const binary=path.join(out,'binary');fs.writeFileSync(binary,'synthetic');
  const resources=path.join(out,'DictionaryApp_DictionaryApp.bundle/EnglishDictionary');
  fs.mkdirSync(resources,{recursive:true});fs.writeFileSync(path.join(resources,'oewn-2025.json.gz'),'data');
  fs.writeFileSync(path.join(resources,'../AppIcon.icns'),'icon');
  const calls=[];
  const app=packageApp(packageOut,binary,{buildID:'test'},(cmd,args)=>calls.push([cmd,args]),signingOptions('testing',fingerprint));
  assert.deepEqual(calls[0],['/usr/bin/codesign',['--sign',fingerprint,app]]);
  assert.match(fs.readFileSync(path.join(app,'Contents/Info.plist'),'utf8'),/com.liyunhui.DictionaryApp.testing/);
  assert.match(fs.readFileSync(path.join(app,'Contents/Info.plist'),'utf8'),/Dictionary Testing/);
});

test('two staged versions retain a fixed entry, preserve old bytes and do not change daily', async () => {
  const {stageTestingBuild}=await staging;const f=fixture();
  const first=f.create('first'), second=f.create('second');
  fs.mkdirSync(path.join(f.root,'build/Dictionary-Daily.app'));
  fs.writeFileSync(path.join(f.root,'build/Dictionary-Daily.app/sentinel'),'unchanged');
  const a=stageTestingBuild(f.root,first,f.verify,f.identify,f.idle);
  const b=stageTestingBuild(f.root,second,f.verify,f.identify,f.idle);
  assert.equal(a.entry,b.entry);
  assert.equal(f.identify(b.entry).sha256,'second');
  assert.equal(f.identify(path.join(b.backup,'Dictionary Testing.app')).sha256,'first');
  assert.equal(fs.readFileSync(path.join(f.root,'build/Dictionary-Daily.app/sentinel'),'utf8'),'unchanged');
  assert(stageTestingBuild(f.root,second,f.verify,f.identify,f.idle).unchanged);
});

test('ad hoc, weak requirements, identity changes and wrong channel cannot replace testing', async () => {
  const {stageTestingBuild,persistentRequirement}=await staging;const f=fixture();
  const first=f.create('first');
  stageTestingBuild(f.root,first,f.verify,f.identify,f.idle);
  for (const sig of ['Signature=adhoc\n# designated => cdhash H"abc"', '# designated => identifier "example"', signature.replace('anchor apple generic', 'anchor apple generic and certificate leaf = H"changed"')]) {
    const next=f.create('bad-'+Math.random(),sig);
    assert.throws(()=>stageTestingBuild(f.root,next,f.verify,f.identify,f.idle),/signature|requirement/i);
    assert.equal(f.identify(path.join(f.root,'build/testing/Dictionary Testing.app')).sha256,'first');
  }
  assert.throws(()=>persistentRequirement({signature:''}),/signature/i);
  assert.throws(()=>stageTestingBuild(f.root,first,out=>({...f.verify(out),channel:'daily'}),f.identify,f.idle),/separately/);
});

test('failed copy verification, running app and concurrent staging preserve the installed version', async () => {
  const {stageTestingBuild}=await staging;const f=fixture();
  const first=f.create('first'), second=f.create('second');
  stageTestingBuild(f.root,first,f.verify,f.identify,f.idle);
  const altered=app=>({...f.identify(app), ...(app.includes('testing-stage-') ? {sha256:'corrupt'} : {})});
  assert.throws(()=>stageTestingBuild(f.root,second,f.verify,altered,f.idle),/mismatch/);
  assert.equal(f.identify(path.join(f.root,'build/testing/Dictionary Testing.app')).sha256,'first');
  assert.throws(()=>stageTestingBuild(f.root,second,f.verify,f.identify,()=>({processes:[{pid:42}],listeners:[]})),/blocked/i);
  fs.mkdirSync(path.join(f.root,'build/testing-stage.lock'));
  assert.throws(()=>stageTestingBuild(f.root,second,f.verify,f.identify,f.idle),/EEXIST/);
});

test('testing channel cannot switch the daily shortcut', async () => {
  const {selectDailyBuild}=await api;const f=fixture();const candidate=f.create('test');
  assert.throws(()=>selectDailyBuild(f.root,candidate,f.verify,f.idle),/cannot become/);
  assert(!fs.existsSync(path.join(f.root,'build/Dictionary-Daily.app')));
});
