#!/usr/bin/env node
// No dependencies, hooks, installs, app launch/termination, permissions or credential reads.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import os from 'node:os';
import {fileURLToPath} from 'node:url';
import {spawn,spawnSync} from 'node:child_process';
import {suites,plan} from './e2e/registry.mjs';
export {plan};
const project=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const sha=data=>crypto.createHash('sha256').update(data).digest('hex');
const blockedPath=p=>p.split('/').some(s=>/^\.env(?:\.|$)|^(secrets|\.git|build|node_modules)$|\.(pem|key|p12|pfx)$/i.test(s));
const hashable=p=>/^(Sources|Tests|scripts|extensions|docs)\//.test(p)||['Package.swift','README.md','.gitignore'].includes(p);
const print=value=>console.log(JSON.stringify(value,null,2));
function git(root,args) {
  const r=spawnSync('/usr/bin/git',args,{cwd:root,encoding:'utf8'});
  if(r.error||r.status!==0) throw Error('Git discovery failed; no tests executed');
  return r.stdout;
}
export function discoverChanges(root,invoke=(cmd,args)=>git(root,args)) {
  return [...new Set([
    ...invoke('git',['diff','--name-only','-z','--no-renames']).split('\0'),
    ...invoke('git',['diff','--cached','--name-only','-z','--no-renames']).split('\0'),
    ...invoke('git',['ls-files','--others','--exclude-standard','-z']).split('\0')
  ].filter(Boolean))].sort();
}
export function fingerprint(root,paths=git(root,['ls-files','--cached','--others','--exclude-standard','-z']).split('\0')) {
  const files=[];
  for(const p of [...new Set(paths.filter(Boolean))].sort()) {
    if(blockedPath(p)) continue;
    if(path.isAbsolute(p)||p.split('/').includes('..')) throw Error('Unsafe evidence input path');
    if(!hashable(p)) continue;
    const absolute=path.join(root,p);
    // Check every component before opening, including directory symlinks.
    let current=root,missing=false;
    for(const part of p.split('/')) {
      current=path.join(current,part);
      if(!fs.existsSync(current)){missing=true;break;}
      if(fs.lstatSync(current).isSymbolicLink()) throw Error('Symlink evidence input refused');
    }
    if(missing){files.push({path:p,deleted:true});continue;}
    const stat=fs.lstatSync(absolute);
    if(!stat.isFile()) throw Error('Non-regular evidence input refused');
    files.push({path:p,mode:stat.mode&0o777,sha256:sha(fs.readFileSync(absolute))});
  }
  return {files,fingerprint:sha(JSON.stringify(files))};
}
export function changesSince(before,after) {
  const a=new Map(before.files.map(f=>[f.path,JSON.stringify(f)])),b=new Map(after.files.map(f=>[f.path,JSON.stringify(f)]));
  return [...new Set([...a.keys(),...b.keys()])].filter(p=>a.get(p)!==b.get(p)).sort();
}
export function gates(id,options) {
  const suite=suites.find(s=>s.id===id);
  if(!suite) throw Error('Unknown suite');
  return [...(suite.gui&&!options.allowGui?['--allow-gui']:[]),
    ...(suite.model&&!options.allowModel?['--allow-model']:[]),
    ...(suite.level==='L4'&&!options.allowFull?['--allow-full']:[])];
}
export function select(options) {
  if(!options.suites?.length) throw Error('run requires explicit --suite; no default test execution');
  for(const key of ['suites','cases'])if(Object.hasOwn(options,key)) {
    if(!Array.isArray(options[key])||!options[key].length||options[key].some(id=>typeof id!=='string'||!/^[A-Za-z0-9][A-Za-z0-9-]*$/.test(id)))throw Error('Invalid explicit '+key+' selector; empty entries are not allowed');
  }
  for(const id of options.suites) if(!suites.some(s=>s.id===id)) throw Error('Unknown suite: '+id);
  const chosen=suites.filter(s=>options.suites.includes(s.id));
  for(const id of options.cases??[]) if(!chosen.some(s=>s.cases.some(c=>c.id===id))) throw Error('Unknown case in selected suites: '+id);
  if(options.match&&chosen.some(s=>!['node','swift'].includes(s.adapter)))throw Error('--match is supported only for Node/Swift tests, never silently ignored by live routes');
  if(options.qaBuild&&!chosen.some(s=>s.adapter==='native'))throw Error('--qa-build applies only to native smoke');
  return chosen;
}
const escaped=s=>s.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
export function commandFor(suite,item,options,root,output) {
  if(suite.adapter==='node') return {program:process.execPath,args:['--test','--test-reporter=tap',...(options.match?['--test-name-pattern',options.match]:[]),...suite.files],parser:'node'};
  const cache=path.join(root,'build/e2e/cache');
  const args=['swift','test','--cache-path',path.join(cache,'packages'),'--config-path',path.join(cache,'config'),
    '--scratch-path',path.join(cache,'swift'),'--disable-sandbox','--disable-xctest','-Xswiftc','-module-cache-path','-Xswiftc',path.join(cache,'modules')];
  const plugin='/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing';
  if(fs.existsSync(plugin)) args.push('-Xswiftc','-plugin-path','-Xswiftc',plugin);
  if(item.filter) args.push('--filter',escaped(item.filter)+(options.match?'/.*'+escaped(options.match):''));
  else if(options.match) throw Error('--match requires a filtered Swift case');
  return {program:'/usr/bin/xcrun',args,parser:'swift',env:{CLANG_MODULE_CACHE_PATH:path.join(cache,'clang'),SWIFTPM_MODULECACHE_OVERRIDE:path.join(cache,'swiftpm')}};
}
export function parseCounts(output,kind) {
  if(kind==='node') {
    const read=name=>output.match(new RegExp(`^# ${name} (\\d+)$`,'m'));
    if(!read('pass')||!read('fail')||!read('skipped')) return null;
    return {PASS:Number(read('pass')[1]),FAIL:Number(read('fail')[1]),SKIP:Number(read('skipped')[1])};
  }
  const summary=[...output.matchAll(/Test run with (\d+) tests?(?: in \d+ suites?)? (passed|failed)(?:[^\n]*?with (\d+) issues?)?/g)].at(-1);
  if(!summary) return null;
  // Failed Swift runs don't expose reliable failed-test counts in this summary.
  if(summary[2]==='failed') return null;
  const skipped=[...output.matchAll(/Test [^\n]+ skipped/g)].length;
  return {PASS:Number(summary[1])-skipped,FAIL:0,SKIP:skipped};
}
export function testOutcome(result) {
  if(result.exitCode!==0||!result.counts||result.counts.FAIL>0) return 'FAIL';
  if(result.counts.SKIP>0) return 'BLOCKED';
  if(result.counts.PASS===0) return 'FAIL';
  return 'PASS';
}
async function command(command,log,root) {
  const stream=fs.openSync(log,'wx',0o600);
  let exitCode;
  try {
    exitCode=await new Promise(resolve=>{
      const child=spawn(command.program,command.args,{cwd:root,stdio:['ignore',stream,stream],env:{...process.env,...command.env}});
      child.once('error',()=>resolve(-1)); child.once('close',code=>resolve(code??-1));
    });
  } finally {fs.closeSync(stream);}
  return {exitCode,counts:parseCounts(fs.readFileSync(log,'utf8'),command.parser)};
}
export function acquireGuiLock(folder,runID) {
  safeDirectory(folder);
  const lock=path.join(folder,'.gui-lock');
  try{fs.mkdirSync(lock,{mode:0o700});}catch{throw Error('GUI lock exists or cannot be created; inspect manually; never stolen automatically');}
  const owner=path.join(lock,'owner.json'),token=crypto.randomBytes(12).toString('hex');
  fs.writeFileSync(owner,JSON.stringify({runID,pid:process.pid,token}),{flag:'wx',mode:0o600});
  let released=false;
  return ()=>{
    if(released)return;
    if(JSON.parse(fs.readFileSync(owner,'utf8')).token!==token) throw Error('GUI lock ownership changed; manual recovery required');
    fs.unlinkSync(owner);fs.rmdirSync(lock);released=true;
  };
}
function metadata(root) {return {head:git(root,['rev-parse','HEAD']).trim(),branch:git(root,['branch','--show-current']).trim(),changed:discoverChanges(root)};}
let context;
const executionContext=()=>context??=(
  {node:process.version,nodeBinarySHA256:sha(fs.readFileSync(process.execPath)),osRelease:os.release(),platform:process.platform,arch:process.arch});
export function planSinceRun(root,prior,changed,current,goals=[]) {
  const oldPaths=Array.isArray(prior.metadata?.changed)?prior.metadata.changed:[];
  const delta=Array.isArray(prior.inputs?.files)?changesSince(prior.inputs,current):[];
  const requested=Array.isArray(prior.request?.suites)?prior.request.suites.filter(id=>suites.some(s=>s.id===id)):[];
  const paths=[...new Set([...changed,...oldPaths,...delta])].sort();
  const base=plan(paths,[...new Set([...goals,...requested])]);
  if(!base.recommended.length&&!requested.length) {
    const unknown=plan(['unknown-history-input']);base.recommended=unknown.recommended;base.warnings.push(...unknown.warnings);
  }
  const begin=Date.parse(prior.startedAt),end=Date.parse(prior.finishedAt);
  const reusable=prior.schemaVersion===2&&prior.completed===true&&prior.dryRun===false&&prior.inputsUnchanged===true&&
    Number.isFinite(begin)&&Number.isFinite(end)&&end>=begin&&Array.isArray(prior.request?.cases)&&
    JSON.stringify(prior.executionContext)===JSON.stringify(executionContext())&&
    prior.inputs?.fingerprint===current.fingerprint&&JSON.stringify(prior.inputs?.files)===JSON.stringify(current.files)&&!base.warnings.length;
  const coverage={reused:[],unverified:[]};
  for(const recommendation of base.recommended) {
    const suite=suites.find(s=>s.id===recommendation.suite);
    recommendation.cases=[];
    for(const item of suite.cases) {
      const matches=(Array.isArray(prior.results)?prior.results:[]).filter(r=>r?.suite===suite.id&&r?.case===item.id);
      const r=matches.length===1?matches[0]:null;
      const validTime=r&&Number.isFinite(Date.parse(r.startedAt))&&Number.isFinite(Date.parse(r.finishedAt))&&
        Date.parse(r.startedAt)>=begin&&Date.parse(r.startedAt)<=Date.parse(r.finishedAt)&&Date.parse(r.finishedAt)<=end;
      // Live/engine/Swift toolchains are not proven by the recorded Node context.
      // Reuse only a complete, unfiltered deterministic Node case, never a suite.
      const usesUnprovenSwift=suite.id==='infra'&&item.id==='runner';
      const eligible=reusable&&!usesUnprovenSwift&&suite.level==='L1'&&suite.adapter==='node'&&requested.includes(suite.id)&&
        r?.selected===true&&r.status==='PASS'&&r.scope==='full-case'&&prior.request.match===null&&validTime&&
        (!prior.request.cases.length||prior.request.cases.includes(item.id))&&
        r.exitCode===0&&Number.isSafeInteger(r.tests?.PASS)&&r.tests.PASS>0&&r.tests.FAIL===0&&r.tests.SKIP===0&&
        JSON.stringify(r.command)===JSON.stringify(commandFor(suite,item,{},root,''));
      if(eligible)coverage.reused.push({suite:suite.id,case:item.id,runID:prior.runID,status:'historical PASS',scope:'full-case'});
      else {
        const reason=usesUnprovenSwift?'infra/runner invokes Swift; Node-only history cannot prove its compiler/SDK. Rerun when in scope':
          !reusable?'History/input/context is incomplete, changed, legacy or not reusable':
          suite.adapter!=='node'||suite.level!=='L1'?'Runtime/toolchain evidence cannot be reused from file hashes':
          'No complete unfiltered PASS for this exact case';
        recommendation.cases.push({id:item.id,reason});coverage.unverified.push({suite:suite.id,case:item.id,previousStatus:r?.status??'missing',reason});
      }
    }
  }
  base.recommended=base.recommended.filter(r=>r.cases.length);
  if(coverage.unverified.length)base.warnings.push('Unverified case obligations remain; changed-file equality does not establish passed coverage.');
  return {...base,baselineRun:prior.runID??null,coverage};
}
export function safeDirectory(directory) {
  const absolute=path.resolve(directory);
  let current=path.parse(absolute).root;
  for(const part of absolute.slice(current.length).split(path.sep).filter(Boolean)) {
    current=path.join(current,part);
    if(!fs.existsSync(current))fs.mkdirSync(current,{mode:0o700});
    if(fs.lstatSync(current).isSymbolicLink()||!fs.statSync(current).isDirectory())throw Error('Symlink/non-directory output refused');
  }
}
export async function execute(root,options,deps={}) {
  const chosen=select(options),runID=new Date().toISOString().replace(/[:.]/g,'-')+'-'+crypto.randomBytes(3).toString('hex');
  const output=deps.output??path.join(root,'build/e2e',runID);
  if(!deps.output){safeDirectory(path.dirname(output));fs.mkdirSync(output,{mode:0o700});}
  const report={schemaVersion:2,runID,startedAt:new Date().toISOString(),dryRun:!!options.dryRun,executionContext:executionContext(),
    request:{suites:options.suites,cases:options.cases??[],match:options.match??null,
      allowGui:!!options.allowGui,allowModel:!!options.allowModel,allowFull:!!options.allowFull,qaBuild:options.qaBuild??null},
    historicalReferences:[{date:'2026-10-25',summary:'docs/qa/phase1a/integration-2026-10-25/automation/qa-summary.json',
      note:'Historical evidence only; IQA-M1 mandatory semantics Failed (6/12); never included in current counts'}],
    completed:false,metadata:(deps.metadata??metadata)(root),inputs:(deps.fingerprint??fingerprint)(root),
    results:suites.flatMap(s=>s.cases.map(c=>({suite:s.id,case:c.id,level:s.level,evidence:c.evidence,ac:c.ac,
      selected:chosen.includes(s)&&(!options.cases?.length||options.cases.includes(c.id)),scope:options.match?'filtered':'full-case',status:'NOT_RUN'})))};
  // Persist before execution so an interrupted run cannot masquerade as a completed pass.
  const save=()=>fs.writeFileSync(path.join(output,'report.json'),JSON.stringify(report,null,2)+'\n',{mode:0o600});
  save();
  let haltGui=false;
  for(const result of report.results.filter(r=>r.selected)) {
    const suite=suites.find(s=>s.id===result.suite),item=suite.cases.find(c=>c.id===result.case);
    result.missingFlags=gates(suite.id,options);
    if(['node','swift'].includes(suite.adapter)) result.command=commandFor(suite,item,options,root,output);
    if(options.dryRun) {result.reason='Plan only; no child tests, GUI, runtime inspection or model call executed';continue;}
    if(suite.gui&&haltGui){result.status='BLOCKED';result.reason='Earlier GUI operation failed or could not restore state; no subsequent GUI operation attempted';continue;}
    if(result.missingFlags.length){result.status='BLOCKED';result.reason='Missing explicit '+result.missingFlags.join(' and ');continue;}
    if(['manual','unavailable'].includes(suite.adapter)) {
      result.status=suite.adapter==='manual'?'MANUAL_REQUIRED':'BLOCKED';result.reason=suite.reason;continue;
    }
    let release;
    result.startedAt=new Date().toISOString();
    result.status='BLOCKED';result.reason='Execution started; completion not yet recorded';save();
    try {
      if(suite.gui) release=acquireGuiLock(path.join(root,'build/e2e'),runID);
      if(suite.adapter==='native') {
        const native=deps.native??(await import('./e2e/native.mjs')).runNative;
        delete result.reason;
        Object.assign(result,await native({root,output,options,caseID:item.id}));
      } else {
        if(suite.adapter==='swift')for(const folder of ['packages','config','swift','modules','swiftpm','clang'])safeDirectory(path.join(root,'build/e2e/cache',folder));
        result.log=`${suite.id}--${item.id}.log`;
        const executed=await(deps.command??command)(result.command,path.join(output,result.log),root);
        result.exitCode=executed.exitCode;result.tests=executed.counts;result.status=testOutcome(executed);delete result.reason;
        if(!executed.counts)result.reason='No verifiable test summary (or failed Swift summary); inspect private log; no test-count inference';
        else if(executed.counts.SKIP>0)result.reason='Selected tests were skipped; coverage incomplete';
        else if(executed.counts.PASS===0)result.reason='No matching non-skipped tests; never a PASS';
      }
    } catch(error) {
      result.status='BLOCKED';result.reason=error.message;
      if(suite.adapter==='native'&&error.nativeIdentity){result.identity=error.nativeIdentity;result.actions=error.nativeActions;}
    }
    finally {
      if(release)try{release();}catch(error){result.status='BLOCKED';result.reason=error.message;}
      if(suite.gui&&result.status!=='PASS')haltGui=true;
      result.finishedAt=new Date().toISOString();save();
    }
  }
  const after=(deps.fingerprint??fingerprint)(root);
  report.inputsUnchanged=report.inputs.fingerprint===after.fingerprint;
  if(!report.inputsUnchanged)for(const result of report.results.filter(r=>r.status==='PASS')) {
    result.status='BLOCKED';result.reason='Input inventory changed during execution; original evidence is not a stable-version PASS';
  }
  report.finishedAt=new Date().toISOString();report.completed=true;
  report.counts=Object.fromEntries(['PASS','FAIL','BLOCKED','NOT_RUN','MANUAL_REQUIRED'].map(s=>[s,report.results.filter(r=>r.status===s).length]));
  report.output=path.relative(root,output);save();return report;
}
export function parseOptions(args) {
  const result={suites:[],paths:[],goals:[]},value={ '--suite':'suites','--case':'cases','--path':'paths','--goal':'goals','--match':'match','--qa-build':'qaBuild','--since-run':'sinceRun' },
    flags={'--changed':'changed','--dry-run':'dryRun','--allow-gui':'allowGui','--allow-model':'allowModel','--allow-full':'allowFull'};
  for(let i=0;i<args.length;i++) {
    const arg=args[i];
    if(flags[arg]){result[flags[arg]]=true;continue;}
    if(value[arg]) {
      const v=args[++i];if(!v||v.startsWith('--'))throw Error('Missing value for '+arg);
      if(arg==='--suite'||arg==='--case') {
        const ids=v.split(',').map(id=>id.trim());
        if(ids.some(id=>!/^[A-Za-z0-9][A-Za-z0-9-]*$/.test(id)))throw Error('Invalid '+arg+' selector; empty entries are not allowed');
        result[value[arg]]=[...new Set([...(result[value[arg]]??[]),...ids])];
      } else if(Array.isArray(result[value[arg]]))result[value[arg]].push(...v.split(',').filter(Boolean));else result[value[arg]]=v;
      continue;
    }
    throw Error('Unknown option: '+arg);
  }
  if(result.changed&&result.paths.length)throw Error('Choose --changed or explicit --path, not both');
  if(result.sinceRun&&(result.changed||result.paths.length))throw Error('Choose --since-run OR --changed/--path');
  return result;
}
function readReport(id) {
  if(!id||!/^\d{4}-[A-Za-z0-9-]+$/.test(id))throw Error('report requires an owned run ID');
  const file=path.join(project,'build/e2e',id,'report.json');
  if(fs.realpathSync(file)!==file)throw Error('Symlink report refused');
  const report=JSON.parse(fs.readFileSync(file,'utf8'));
  if(![1,2].includes(report.schemaVersion)||report.runID!==id)throw Error('Unknown report schema/run identity');
  return report;
}
export async function main(args=process.argv.slice(2)) {
  const [verb='list',...rest]=args;
  if(verb==='report') {
    if(rest.length!==1)throw Error('report requires one owned run ID');
    print(readReport(rest[0]));return;
  }
  const opts=parseOptions(rest);
  if(verb==='list') {
    if(rest.length)throw Error('list accepts no options');
    print({command:'list',executed:false,suites:suites.map(s=>({...s,cases:s.cases.map(c=>({...c,status:'NOT_RUN'}))}))});return;
  }
  if(verb==='plan') {
    if(opts.suites.length||opts.cases?.length||opts.allowGui||opts.allowModel||opts.allowFull||opts.dryRun||opts.match||opts.qaBuild)throw Error('plan accepts only change/goal selectors');
    let paths=opts.paths.length?opts.paths:discoverChanges(project);
    if(opts.sinceRun) {
      const prior=readReport(opts.sinceRun);
      print(planSinceRun(project,prior,paths,fingerprint(project),opts.goals));return;
    }
    print({...plan(paths,opts.goals),baselineRun:opts.sinceRun??null});return;
  }
  if(verb==='run') {
    if(opts.changed||opts.paths.length||opts.goals.length||opts.sinceRun)throw Error('Change/goal discovery is plan-only; run requires explicit suites/cases');
    const report=await execute(project,opts);print({runID:report.runID,counts:report.counts,report:report.output+'/report.json'});
    if(report.counts.FAIL)process.exitCode=1;
    else if(report.counts.BLOCKED||report.counts.MANUAL_REQUIRED)process.exitCode=2;
    return;
  }
  if(verb==='help') {print({usage:['node scripts/e2e.mjs [list]','node scripts/e2e.mjs plan [--changed | --path <relative-path> ... | --since-run <run-id>] [--goal <goal>]',
    'node scripts/e2e.mjs run --suite <id> [--case <id>] [--match <test-name>] [--dry-run]',
    'GUI/model/full gates: --allow-gui --allow-model --allow-full; native also --qa-build <directory>',
    'node scripts/e2e.mjs report <run-id>']});return;}
  throw Error('Unknown command; use list, plan, run, report or help');
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url))main().catch(error=>{console.error(error.message);process.exitCode=1;});
