const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const {spawn, spawnSync} = require('node:child_process');

// Run the actual legacy script in isolated directories. Never target real Apps.
// Fixtures are retained; compiler and signer are deterministic fake processes.
function fixture(mode = 'success') {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dictionary-build-regression-'));
  for (const dir of ['scripts', 'tools', 'bin']) fs.mkdirSync(path.join(root, dir));
  fs.copyFileSync(path.resolve(__dirname, '../../scripts/build-app.sh'), path.join(root, 'scripts/build-app.sh'));
  fs.copyFileSync(path.resolve(__dirname, '../../VERSION'), path.join(root, 'VERSION'));
  fs.writeFileSync(path.join(root, 'bin/DictionaryApp'), 'candidate-binary', {mode: 0o755});
  const resource = path.join(root, 'bin/DictionaryApp_DictionaryApp.bundle/Contents/Resources/EnglishDictionary');
  if (mode !== 'missing-resource') {
    fs.mkdirSync(resource, {recursive: true});
    fs.writeFileSync(path.join(resource, 'oewn-2025.json.gz'), 'synthetic-resource');
    fs.writeFileSync(path.join(resource, '../AppIcon.icns'), 'synthetic-icon');
  }
  const tool = `#!${process.execPath}
const fs = require('node:fs');
const path = require('node:path');
const root = process.cwd(), mode = process.env.TEST_BUILD_MODE;
const args = process.argv.slice(2);
if (path.basename(process.argv[1]) === 'codesign') {
  fs.appendFileSync('signing-calls', JSON.stringify(args) + '\\n');
  if (mode === 'sign-failure' && args.includes('--sign')) process.exit(42);
  if (mode === 'verify-failure' && args.includes('--verify')) process.exit(43);
} else if (args.includes('--show-bin-path')) {
  console.log(path.join(root, 'bin'));
} else {
  fs.writeFileSync('compile-started-' + (process.env.TEST_JOB || 'one'), 'started');
  if (mode === 'compile-failure') process.exit(41);
  if (mode === 'race') {
    fs.mkdirSync('build/Dictionary.app/Contents/MacOS', {recursive: true});
    fs.writeFileSync('build/Dictionary.app/Contents/MacOS/DictionaryApp', 'original-executable');
    fs.writeFileSync('build/Dictionary.app/Contents/Info.plist', 'original-plist');
  }
  if (mode === 'concurrent') {
    const deadline = Date.now() + 5000;
    const wait = () => {
      if (fs.existsSync('compile-started-A') && fs.existsSync('compile-started-B')) return;
      if (Date.now() > deadline) process.exit(44);
      setTimeout(wait, 10);
    };
    wait();
  }
}
`;
  for (const name of ['xcrun', 'codesign']) fs.writeFileSync(path.join(root, 'tools', name), tool, {mode: 0o755});
  return {root, app: path.join(root, 'build/Dictionary.app'),
    env: {...process.env, PATH: `${path.join(root, 'tools')}:${process.env.PATH}`, TEST_BUILD_MODE: mode}};
}

function run(f) {
  return spawnSync('/bin/bash', ['scripts/build-app.sh'], {cwd: f.root, env: f.env, encoding: 'utf8', timeout: 15000});
}
function preserved(f) {
  assert.equal(fs.readFileSync(path.join(f.app, 'Contents/MacOS/DictionaryApp'), 'utf8'), 'original-executable');
  assert.equal(fs.readFileSync(path.join(f.app, 'Contents/Info.plist'), 'utf8'), 'original-plist');
}
function refused(r) {
  assert.equal(r.error, undefined);
  assert.notEqual(r.status, 0);
  assert.doesNotMatch(r.stdout, /Built:/);
}

test('legacy refuses an already-existing App before compiling', () => {
  const f = fixture();
  fs.mkdirSync(path.join(f.app, 'Contents/MacOS'), {recursive: true});
  fs.writeFileSync(path.join(f.app, 'Contents/MacOS/DictionaryApp'), 'original-executable');
  fs.writeFileSync(path.join(f.app, 'Contents/Info.plist'), 'original-plist');
  refused(run(f)); preserved(f);
  assert(!fs.existsSync(path.join(f.root, 'compile-started-one')));
});

test('H1: an App appearing during compilation is refused with all sentinel bytes preserved', () => {
  const f = fixture('race');
  refused(run(f)); preserved(f);
  assert(!fs.existsSync(path.join(f.root, 'signing-calls')));
});

test('legacy refuses even a dangling target symlink before compiling', () => {
  const f = fixture();
  fs.mkdirSync(path.join(f.root, 'build'));
  fs.symlinkSync('missing-app', f.app);
  refused(run(f));
  assert.equal(fs.readlinkSync(f.app), 'missing-app');
  assert(!fs.existsSync(path.join(f.root, 'compile-started-one')));
});

test('two legacy builds that both pass the early guard have only one packaging winner', async () => {
  const f = fixture('concurrent');
  const start = job => new Promise((resolve, reject) => {
    const child = spawn('/bin/bash', ['scripts/build-app.sh'], {cwd: f.root, env: {...f.env, TEST_JOB: job}});
    let stdout = '', stderr = '';
    child.stdout.on('data', b => stdout += b); child.stderr.on('data', b => stderr += b);
    child.on('error', reject); child.on('close', status => resolve({status, stdout, stderr}));
  });
  const results = await Promise.all([start('A'), start('B')]);
  assert.equal(results.filter(r => r.status === 0).length, 1);
  assert.equal(results.filter(r => /Built:/.test(r.stdout)).length, 1);
  assert.equal(fs.readFileSync(path.join(f.app, 'Contents/MacOS/DictionaryApp'), 'utf8'), 'candidate-binary');
  const calls = fs.readFileSync(path.join(f.root, 'signing-calls'), 'utf8').trim().split('\n').map(JSON.parse);
  assert.equal(calls.filter(a => a.includes('--sign')).length, 1);
});

test('compiler failure does not create an App or claim success', () => {
  const f = fixture('compile-failure'); refused(run(f));
  assert(!fs.existsSync(f.app));
});

test('signing failure preserves incomplete output, reports failure, and refuses a retry', () => {
  const f = fixture('sign-failure'); refused(run(f));
  const binary = fs.readFileSync(path.join(f.app, 'Contents/MacOS/DictionaryApp'));
  f.env.TEST_BUILD_MODE = 'success'; refused(run(f));
  assert.deepEqual(fs.readFileSync(path.join(f.app, 'Contents/MacOS/DictionaryApp')), binary);
});

test('signature verification failure is not reported as a successful legacy build', () => {
  refused(run(fixture('verify-failure')));
});

test('legacy success requires signing and verification and retains bundle identity/version', () => {
  const f = fixture(); const r = run(f);
  assert.equal(r.status, 0, r.stderr); assert.match(r.stdout, /Built: build\/Dictionary.app/);
  const calls = fs.readFileSync(path.join(f.root, 'signing-calls'), 'utf8').trim().split('\n').map(JSON.parse);
  assert(calls.some(a => a.includes('--sign')));
  assert(calls.some(a => a.includes('--verify') && a.includes('--strict')));
  const plist = fs.readFileSync(path.join(f.app, 'Contents/Info.plist'), 'utf8');
  assert.match(plist, /CFBundleIconFile/);
  assert.equal(fs.readFileSync(path.join(f.app, 'Contents/Resources/AppIcon.icns'), 'utf8'), 'synthetic-icon');
  assert.match(plist, /com\.liyunhui\.DictionaryApp/);
  assert(plist.includes('<string>'+fs.readFileSync(path.join(f.root,'VERSION'),'utf8').trim()+'</string>'));
  assert.equal(fs.readFileSync(path.join(f.app, 'Contents/Resources/DictionaryApp_DictionaryApp.bundle/Contents/Resources/EnglishDictionary/oewn-2025.json.gz'), 'utf8'), 'synthetic-resource');
});

test('QA packaging carries dictionary resources with the executable', async () => {
  const {packageApp} = await import('../../scripts/qa-app.mjs');
  const f = fixture(); fs.mkdirSync(path.dirname(f.app), {recursive: true});
  packageApp(path.dirname(f.app), path.join(f.root, 'bin/DictionaryApp'), {}, () => '');
  assert.match(fs.readFileSync(path.join(f.app, 'Contents/Info.plist'), 'utf8'), /CFBundleIconFile/);
  assert.equal(fs.readFileSync(path.join(f.app, 'Contents/Resources/AppIcon.icns'), 'utf8'), 'synthetic-icon');
  assert.equal(fs.readFileSync(path.join(f.app, 'Contents/Resources/DictionaryApp_DictionaryApp.bundle/Contents/Resources/EnglishDictionary/oewn-2025.json.gz'), 'utf8'), 'synthetic-resource');
});

test('QA packaging refuses missing dictionary resources before signing', async () => {
  const {packageApp} = await import('../../scripts/qa-app.mjs');
  const f = fixture(); fs.mkdirSync(path.dirname(f.app), {recursive: true});
  const binary = path.join(f.root, 'standalone-binary'); fs.writeFileSync(binary, 'synthetic');
  assert.throws(() => packageApp(path.dirname(f.app), binary, {}, () => assert.fail('must not sign')), /resource/i);
});

test('legacy packaging refuses missing dictionary resources before signing', () => {
  const f = fixture('missing-resource'); refused(run(f));
  assert(!fs.existsSync(path.join(f.root, 'signing-calls')));
});

test('QA packaging accepts native SwiftPM flat resource bundles too', async () => {
  const {packageApp} = await import('../../scripts/qa-app.mjs');
  const f = fixture('missing-resource'); fs.mkdirSync(path.dirname(f.app), {recursive: true});
  const directory = path.join(f.root, 'bin/DictionaryApp_DictionaryApp.bundle/EnglishDictionary');
  fs.mkdirSync(directory, {recursive: true});
  fs.writeFileSync(path.join(directory, 'oewn-2025.json.gz'), 'synthetic-flat-resource');
  fs.writeFileSync(path.join(directory, '../AppIcon.icns'), 'synthetic-icon');
  packageApp(path.dirname(f.app), path.join(f.root, 'bin/DictionaryApp'), {}, () => '');
  assert.match(fs.readFileSync(path.join(f.app, 'Contents/Info.plist'), 'utf8'), /CFBundleIconFile/);
  assert.equal(fs.readFileSync(path.join(f.app, 'Contents/Resources/AppIcon.icns'), 'utf8'), 'synthetic-icon');
  assert.equal(fs.readFileSync(path.join(f.app, 'Contents/Resources/DictionaryApp_DictionaryApp.bundle/EnglishDictionary/oewn-2025.json.gz'), 'utf8'), 'synthetic-flat-resource');
});

test('QA packaging also refuses an existing App without touching any contents', async () => {
  const {packageApp} = await import('../../scripts/qa-app.mjs');
  const f = fixture(); fs.mkdirSync(f.app, {recursive:true});
  fs.writeFileSync(path.join(f.app, 'sentinel'), 'preserve');
  assert.throws(() => packageApp(path.dirname(f.app), path.join(f.root, 'bin/DictionaryApp'), {}, () => assert.fail('must not sign')), /EEXIST/);
  assert.equal(fs.readFileSync(path.join(f.app, 'sentinel'), 'utf8'), 'preserve');
  assert.deepEqual(fs.readdirSync(f.app), ['sentinel']);
});
