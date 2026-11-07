const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const api = import('../../scripts/qa-app.mjs');

function fixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dictionary-qa-test-'));
  for (const p of ['Package.swift', 'README.md', '.gitignore', 'Sources/App.swift', 'Tests/Test.swift', 'scripts/build-app.sh', 'docs/audit.md']) {
    fs.mkdirSync(path.dirname(path.join(root,p)), {recursive:true});
    fs.writeFileSync(path.join(root,p), p);
  }
  return root;
}

test('snapshot includes untracked inputs and restores exact bytes/modes; changes affect fingerprint', async () => {
  const {snapshot, verifySnapshot} = await api;
  const root=fixture(), dest=path.join(root,'build','one');
  fs.chmodSync(path.join(root,'scripts/build-app.sh'),0o755);
  const first=snapshot(root,dest);
  assert.equal(first.files.length,7);
  assert.equal(verifySnapshot(dest,first),true);
  assert.equal(fs.statSync(path.join(dest,'scripts/build-app.sh')).mode&0o777,0o755);
  fs.writeFileSync(path.join(root,'Sources/Untracked.swift'),'new');
  assert.notEqual(snapshot(root,path.join(root,'build','two')).fingerprint,first.fingerprint);
  fs.writeFileSync(path.join(dest,'README.md'),'changed');
  assert.throws(()=>verifySnapshot(dest,first),/mismatch/);
});

test('protected files are not read or copied; symlinks and unexpected build inputs are rejected', async () => {
  const {snapshot, assertKnownInputs} = await api;
  const root=fixture();
  fs.writeFileSync(path.join(root,'.env'),'PRIVATE_SENTINEL',{mode:0});
  fs.mkdirSync(path.join(root,'secrets'));
  fs.writeFileSync(path.join(root,'secrets','token'),'PRIVATE_SENTINEL',{mode:0});
  fs.writeFileSync(path.join(root,'Sources/.DS_Store'),'finder metadata');
  const result=snapshot(root,path.join(root,'build','safe'));
  assert(!JSON.stringify(result).includes('PRIVATE_SENTINEL'));
  assert(!fs.existsSync(path.join(root,'build/safe/.env')));
  assert(!result.files.some(f=>f.path.endsWith('.DS_Store')));
  fs.symlinkSync('/etc/hosts',path.join(root,'Sources/external.swift'));
  assert.throws(()=>snapshot(root,path.join(root,'build','symlink')),/symlink/i);
  assert.throws(()=>assertKnownInputs(['Package.swift','Other/local.swift']),/unapproved/i);
});

test('existing output is refused without changing its contents', async () => {
  const {snapshot} = await api; const root=fixture(),dest=path.join(root,'build','one');
  fs.mkdirSync(dest,{recursive:true});fs.writeFileSync(path.join(dest,'sentinel'),'keep');
  assert.throws(()=>snapshot(root,dest),/exist/i);
  assert.equal(fs.readFileSync(path.join(dest,'sentinel'),'utf8'),'keep');
});

test('process/port conflicts and inconclusive inspection fail closed', async () => {
  const {assertLaunchSafe, parseProcesses, parseListeners} = await api;
  assert.throws(()=>assertLaunchSafe([{pid:12,executable:'/old/Dictionary.app/Contents/MacOS/DictionaryApp'}],[]),/12/);
  assert.throws(()=>assertLaunchSafe([],[99]),/99/);
  assert.throws(()=>parseProcesses('not a process table'),/inspect/i);
  assert.throws(()=>parseListeners({status:1,stdout:'',stderr:'permission denied'}),/inspect/i);
  assert.deepEqual(parseListeners({status:1,stdout:'',stderr:''}),[]);
  assert.deepEqual(parseListeners({status:0,stdout:'p99\nn127.0.0.1:49152\n',stderr:''}),[99]);
  assert.deepEqual(parseListeners({status:0,stdout:'p5056\nf4\nn127.0.0.1:49152\n',stderr:''}),[5056]);
  assert.deepEqual(parseProcesses(' 12 /path with space/DictionaryApp\n'),[{pid:12,executable:'/path with space/DictionaryApp'}]);
  assert.doesNotThrow(()=>assertLaunchSafe([],[]));
});

test('same name/Bundle ID cannot substitute for executable path, UUID and hash', async () => {
  const {assertIdentity} = await api;
  const expected={executable:'/new/Dictionary.app/Contents/MacOS/DictionaryApp',bundleID:'com.liyunhui.DictionaryApp',uuid:'A',sha256:'a',signature:'adhoc'};
  for(const field of ['executable','bundleID','uuid','sha256','signature']) {
    assert.throws(()=>assertIdentity(expected,{...expected,[field]:'different'}),/identity/i);
  }
  assert.doesNotThrow(()=>assertIdentity(expected,{...expected}));
});

test('failed signing never writes a launchable manifest', async () => {
  const {packageApp} = await api; const root=fixture();
  const binary=path.join(root,'fake-binary');fs.writeFileSync(binary,'binary');
  const resource=path.join(root,'DictionaryApp_DictionaryApp.bundle/Contents/Resources/EnglishDictionary');
  fs.mkdirSync(resource,{recursive:true});fs.writeFileSync(path.join(resource,'oewn-2025.json.gz'),'synthetic-resource');
  fs.writeFileSync(path.join(resource,'../AppIcon.icns'),'synthetic-icon');
  const out=path.join(root,'build/package');fs.mkdirSync(out,{recursive:true});
  assert.throws(()=>packageApp(out,binary,{buildID:'test',sourceFingerprint:'abc'},()=>{throw Error('sign failed');}),/sign failed/);
  assert(!fs.existsSync(path.join(out,'build-manifest.json')));
});

test('signature identity includes designated requirement from stdout and details from stderr', async () => {
  const {parseSignature}=await api;
  const signature=parseSignature({status:0,stdout:'# designated => cdhash H"abc"\n',stderr:'Signature=adhoc\nCDHash=abc\nTeamIdentifier=not set\n'});
  assert.match(signature,/# designated/);assert.match(signature,/CDHash=abc/);
  assert.throws(()=>parseSignature({status:0,stdout:'',stderr:'Signature=adhoc\n'}),/Incomplete/);
});

test('certificate signature inspection accepts codesign explicit designated requirements', async () => {
  const {parseSignature}=await api;
  const {persistentRequirement}=await import('../../scripts/testing-app.mjs');
  const requirement='identifier "com.liyunhui.DictionaryApp.testing" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: Fixture"';
  const details={status:0,stdout:'designated => '+requirement+'\n',stderr:'Signature size=4786\nCDHash=abc\nTeamIdentifier=FIXTURE\n'};
  const signature=parseSignature(details);
  assert.equal(persistentRequirement({signature}),'# designated => '+requirement);
  assert.equal(signature,parseSignature({...details,stdout:'# designated => '+requirement+'\n'}));
});

test('daily entry verifies build, retains previous bundle and supports deliberate rollback', async () => {
  const {selectDailyBuild} = await api;
  const root=fs.realpathSync(fixture());
  for(const id of ['old','new']) fs.mkdirSync(path.join(root,'build/qa.noindex',id,'Dictionary.app'),{recursive:true});
  const daily=path.join(root,'build/Dictionary-Daily.app');
  fs.symlinkSync('qa.noindex/old/Dictionary.app',daily);
  const verified=[];
  const verify=out=>{verified.push(out);return {buildID:path.basename(out)};};
  const idle=()=>({processes:[],listeners:[]});
  const result=selectDailyBuild(root,path.join(root,'build/qa.noindex/new'),verify,idle);
  assert.equal(fs.realpathSync(daily),path.join(root,'build/qa.noindex/new/Dictionary.app'));
  assert.equal(fs.realpathSync(result.previous),path.join(root,'build/qa.noindex/old/Dictionary.app'));
  assert(fs.existsSync(path.join(root,'build/qa.noindex/old/Dictionary.app')));
  assert.equal(selectDailyBuild(root,path.join(root,'build/qa.noindex/new'),verify,idle).unchanged,true);
  selectDailyBuild(root,path.join(root,'build/qa.noindex/old'),verify,idle);
  assert.equal(fs.realpathSync(daily),path.join(root,'build/qa.noindex/old/Dictionary.app'));
  assert.equal(verified.length,3);
});

test('daily entry refuses conflicts, invalid builds, external paths and real apps without replacement', async () => {
  const {selectDailyBuild} = await api;
  const root=fs.realpathSync(fixture()),out=path.join(root,'build/qa.noindex/new');
  fs.mkdirSync(path.join(out,'Dictionary.app'),{recursive:true});
  const daily=path.join(root,'build/Dictionary-Daily.app');
  const ok=()=>({buildID:'new'}), idle=()=>({processes:[],listeners:[]});
  assert.throws(()=>selectDailyBuild(root,out,ok,()=>({processes:[{pid:42}],listeners:[]})),/blocked/i);
  assert.throws(()=>selectDailyBuild(root,out,()=>{throw Error('hash mismatch');},idle),/mismatch/);
  assert(!fs.existsSync(daily));
  assert.throws(()=>selectDailyBuild(root,root,ok,idle),/build\/qa/);
  fs.mkdirSync(daily);fs.writeFileSync(path.join(daily,'keep'),'unchanged');
  assert.throws(()=>selectDailyBuild(root,out,ok,idle),/symlink/i);
  assert.equal(fs.readFileSync(path.join(daily,'keep'),'utf8'),'unchanged');
});

test('first daily entry is created exclusively and external old references are preserved', async () => {
  const {selectDailyBuild} = await api;
  const root=fs.realpathSync(fixture()),out=path.join(root,'build/qa.noindex/first');
  fs.mkdirSync(path.join(out,'Dictionary.app'),{recursive:true});
  const idle=()=>({processes:[],listeners:[]});
  const result=selectDailyBuild(root,out,()=>({buildID:'first'}),idle);
  assert.equal(fs.realpathSync(result.entry),path.join(out,'Dictionary.app'));
  assert.equal(result.previous,undefined);
  const other=fs.realpathSync(fixture()),otherOut=path.join(other,'build/qa.noindex/new');
  fs.mkdirSync(path.join(otherOut,'Dictionary.app'),{recursive:true});
  const entry=path.join(other,'build/Dictionary-Daily.app');
  fs.symlinkSync('/Applications/Dictionary.app',entry);
  assert.throws(()=>selectDailyBuild(other,otherOut,()=>({buildID:'new'}),idle),/outside/);
  assert.equal(fs.readlinkSync(entry),'/Applications/Dictionary.app');
});
