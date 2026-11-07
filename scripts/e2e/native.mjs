// Reuses qa-app.mjs identity verification and the successful bounded TextEdit AX probe.
// Only --allow-gui + --allow-model can reach this adapter. It never opens/closes documents.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {assertIdentity,parseProcesses,parseListeners} from '../qa-app.mjs';

export function assertRuntime(identity,state) {
  if(state.processes.length!==1||state.processes[0].executable!==identity.executable||
     state.listeners.length!==1||state.listeners[0]!==state.processes[0].pid) {
    throw Error('Current Dictionary identity/sole port owner mismatch; no input sent');
  }
  return state.processes[0].pid;
}
const hash=data=>crypto.createHash('sha256').update(data).digest('hex');
function invoke(program,args,root) {
  const r=spawnSync(program,args,{cwd:root,encoding:'utf8',timeout:120000,maxBuffer:16*1024*1024});
  // Do not persist arbitrary subprocess error text or environment.
  if(r.error||r.status!==0)throw Error('Native prerequisite command failed: '+path.basename(program));
  return r.stdout;
}
export function assertProductionInputs(root,manifest,call=invoke) {
  const relevant=p=>p==='Package.swift'||p.startsWith('Sources/')||p.startsWith('extensions/');
  const expected=manifest.source.files.filter(f=>relevant(f.path));
  const actual=call('/usr/bin/git',['ls-files','--cached','--others','--exclude-standard','-z'],root).split('\0').filter(relevant).sort();
  if(JSON.stringify(actual)!==JSON.stringify(expected.map(f=>f.path).sort()))throw Error('Candidate production input inventory differs from Worktree');
  for(const f of expected) {
    let item=root;
    for(const component of f.path.split('/')) {
      item=path.join(item,component);
      if(fs.lstatSync(item).isSymbolicLink())throw Error('Symlink production input refused');
    }
    const st=fs.statSync(item);
    if(!st.isFile()||hash(fs.readFileSync(item))!==f.sha256||(st.mode&0o777)!==f.mode)throw Error('Candidate production input hash/mode differs from Worktree');
  }
}
const kinds=new Set(['processStarted','accessibilityChecked','hotkeyRegistration','captureStarted','captureSucceeded','captureFailed',
  'staleCaptureDiscarded','sourceChanged','submissionRejected','lookupSubmitted','providerSucceeded','providerFailed',
  'lookupCancelled','lookupSuperseded','popupPresented','popupNotVisible','popupDismissed']);
const terminal=new Set(['captureFailed','submissionRejected','providerSucceeded','providerFailed','lookupCancelled','lookupSuperseded','sourceChanged']);
export function safeEvents(text) {
  // No raw record is printed/saved. Retain only fixed enum/numeric/UUID predicates.
  return text.split('\n').filter(Boolean).map(line=>{
    const e=JSON.parse(line);
    if(!kinds.has(e.kind))throw Error('Unknown diagnostic schema; inspect manually');
    return {kind:e.kind,attemptID:/^[0-9A-F-]{36}$/i.test(e.attemptID??'')?e.attemptID:null,
      sourcePID:Number.isInteger(e.sourcePID)?e.sourcePID:null,processID:e.processID,
      buildID:e.buildID,runID:e.runID,
      targetLength:Number.isInteger(e.targetLength)?e.targetLength:null,
      sentenceLength:Number.isInteger(e.sentenceLength)?e.sentenceLength:null,
      strategy:['axRange','axTreeWalk','axSelectionOnly','clipboardOnly','safariDOM'].includes(e.details?.strategy)?e.details.strategy:null,
      reliability:['anchored','heuristic','targetOnly','legacyUnverified'].includes(e.details?.reliability)?e.details.reliability:null};
  });
}
export function assertIdle(events) {
  const active=new Set();
  for(const e of events) {
    if(e.attemptID&&['captureStarted','lookupSubmitted'].includes(e.kind))active.add(e.attemptID);
    if(terminal.has(e.kind))active.delete(e.attemptID);
  }
  if(active.size)throw Error('Unfinished native/HTTP intent; idle cannot be proven; no input sent');
}
export function ownAttempt(events,sourcePID,expected) {
  const starts=events.filter(e=>e.kind==='captureStarted');
  if(starts.length>1||starts.some(e=>e.sourcePID!==sourcePID)||(expected&&starts.some(e=>e.attemptID!==expected))) {
    throw Error('Concurrent/unrelated intent observed; stop without reading popup');
  }
  if(events.some(e=>e.attemptID&&starts[0]&&e.attemptID!==starts[0].attemptID))throw Error('Unrelated diagnostic activity; stop');
  return starts[0]?.attemptID;
}

export async function runNative({root,output,options,caseID},deps={}) {
  if(!options.allowGui||!options.allowModel)throw Error('Explicit GUI and model authorization required');
  if(!options.qaBuild)throw Error('Native smoke requires --qa-build; no App is launched automatically');
  const candidate=path.resolve(root,options.qaBuild),qaRoot=path.join(root,'build/qa.noindex');
  if(path.dirname(candidate)!==qaRoot||fs.realpathSync(candidate)!==candidate)throw Error('Use an existing nonsymlink build/qa.noindex/<build-id> directory');
  const call=deps.invoke??invoke,wait=deps.wait??(ms=>new Promise(resolve=>setTimeout(resolve,ms)));
  const inspect=()=>JSON.parse(call(process.execPath,['scripts/qa-app.mjs','inspect',candidate],root));
  const manifest=inspect();
  if(manifest.buildID!==path.basename(candidate)||manifest.identity.bundleID!=='com.liyunhui.DictionaryApp')throw Error('Unexpected QA build identity');
  assertProductionInputs(root,manifest,call);
  const runtime=deps.runtime??(()=>{
    const state={processes:parseProcesses(call('/bin/ps',['-ww','-axo','pid=,comm='],root)),
      listeners:parseListeners({status:0,stdout:call('/usr/sbin/lsof',['-nP','-iTCP:49152','-sTCP:LISTEN','-Fpn'],root),stderr:''})};
    const current=assertRuntime(manifest.identity,state);
    return {...state,processStart:call('/bin/ps',['-p',String(current),'-o','lstart='],root).trim()};
  });
  const first=runtime(),pid=assertRuntime(manifest.identity,first);
  if(typeof first.processStart!=='string'||!first.processStart.trim())throw Error('Process incarnation unavailable; no input sent');
  const runs=fs.readdirSync(path.join(candidate,'runs')).filter(name=>/^[\dTZA-Za-z-]+$/.test(name)).map(name=>path.join(candidate,'runs',name));
  const matched=runs.filter(dir=>{
    const file=path.join(dir,'runtime-verified.json');
    return fs.existsSync(file)&&JSON.parse(fs.readFileSync(file,'utf8')).pid===pid;
  });
  if(matched.length!==1)throw Error('No unique verified diagnostics run for current PID; no input sent');
  const run=matched[0],runID=path.basename(run),log=path.join(run,'events.jsonl');
  if(fs.realpathSync(log)!==log)throw Error('Diagnostic symlink refused');
  const logStat=fs.statSync(log);
  if((logStat.mode&0o777)!==0o600||logStat.uid!==process.getuid()||logStat.size>8*1024*1024)throw Error('Unsafe diagnostic ownership/mode/size');
  const read=()=>{
    const st=fs.statSync(log);
    if(st.ino!==logStat.ino||st.size<logStat.size||st.size>8*1024*1024)throw Error('Diagnostic file replaced/truncated/too large');
    const rows=safeEvents(fs.readFileSync(log,'utf8'));
    if(rows.some(e=>e.processID!==pid||e.buildID!==manifest.buildID||e.runID!==runID))throw Error('Diagnostic runtime identity mismatch');
    return rows;
  };
  const before=read();assertIdle(before);
  const binding=Object.freeze({buildID:manifest.buildID,pid,runID,processStart:first.processStart,...manifest.identity,sourceFingerprint:manifest.source.fingerprint});
  let invalid=false;
  const actions=[];
  const bindingError=()=>Object.assign(Error('Native runtime identity changed or unavailable; no further app operations; inspect/recover manually'),
    {nativeIdentity:binding,nativeActions:[...actions]});
  const verify=()=>{
    if(invalid)throw bindingError();
    try {
      const current=inspect();assertIdentity(manifest.identity,current.identity);
      if(current.buildID!==binding.buildID||current.source.fingerprint!==binding.sourceFingerprint)throw Error('Build changed');
      const state=runtime();
      if(assertRuntime(binding,state)!==pid||state.processStart!==binding.processStart)throw Error('Process instance changed');
      const open=call('/usr/sbin/lsof',['-a','-p',String(pid),'-Fpn','--',log],root).split('\n');
      if(!open.includes('p'+pid)||!open.includes('n'+log))throw Error('Open log binding lost');
      read();
    } catch {invalid=true;throw bindingError();}
  };
  const fixture=path.join(candidate,'operator-fixtures/TextEdit-phase1a.txt');
  if(fs.realpathSync(fixture)!==fixture)throw Error('Fixture symlink refused');
  const base='The bank approved my loan. We sat on the bank of the river.';
  if(fs.readFileSync(fixture,'utf8')!==base+'\n')throw Error('Owned fixture differs; no open/write/input performed');
  const executable=path.join(output,'native-probe-'+caseID);
  call('/usr/bin/xcrun',['swiftc','-parse-as-library','Tests/E2E/native-smoke.swift','-module-cache-path',path.join(output,'swift-modules'),'-o',executable],root);
  const start=caseID==='first-bank'?4:41;
  const probe=(mode,...args)=>{
    verify(); // Every guard, input, observation and cleanup stays bound to this instance.
    actions.push({mode,pid,runID,operation:'attempted'});
    const result=JSON.parse(call(executable,[mode,fixture,String(pid),String(start),...args.map(String)],root));
    if(result.blocked)throw Error('Native guard: '+result.reason);return result;
  };
  const initial=probe('guard');
  let changed=false,triggered=false,intent;
  const after=()=>read().slice(before.length);
  try {
    if(after().some(e=>e.attemptID))throw Error('Concurrent activity before input; stop');
    changed=true;
    const selected=probe('select');
    if(after().some(e=>e.attemptID))throw Error('Concurrent activity before shortcut; stop');
    probe('trigger');triggered=true;
    const until=Date.now()+30000;
    let rows=[];
    while(Date.now()<until) {
      rows=after();intent=ownAttempt(rows,initial.TextEditPID,intent);
      if(intent&&rows.some(e=>e.attemptID===intent&&terminal.has(e.kind)))break;
      await wait(150);
    }
    if(!intent)throw Error('No owned capture attempt within 30 seconds; do not retry automatically');
    const done=rows.find(e=>e.attemptID===intent&&terminal.has(e.kind));
    if(!done)throw Error('No terminal event within 30 seconds; manual cleanup/inspection required');
    if(done.kind!=='providerSucceeded')return {status:'FAIL',reason:'Owned lookup terminal was '+done.kind,attemptID:intent,identity:binding,actions};
    // Give layout a bounded interval, checking interference before any popup observation.
    await wait(250);
    ownAttempt(after(),initial.TextEditPID,intent);
    const popup=probe('popup');
    const capture=rows.find(e=>e.kind==='captureSucceeded'&&e.attemptID===intent);
    const checks={sourceRange:selected.start===start&&selected.end===start+4,
      rawSourceUnchanged:selected.source_content_matches,
      exactCapture:capture?.strategy==='axRange'&&capture?.reliability==='anchored',
      targetLength:capture?.targetLength===4,
      correctSourceSentence:popup.sentence_matches&&popup.original_sentence_label,
      sentenceTranslationPresent:popup.sentence_translation_present};
    const captureStatus=Object.values(checks).every(value=>value===true)?'PASS':'FAIL';
    const meaningCheck=popup.meaningCheck?.observed===true&&popup.meaningCheck.field==='meaningInContext'&&['PASS','FAIL'].includes(popup.meaningCheck.status)?
      popup.meaningCheck:{status:'MANUAL_REQUIRED',observed:false};
    return {status:captureStatus==='FAIL'||meaningCheck.status==='FAIL'?'FAIL':meaningCheck.status,checks,captureStatus,meaningCheck,attemptID:intent,
      identity:binding,actions,
      sourceRange:{start,end:start+4},automaticInputNotPhysical:true,
      limitations:['Live private provider document/range not intercepted','Contextual meaning requires an identified field; whole-popup keywords are not evidence','No full translation-quality or same-sentence IQA-M1 acceptance'],
      modelEvidence:'Live Model (indirect configured provider lookup; no independent semantic scorer)'};
  } finally {
    if(changed) {
      // Never close someone else's result or overwrite their new selection.
      verify();ownAttempt(after(),initial.TextEditPID,intent);
      try {
        if(triggered) {
          const rows=after();
          if(!rows.some(e=>terminal.has(e.kind)&&e.attemptID===intent))throw Error('Owned lookup still active; leave untouched, operator cleanup required');
          probe('dismiss');
        }
      } finally {
        const restored=probe('restore',initial.start,initial.end);
        if(restored.start!==initial.start||restored.end!==initial.end)throw Error('Original owned selection not restored; manual inspection required');
      }
      await wait(150);
      probe('guard'); // Confirms the owned source/focus and absence of a leftover popup.
    }
  }
}
