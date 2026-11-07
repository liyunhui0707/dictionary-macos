#!/usr/bin/env node
// No dependencies. Commands never stop processes, replace bundles or read credentials.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {spawnSync, spawn} from 'node:child_process';

const project = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const roots = ['Sources', 'Tests', 'scripts', 'docs', 'extensions', '.github', 'website'];
const topFiles = ['Package.swift', 'README.md', '.gitignore', 'LICENSE', 'PRIVACY.md', 'SECURITY.md', 'CONTRIBUTING.md', 'THIRD_PARTY_NOTICES.md', 'AGENTS.md'];
const sha = data => crypto.createHash('sha256').update(data).digest('hex');
const json = (file, value) => fs.writeFileSync(file, JSON.stringify(value,null,2)+'\n', {flag:'wx',mode:0o600});
const stamp = () => new Date().toISOString().replace(/[:.]/g,'-')+'-'+crypto.randomBytes(3).toString('hex');
const protectedPath = p => p.split('/').some(s => /^\.env(?:\.|$)/i.test(s) || /^(secrets|node_modules|\.build|\.git|\.DS_Store|dist)$/i.test(s) || /\.(pem|key|p12|pfx|gguf|safetensors|crx)$/i.test(s));

function run(command, args, cwd=project) {
  const r = spawnSync(command,args,{cwd,encoding:'utf8',maxBuffer:16*1024*1024});
  if(r.error || r.status!==0) throw Error(`${path.basename(command)} failed (${r.status ?? 'not started'}): ${r.stderr || r.error?.message || ''}`);
  return r.stdout;
}

export function assertKnownInputs(paths) {
  for(const p of paths) {
    if(protectedPath(p)) continue; // Excluded before opening even if accidentally tracked.
    if(!topFiles.includes(p) && !roots.some(r=>p.startsWith(r+'/'))) throw Error('Unapproved input: '+p);
  }
}

function inventory(root) {
  if(fs.lstatSync(root).isSymbolicLink()) throw Error('Symlink snapshot root refused');
  const files=[];
  function visit(p) {
    if(protectedPath(p)) return;
    const file=path.join(root,p);const stat=fs.lstatSync(file);
    if(stat.isSymbolicLink()) throw Error('Symlink input refused: '+p);
    if(stat.isDirectory()) { for(const name of fs.readdirSync(file).sort()) visit(p+'/'+name); return; }
    if(!stat.isFile()) throw Error('Non-regular input: '+p);
    const data=fs.readFileSync(file);
    if(/-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----|\bsk-(?:ant-|proj-)?[A-Za-z0-9_-]{24,}|\bgh[pousr]_[A-Za-z0-9]{30,}/.test(data.toString('utf8'))) throw Error('Credential-like input refused: '+p);
    files.push({path:p,mode:stat.mode&0o777,bytes:data.length,sha256:sha(data)});
  }
  for(const p of [...topFiles,...roots]) {
    try { fs.lstatSync(path.join(root,p)); } catch(error) { if(error.code==='ENOENT') continue; throw error; }
    visit(p);
  }
  files.sort((a,b)=>a.path.localeCompare(b.path,'en'));
  return {files,fingerprint:sha(JSON.stringify(files))};
}

export function verifySnapshot(root, manifest) {
  const current=inventory(root);
  if(current.fingerprint!==manifest.fingerprint) throw Error('Snapshot hash/mode/file inventory mismatch');
  return true;
}

export function snapshot(root, destination) {
  const manifest=inventory(root);
  fs.mkdirSync(path.dirname(destination),{recursive:true});fs.mkdirSync(destination,{mode:0o700});
  for(const entry of manifest.files) {
    const dest=path.join(destination,entry.path);fs.mkdirSync(path.dirname(dest),{recursive:true});
    fs.copyFileSync(path.join(root,entry.path),dest,fs.constants.COPYFILE_EXCL);fs.chmodSync(dest,entry.mode);
  }
  verifySnapshot(destination,manifest);
  return manifest;
}

export function parseSignature(details) {
  if(details.error || details.status!==0) throw Error('Cannot inspect signature');
  // codesign prefixes implicit (ad-hoc) requirements with '# ', but explicit
  // certificate requirements have no prefix. Keep archive identity formatting.
  const signature=(details.stdout+'\n'+details.stderr).split('\n')
    .map(l=>l.startsWith('designated =>') ? '# '+l : l)
    .filter(l=>/^(Signature=|CDHash=|TeamIdentifier=|# designated =>)/.test(l)).join('\n');
  if(!signature.includes('CDHash=') || !signature.includes('# designated =>')) throw Error('Incomplete signature inspection');
  return signature;
}

export function binaryIdentity(app) {
  const executable=path.join(app,'Contents/MacOS/DictionaryApp');
  run('/usr/bin/codesign',['--verify','--strict',app]);
  const details=spawnSync('/usr/bin/codesign',['-d','--verbose=4','-r-',app],{encoding:'utf8'});
  const signature=parseSignature(details);
  const uuid=run('/usr/bin/dwarfdump',['--uuid',executable]).trim().split('\n').map(l=>{
    const m=l.match(/^UUID: ([A-Fa-f0-9-]+) \(([^)]+)\)/);if(!m)throw Error('Cannot inspect UUID');return `${m[1]} (${m[2]})`;
  }).join(', ');
  const bundleID=run('/usr/libexec/PlistBuddy',['-c','Print :CFBundleIdentifier',path.join(app,'Contents/Info.plist')]).trim();
  return {executable,uuid,sha256:sha(fs.readFileSync(executable)),bundleID,signature};
}

export function assertIdentity(expected, actual) {
  for(const field of ['executable','bundleID','uuid','sha256','signature']) {
    if(!expected[field] || expected[field]!==actual[field]) throw Error('App identity mismatch: '+field);
  }
}

export function signingOptions(channel = 'daily', identity) {
  if (!['daily', 'testing'].includes(channel)) throw Error('Unknown build channel');
  if (identity !== undefined && !/^[A-Fa-f0-9]{40}$/.test(identity))
    throw Error('Signing identity must be an exact 40-character certificate fingerprint');
  if (channel === 'testing' && !identity)
    throw Error('Testing builds require a persistent signing identity; no ad-hoc fallback');
  return {channel, identity: identity?.toUpperCase() ?? '-',
    bundleID: channel === 'testing' ? 'com.liyunhui.DictionaryApp.testing' : 'com.liyunhui.DictionaryApp',
    name: channel === 'testing' ? 'Dictionary Testing' : 'Dictionary'};
}

export function assertSigningIdentityAvailable(identity, listing) {
  const fingerprints = [...listing.matchAll(/^\s*\d+\) ([A-Fa-f0-9]{40}) /gm)].map(m => m[1].toUpperCase());
  if (!fingerprints.includes(identity.toUpperCase())) throw Error('Requested code-signing identity is not available; no build or permission change performed');
}

export function packageApp(out, binary, metadata, invoke=run, signing=signingOptions()) {
  const app=path.join(out,'Dictionary.app');
  fs.mkdirSync(app);fs.mkdirSync(path.join(app,'Contents/MacOS'),{recursive:true});fs.mkdirSync(path.join(app,'Contents/Resources'));
  const executable=path.join(app,'Contents/MacOS/DictionaryApp');
  fs.copyFileSync(binary,executable,fs.constants.COPYFILE_EXCL);fs.chmodSync(executable,0o755);
  const resourceName='DictionaryApp_DictionaryApp.bundle';
  const resource=path.join(path.dirname(binary),resourceName);
  if(!['Contents/Resources',''].some(prefix=>fs.existsSync(path.join(resource,prefix,'EnglishDictionary/oewn-2025.json.gz'))) || fs.lstatSync(resource).isSymbolicLink()) throw Error('Missing or unsafe dictionary resource bundle');
  fs.cpSync(resource,path.join(app,'Contents/Resources',resourceName),{recursive:true,errorOnExist:true,force:false});
  const icon = ['Contents/Resources/AppIcon.icns','AppIcon.icns'].map(p=>path.join(resource,p)).find(p=>fs.existsSync(p));
  if(!icon || fs.lstatSync(icon).isSymbolicLink() || !fs.lstatSync(icon).isFile()) throw Error('Missing or unsafe app icon resource');
  fs.copyFileSync(icon,path.join(app,'Contents/Resources/AppIcon.icns'),fs.constants.COPYFILE_EXCL);
  const values={CFBundleDevelopmentRegion:'en',CFBundleExecutable:'DictionaryApp',CFBundleIdentifier:signing.bundleID,CFBundleInfoDictionaryVersion:'6.0',CFBundleName:signing.name,CFBundleDisplayName:signing.name,CFBundlePackageType:'APPL',CFBundleShortVersionString:'0.1.0',CFBundleVersion:'0.1.0',LSMinimumSystemVersion:'14.0',NSAppleEventsUsageDescription:'Dictionary uses Apple Events to read the selected text and its surrounding paragraph from Safari, so it can translate the word in context.'};
  values.CFBundleIconFile='AppIcon';
  const plist='<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>'+Object.entries(values).map(([k,v])=>`<key>${k}</key><string>${v}</string>`).join('')+'<key>LSUIElement</key><false/><key>NSHighResolutionCapable</key><true/></dict></plist>\n';
  fs.writeFileSync(path.join(app,'Contents/Info.plist'),plist,{flag:'wx'});
  json(path.join(app,'Contents/Resources/qa-build.json'),metadata);
  invoke('/usr/bin/codesign',['--sign',signing.identity,app]);
  invoke('/usr/bin/codesign',['--verify','--strict',app]);
  return app;
}

export function parseProcesses(output) {
  const lines=output.trim().split('\n');
  if(!output.trim()) throw Error('Cannot inspect processes: empty process table');
  return lines.map(l=>{
    const m=l.match(/^\s*(\d+)\s+(.+)$/);if(!m)throw Error('Cannot inspect process row');
    return {pid:Number(m[1]),executable:m[2]};
  }).filter(p=>path.basename(p.executable)==='DictionaryApp');
}

export function parseListeners(r) {
  if(r.error || (r.status!==0 && r.status!==1) || r.stderr || (r.status===1 && r.stdout)) throw Error('Cannot inspect port 49152');
  if(r.status===1) return [];
  const lines=r.stdout.trim().split('\n');
  if(!lines.some(l=>/^p\d+$/.test(l)) || lines.some(l=>!/^p\d+$|^f\d+$|^n.+/.test(l))) throw Error('Cannot inspect port owners');
  return [...new Set(lines.filter(l=>l.startsWith('p')).map(l=>Number(l.slice(1))))];
}

export function runtime() {
  const processes=parseProcesses(run('/bin/ps',['-ww','-axo','pid=,comm=']));
  const listeners=parseListeners(spawnSync('/usr/sbin/lsof',['-nP','-iTCP:49152','-sTCP:LISTEN','-Fpn'],{encoding:'utf8'}));
  return {processes,listeners};
}

export function assertLaunchSafe(processes, listeners) {
  if(processes.length || listeners.length) throw Error('Launch blocked; quit conflicting apps manually. '+JSON.stringify({processes,listeners}));
}

export function inspect(out) {
  const manifest=JSON.parse(fs.readFileSync(path.join(out,'build-manifest.json'),'utf8'));
  if(manifest.ready!==true) throw Error('Build is not ready');
  verifySnapshot(path.join(out,'source'),manifest.source);
  assertIdentity(manifest.identity,binaryIdentity(path.join(out,'Dictionary.app')));
  const embedded=JSON.parse(fs.readFileSync(path.join(out,'Dictionary.app/Contents/Resources/qa-build.json'),'utf8'));
  if(embedded.buildID!==manifest.buildID || embedded.sourceFingerprint!==manifest.source.fingerprint) throw Error('Embedded build identity mismatch');
  return manifest;
}

function build(signing=signingOptions()) {
  if (signing.identity !== '-')
    assertSigningIdentityAvailable(signing.identity, run('/usr/bin/security', ['find-identity', '-v', '-p', 'codesigning']));
  const paths=run('/usr/bin/git',['ls-files','--cached','--others','--exclude-standard','-z']).split('\0').filter(Boolean);
  assertKnownInputs(paths);
  const buildID=stamp();const out=path.join(project,'build/qa.noindex',buildID);
  fs.mkdirSync(path.dirname(out),{recursive:true});fs.mkdirSync(out,{mode:0o700});
  const source=snapshot(project,path.join(out,'source'));
  const metadata={buildID,channel:signing.channel,sourceFingerprint:source.fingerprint,head:run('/usr/bin/git',['rev-parse','HEAD']).trim(),dirty:!!run('/usr/bin/git',['status','--porcelain']).trim(),createdAt:new Date().toISOString()};
  const toolchain={swift:run('/usr/bin/xcrun',['swift','--version']).trim(),sdk:run('/usr/bin/xcrun',['--show-sdk-path']).trim(),sdkVersion:run('/usr/bin/xcrun',['--show-sdk-version']).trim(),architecture:run('/usr/bin/uname',['-m']).trim(),configuration:'release'};
  json(path.join(out,'source-manifest.json'),source);
  console.log('Building frozen source: '+out);
  const args=['swift','build','-c','release','--package-path',path.join(out,'source'),'--scratch-path',path.join(out,'scratch')];
  const compiled=spawnSync('/usr/bin/xcrun',args,{cwd:out,encoding:'utf8',maxBuffer:16*1024*1024});
  fs.writeFileSync(path.join(out,'build.log'),(compiled.stdout??'')+(compiled.stderr??''),{flag:'wx',mode:0o600});
  if(compiled.error || compiled.status!==0) throw Error('Release build failed; inspect '+path.join(out,'build.log'));
  const binPath=run('/usr/bin/xcrun',[...args,'--show-bin-path'],out).trim();
  verifySnapshot(path.join(out,'source'),source);
  const app=packageApp(out,path.join(binPath,'DictionaryApp'),metadata,run,signing);
  const manifest={...metadata,ready:true,toolchain,source,identity:binaryIdentity(app),signingNote:signing.identity === '-' ? 'Ad-hoc archive: permission continuity is not guaranteed. Do not use for routine desktop iteration.' : 'Certificate-signed build. Check running-process trust; do not reset permissions routinely.'};
  json(path.join(out,'build-manifest.json'),manifest);
  console.log(JSON.stringify({out,...metadata,identity:manifest.identity},null,2));
}

async function launch(out) {
  const manifest=inspect(out);
  const before=runtime();assertLaunchSafe(before.processes,before.listeners);
  const runID=stamp(), directory=path.join(out,'runs',runID);fs.mkdirSync(directory,{recursive:true,mode:0o700});
  // Inherit provider configuration without serializing or printing any environment values.
  const child=spawn(manifest.identity.executable,[],{cwd:project,detached:true,stdio:'ignore',env:{...process.env,DICTIONARY_QA_LOG:path.join(directory,'events.jsonl'),DICTIONARY_QA_RUN_ID:runID}});
  await new Promise((resolve,reject)=>{child.once('spawn',resolve);child.once('error',reject);});child.unref();
  json(path.join(directory,'launch.json'),{buildID:manifest.buildID,runID,pid:child.pid,expectedIdentity:manifest.identity});
  for(let n=0;n<40;n++) {
    const state=runtime();
    const match=state.processes.find(p=>p.pid===child.pid);
    if(match && match.executable!==manifest.identity.executable) throw Error('Runtime executable identity mismatch');
    if(state.processes.some(p=>p.pid!==child.pid) || state.listeners.some(pid=>pid!==child.pid)) throw Error('New process/port conflict after launch; stop QA and inspect manually');
    if(match && state.listeners.includes(child.pid)) {
      assertIdentity(manifest.identity,binaryIdentity(path.join(out,'Dictionary.app')));
      json(path.join(directory,'runtime-verified.json'),{buildID:manifest.buildID,runID,pid:child.pid,...state,identity:manifest.identity});
      console.log('Runtime identity and HTTP port owner verified. Evidence: '+directory);return;
    }
    await new Promise(resolve=>setTimeout(resolve,200));
  }
  throw Error('Runtime not verified within 8 seconds. App was not terminated; inspect launch.json and quit manually before retrying.');
}

// A stable Finder entry, not an installation or a new signing identity.
// Old bundles and every previous entry remain available for deliberate rollback.
export function selectDailyBuild(root, directory, verify=inspect, checkRuntime=runtime) {
  const qa=path.join(root,'build/qa.noindex');
  const out=path.resolve(directory);
  if(path.dirname(out)!==qa || fs.realpathSync(out)!==out ||
     fs.realpathSync(path.join(out,'Dictionary.app'))!==path.join(out,'Dictionary.app'))
    throw Error('Daily target must be a real build/qa.noindex directory');
  const state=checkRuntime();assertLaunchSafe(state.processes,state.listeners);
  const manifest=verify(out);
  if (manifest.channel === 'testing') throw Error('Testing channel cannot become the daily entry');
  const entry=path.join(root,'build/Dictionary-Daily.app');
  const target=path.relative(path.dirname(entry),path.join(out,'Dictionary.app'));
  let old;
  try {
    if(!fs.lstatSync(entry).isSymbolicLink()) throw Error('Existing daily entry is not a symlink; refused');
    old=fs.readlinkSync(entry);
    const resolved=path.resolve(path.dirname(entry),old);
    if(path.basename(resolved)!=='Dictionary.app' || path.dirname(path.dirname(resolved))!==qa)
      throw Error('Existing daily entry is outside build/qa.noindex; refused');
    if(resolved===path.join(out,'Dictionary.app')) return {entry,buildID:manifest.buildID,unchanged:true};
  } catch(error) { if(error.code!=='ENOENT') throw error; }
  let previous;
  const id=stamp();
  if(old) {
    const history=path.join(root,'build/daily-history');
    fs.mkdirSync(history,{recursive:true});
    if(fs.realpathSync(history)!==history) throw Error('Symlink history directory refused');
    previous=path.join(history,id+'.app');
    fs.symlinkSync(path.relative(history,path.resolve(path.dirname(entry),old)),previous);
  }
  // Refuse a concurrent change rather than replacing an unexpected entry.
  if(old) {
    const temporary=path.join(root,'build',`.daily-${id}.app`);
    fs.symlinkSync(target,temporary);
    if(!fs.lstatSync(entry).isSymbolicLink() || fs.readlinkSync(entry)!==old)
      throw Error('Daily entry changed during update; refused');
    fs.renameSync(temporary,entry);
  } else {
    // Link creation is exclusive; never replace a concurrently created entry.
    fs.symlinkSync(target,entry);
  }
  return {entry,buildID:manifest.buildID,previous,unchanged:false};
}

async function main() {
  const [command,argument,...rest]=process.argv.slice(2);
  if(command==='build' || command==='build-testing') {
    if (argument !== undefined && (argument !== '--signing-identity' || rest.length !== 1))
      throw Error('Use --signing-identity <certificate-fingerprint>');
    return build(signingOptions(command === 'build-testing' ? 'testing' : 'daily', rest[0]));
  }
  if(command==='stage-testing' && argument && rest.length === 0) {
    const {stageTestingBuild} = await import('./testing-app.mjs');
    console.log(JSON.stringify(stageTestingBuild(project, path.resolve(argument)), null, 2));return;
  }
  if(command==='daily' && argument) {
    console.log(JSON.stringify(selectDailyBuild(project,path.resolve(argument)),null,2));return;
  }
  if(command==='preflight') { const state=runtime();console.log(JSON.stringify(state,null,2));assertLaunchSafe(state.processes,state.listeners);return; }
  if((command==='inspect' || command==='launch') && argument) {
    const out=path.resolve(argument);
    if(command==='inspect') console.log(JSON.stringify(inspect(out),null,2));
    else await launch(out);
    return;
  }
  throw Error('Usage: node scripts/qa-app.mjs build [--signing-identity <fingerprint>] | build-testing --signing-identity <fingerprint> | stage-testing <build-directory> | preflight | inspect <build-directory> | launch <build-directory> | daily <build-directory>');
}
if(process.argv[1] && path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) main().catch(error=>{console.error(error.message);process.exitCode=1;});
