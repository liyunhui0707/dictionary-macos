#!/usr/bin/env node
// Explicit local packaging only. No upload, installation, credentials or permission changes.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {packageApp, signingOptions} from './qa-app.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
function run(command, args, cwd=root) {
  const result=spawnSync(command,args,{cwd,encoding:'utf8',maxBuffer:16*1024*1024});
  if(result.error || result.status!==0) throw Error(path.basename(command)+' failed; '+(result.stderr ?? ''));
  return result.stdout;
}
const hash=data=>crypto.createHash('sha256').update(data).digest('hex');

export function auditPublicApp(app) {
  const forbidden=/\/Users\/|-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----|\bsk-(?:ant-|proj-)?[A-Za-z0-9_-]{24,}|\bgh[pousr]_[A-Za-z0-9]{30,}/;
  const records=[];
  function visit(relative) {
    const file=path.join(app,relative), stat=fs.lstatSync(file);
    if(stat.isSymbolicLink()) throw Error('Symlink in public App refused');
    if(stat.isDirectory()) { for(const name of fs.readdirSync(file).sort()) visit(path.join(relative,name)); return; }
    if(!stat.isFile() || /(?:qa-build\.json|\.env(?:\.|$)|\.p12$|\.pfx$|\.pem$|\.key$)/i.test(relative))
      throw Error('Private/unexpected public payload refused');
    const data=fs.readFileSync(file);
    if(forbidden.test(data.toString('utf8'))) throw Error('Private-path or credential-like public payload refused: '+relative);
    records.push({path:relative,bytes:data.length,sha256:hash(data)});
  }
  visit('Contents');
  return records;
}

function main() {
  if(process.argv.length!==2) throw Error('Usage: node scripts/release-app.mjs (clean committed source only)');
  if(run('/usr/bin/git',['status','--porcelain']).trim()) throw Error('Commit and review the release candidate before packaging');
  const commit=run('/usr/bin/git',['rev-parse','HEAD']).trim();
  const version=fs.readFileSync(path.join(root,'VERSION'),'utf8').trim();
  if(!/^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/.test(version)) throw Error('Invalid VERSION');
  const arch=run('/usr/bin/uname',['-m']).trim();
  if(!['arm64','x86_64'].includes(arch)) throw Error('Unsupported host architecture');
  const out=path.join(root,'build/releases.noindex',version+'-'+arch);
  fs.mkdirSync(path.dirname(out),{recursive:true}); fs.mkdirSync(out,{mode:0o700});
  // A source export with no Git history/private files, built outside the maintainer's home.
  const scratch=fs.mkdtempSync('/private/tmp/dictionary-public-build-');
  const source=path.join(scratch,'source'); fs.mkdirSync(source);
  const tar=path.join(scratch,'source.tar');
  run('/usr/bin/git',['archive','--format=tar','--output='+tar,'HEAD','Package.swift','VERSION','Sources','LICENSE','THIRD_PARTY_NOTICES.md']);
  run('/usr/bin/tar',['-xf',tar,'-C',source]);
  const args=['swift','build','-c','release','--package-path',source,'--scratch-path',path.join(scratch,'scratch')];
  console.log('Building committed '+commit+' for '+arch+'; private build log in output directory.');
  const build=spawnSync('/usr/bin/xcrun',args,{cwd:scratch,encoding:'utf8',maxBuffer:16*1024*1024});
  fs.writeFileSync(path.join(out,'build.log'),(build.stdout??'')+(build.stderr??''),{flag:'wx',mode:0o600});
  if(build.error || build.status!==0) throw Error('Release compile failed; inspect private build.log');
  const bin=path.join(run('/usr/bin/xcrun',[...args,'--show-bin-path'],scratch).trim(),'DictionaryApp');
  const stripped=path.join(scratch,'DictionaryApp'); fs.copyFileSync(bin,stripped);
  run('/usr/bin/strip',['-S',stripped]); fs.copyFileSync(stripped,bin);
  const stage=path.join(out,'image'); fs.mkdirSync(stage);
  const app=packageApp(stage,bin,{productVersion:version},run,signingOptions(),false);
  const notices=path.join(app,'Contents/Resources/Notices'); fs.mkdirSync(notices);
  for(const name of ['LICENSE','THIRD_PARTY_NOTICES.md']) fs.copyFileSync(path.join(source,name),path.join(notices,name));
  run('/usr/bin/codesign',['--force','--sign','-',app]);
  run('/usr/bin/codesign',['--verify','--strict',app]);
  const architecture=run('/usr/bin/lipo',['-archs',path.join(app,'Contents/MacOS/DictionaryApp')]).trim();
  if(architecture!==arch) throw Error('Built architecture mismatch');
  const files=auditPublicApp(app);
  const stem='Dictionary-'+version+'-macOS-'+arch;
  const zip=path.join(out,stem+'.zip'), dmg=path.join(out,stem+'.dmg');
  run('/usr/bin/ditto',['-c','-k','--sequesterRsrc','--keepParent',app,zip]);
  fs.symlinkSync('/Applications',path.join(stage,'Applications'));
  run('/usr/bin/hdiutil',['create','-volname','Dictionary '+version,'-srcfolder',stage,'-ov','-format','UDZO',dmg]);
  run('/usr/bin/hdiutil',['verify',dmg]);
  const assets=[zip,dmg].map(file=>({name:path.basename(file),sha256:hash(fs.readFileSync(file)),bytes:fs.statSync(file).size}));
  fs.writeFileSync(path.join(out,'SHA256SUMS'),assets.map(a=>a.sha256+'  '+a.name).join('\n')+'\n',{flag:'wx'});
  fs.writeFileSync(path.join(out,'release-manifest.json'),JSON.stringify({version,commit,architecture,minimumOS:'14.0',signing:'ad-hoc',notarized:false,assets,files},null,2)+'\n',{flag:'wx'});
  console.log('Packaged '+version+' (ad-hoc, NOT notarized): '+out);
  console.log('No upload or installed App replacement performed. Build scratch retained for inspection.');
}
if(process.argv[1] && path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  try { main(); } catch(error) { console.error(error.message); process.exitCode=1; }
}
