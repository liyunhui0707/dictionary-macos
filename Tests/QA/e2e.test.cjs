const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const api = import('../../scripts/e2e.mjs');
const root = path.resolve(__dirname, '../..');
const cli = (...args) => spawnSync(process.execPath, ['scripts/e2e.mjs', ...args], {cwd:root, encoding:'utf8'});

test('default entry is read-only discovery; never starts a test', () => {
  const result = cli();
  assert.equal(result.status, 0, result.stderr);
  const value = JSON.parse(result.stdout);
  assert.equal(value.command, 'list');
  assert(value.suites.some(s => s.id === 'native'));
  assert(value.suites.some(s => s.id === 'model-live'));
  assert.equal(value.executed, false);
});

test('changed discovery includes staged, unstaged, deleted and untracked paths with spaces', async () => {
  const {discoverChanges} = await api;
  const responses = ['Sources/A.swift\0', 'Sources/Deleted.swift\0', 'Tests/New test.swift\0'];
  const calls = [];
  const paths = discoverChanges(root, (_cmd, args) => {calls.push(args); return responses.shift();});
  assert.deepEqual(paths, ['Sources/A.swift', 'Sources/Deleted.swift', 'Tests/New test.swift']);
  assert(calls.some(args => args.includes('--cached')));
  assert(calls.some(args => args.includes('--others')));
});

test('docs-only plan has no E2E or model recommendation; mixed changes retain impact', async () => {
  const {plan} = await api;
  assert.deepEqual(plan(['README.md', 'docs/new.md']).recommended, []);
  const mixed = plan(['README.md', 'Sources/DictionaryApp/Prompt/PromptBuilder.swift']);
  assert(mixed.recommended.some(s => s.suite === 'swift-request' && s.level === 'L1'));
  assert(mixed.recommended.some(s => s.suite === 'model-live' && s.level === 'L3'));
  assert.equal(mixed.executed, false);
});

test('unknown and cross-module changes broaden recommendations without executing acceptance', async () => {
  const {plan} = await api;
  const result = plan(['extensions/obsidian/main.js', 'Sources/DictionaryApp/Capture/SafariContextExtractor.swift', 'new-config.xyz']);
  for (const suite of ['obsidian-unit','obsidian-editor-live','obsidian-reading-live','safari-live','swift-capture']) {
    assert(result.recommended.some(s => s.suite === suite), suite);
  }
  assert(result.warnings.length > 0);
  assert(!result.recommended.some(s => s.level === 'L4'));
  assert.equal(result.executed, false);
});

test('run requires an explicit known suite/case; no implicit full run or shell command option', () => {
  for (const args of [['run'], ['run','--suite','unknown'], ['run','--suite','infra','--case','unknown'], ['run','--command','echo'],
    ['run','--suite','infra','--qa-build','not-used']]) {
    assert.notEqual(cli(...args).status, 0);
  }
});

// Review regressions. Native entry tests below forbid all real subprocesses.
async function history(options={}) {
  const {execute}=await api;
  const inputs={files:[{path:'Tests/Extensions/selection-capture.test.cjs',sha256:'unchanged',mode:420}],fingerprint:'unchanged'};
  const report=await execute(root,{suites:['chromium-unit'],...options},{
    output:fs.mkdtempSync(path.join(os.tmpdir(),'dictionary-history-')),
    fingerprint:()=>inputs,metadata:()=>({changed:[]}),
    command:async()=>({exitCode:0,counts:{PASS:1,FAIL:0,SKIP:0}})
  });
  return {report,inputs};
}

test('R1 relevant infra history must retain runner even after a complete unchanged PASS',async()=>{
  const {planSinceRun}=await api;
  const {report,inputs}=await history({suites:['infra']});
  assert.equal(report.results.find(r=>r.selected).status,'PASS');
  const p=planSinceRun(root,report,['scripts/e2e.mjs'],inputs);
  const runner=p.recommended.find(s=>s.suite==='infra')?.cases.find(c=>c.id==='runner');
  assert(runner,'compiler-dependent infra/runner must remain recommended');
  assert.match(runner.reason,/Swift|SDK/);
  assert(!p.coverage.reused.some(r=>r.suite==='infra'&&r.case==='runner'));
});

test('R1 changed SDKROOT cannot reuse infra PASS under an unchanged Node context',async()=>{
  const {planSinceRun}=await api;
  const {report,inputs}=await history({suites:['infra']});
  const hadSDK=Object.hasOwn(process.env,'SDKROOT'),previous=process.env.SDKROOT;
  try {
    // Process-local planning control only: no compiler/GUI is invoked under this value.
    process.env.SDKROOT='/private/tmp/dictionary-e2e-unit-unavailable-sdk';
    const p=planSinceRun(root,report,['scripts/e2e.mjs'],inputs);
    assert(p.recommended.some(s=>s.suite==='infra'&&s.cases.some(c=>c.id==='runner')));
    assert(!p.coverage.reused.some(r=>r.suite==='infra'));
  } finally {if(hadSDK)process.env.SDKROOT=previous;else delete process.env.SDKROOT;}
});

test('R1 pure Node reuse, changed impact scope and explicit run selection stay narrow',async()=>{
  const {planSinceRun,plan,discoverChanges}=await api;
  const {report,inputs}=await history();
  const p=planSinceRun(root,report,[],inputs);
  assert.deepEqual(p.coverage.reused.map(r=>[r.suite,r.case]),[['chromium-unit','sender']]);
  assert.deepEqual(p.recommended,[]);
  const changes=['Tests/Extensions/cancellation.test.cjs\0','',''];
  const normal=plan(discoverChanges(root,()=>changes.shift()));
  assert.deepEqual(normal.recommended.map(r=>r.suite),['client-lifecycle']);
  assert.equal(normal.executed,false);
  assert.deepEqual(plan(['README.md']).recommended,[]);
  assert.deepEqual(report.results.filter(r=>r.selected).map(r=>[r.suite,r.case]),[['chromium-unit','sender']]);
  assert(report.results.filter(r=>r.suite==='infra').every(r=>r.status==='NOT_RUN'));
});

test('H1 since-run retains dry, failed, blocked, unrun, manual, missing and interrupted obligations',async()=>{
  const {planSinceRun}=await api;
  const {report,inputs}=await history();
  for(const mutate of [r=>{r.dryRun=true;},r=>{r.completed=false;},r=>{r.inputsUnchanged=false;},
    r=>{r.results=[];},r=>{r.results=null;},r=>{r.results={};},r=>{delete r.executionContext;},r=>{r.schemaVersion=1;},
    r=>{delete r.finishedAt;},r=>{delete r.request.cases;},r=>{delete r.request.match;},
    r=>{r.results.find(x=>x.selected).finishedAt='2099-01-01T00:00:00Z';},
    ...['FAIL','BLOCKED','NOT_RUN','MANUAL_REQUIRED'].map(status=>r=>{r.results.find(x=>x.selected).status=status;})]) {
    const prior=structuredClone(report);mutate(prior);
    const p=planSinceRun(root,prior,[],inputs);
    assert(p.recommended.some(s=>s.suite==='chromium-unit'),JSON.stringify(prior.results));
    assert.equal(p.coverage.reused.length,0);
    assert(p.warnings.length>0);
  }
});

test('H1 unchanged complete unfiltered deterministic PASS covers only that registered case',async()=>{
  const {planSinceRun}=await api;
  const {report,inputs}=await history();
  const p=planSinceRun(root,report,[],inputs);
  assert.deepEqual(p.recommended,[]);
  assert.deepEqual(p.coverage.reused.map(r=>[r.suite,r.case]),[['chromium-unit','sender']]);
  const filtered=await history({match:'one method'});
  assert(planSinceRun(root,filtered.report,[],filtered.inputs).recommended.some(s=>s.suite==='chromium-unit'));
  const partial=await history({suites:['swift-capture'],cases:['ranges']});
  const remainder=planSinceRun(root,partial.report,[],partial.inputs).recommended.find(s=>s.suite==='swift-capture');
  assert(remainder.cases.some(c=>c.id==='ax-tree'));
  assert(remainder.cases.some(c=>c.id==='controller'));
});

test('H1 changed inputs, command, scope, engine and live identity cannot reuse a PASS',async()=>{
  const {planSinceRun}=await api;
  const {report,inputs}=await history();
  for(const mutate of [r=>{r.results.find(x=>x.selected).command.args.push('--different');},
    r=>{r.results.find(x=>x.selected).tests.SKIP=1;},r=>{r.request.match='filtered';},
    r=>{r.executionContext={node:'other'};}]) {
    const prior=structuredClone(report);mutate(prior);
    assert.equal(planSinceRun(root,prior,[],inputs).coverage.reused.length,0);
  }
  for(const file of ['Sources/DictionaryApp/Capture/SelectionLocation.swift','Tests/QA/fixture.json','scripts/e2e/registry.mjs','Package.swift']) {
    const changed={files:[...inputs.files,{path:file,sha256:'new'}],fingerprint:'different'};
    assert.equal(planSinceRun(root,report,[file],changed).coverage.reused.length,0,file);
  }
  const live=await history({suites:['native'],cases:['first-bank'],dryRun:true});
  live.report.dryRun=false;live.report.results.find(r=>r.selected).status='PASS';
  assert.equal(planSinceRun(root,live.report,[],live.inputs).coverage.reused.length,0);
});

test('H1 actual plan CLI preserves dry/failing/partial histories and reuses only a complete PASS case',async()=>{
  const {execute}=await api;
  const temp=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'dictionary-plan-cli-')));
  fs.mkdirSync(path.join(temp,'scripts/e2e'),{recursive:true});
  for(const file of ['scripts/e2e.mjs','scripts/e2e/registry.mjs'])fs.copyFileSync(path.join(root,file),path.join(temp,file));
  fs.writeFileSync(path.join(temp,'.gitignore'),'build/\n'); // Match the real project's ignored run artifacts.
  assert.equal(spawnSync('/usr/bin/git',['init','--quiet'],{cwd:temp}).status,0);
  for(const kind of ['dry','FAIL','BLOCKED','NOT_RUN','MANUAL_REQUIRED','filtered','missing','interrupted','legacy','PASS']) {
    const report=await execute(temp,{suites:['chromium-unit'],...(kind==='dry'?{dryRun:true}:{})},{metadata:()=>({changed:[]}),
      command:async()=>({exitCode:0,counts:{PASS:1,FAIL:0,SKIP:0}})});
    const selected=report.results.find(r=>r.selected);
    if(['FAIL','BLOCKED','NOT_RUN','MANUAL_REQUIRED'].includes(kind))selected.status=kind;
    if(kind==='filtered')report.request.match='one test';
    if(kind==='missing')report.results=[];
    if(kind==='interrupted')report.completed=false;
    if(kind==='legacy')report.schemaVersion=1;
    fs.writeFileSync(path.join(temp,report.output,'report.json'),JSON.stringify(report));
    const result=spawnSync(process.execPath,['scripts/e2e.mjs','plan','--since-run',report.runID],{cwd:temp,encoding:'utf8'});
    assert.equal(result.status,0,result.stderr);
    const p=JSON.parse(result.stdout);
    assert.equal(p.recommended.some(s=>s.suite==='chromium-unit'),kind!=='PASS',kind);
    assert.equal(p.coverage.reused.some(r=>r.suite==='chromium-unit'),kind==='PASS',kind);
    if(kind!=='PASS')assert(p.warnings.length>0);
  }
});

test('M1 empty explicit selectors are rejected before output or execution; valid lists stay narrow',async()=>{
  const {parseOptions,select}=await api;
  for(const value of ['',',',' ', ',,','runner,',' , runner','runner,,guards','runner, ,guards']) {
    assert.throws(()=>select(parseOptions(['--suite','infra','--case',value])),/case|value|selector/i,value);
  }
  assert.throws(()=>select(parseOptions(['--suite','infra','--case','runner','--case',','])),/case|selector/i);
  assert.throws(()=>select(parseOptions(['--suite',','])),/suite|selector/i);
  assert.throws(()=>select(parseOptions(['--suite','infra','--case','unknown'])),/Unknown case/i);
  const a=parseOptions(['--suite','infra,qa-build','--case','runner,guards']);
  assert.deepEqual(a.cases,['runner','guards']);assert.equal(select(a).length,2);
  const b=parseOptions(['--suite','infra','--case','runner','--case','runner']);
  assert.deepEqual(b.cases,['runner']);assert.equal(select(b).length,1);
  // Bypass the parser: the executor must still reject an explicit empty selector.
  let launched=false;
  await assert.rejects(()=>api.then(({execute})=>execute(root,{suites:['infra'],cases:[]},{command:()=>{launched=true;}})),/case|selector/i);
  assert.equal(launched,false);
});

test('M2 dependency map includes direct cross-adapter, shared model/coordinator and build consumers',async()=>{
  const {plan}=await api;
  for(const [file,ids] of [
    ['extensions/chromium/content.js',['chromium-unit','obsidian-unit','dom-engine','safari-engine','chromium-loaded']],
    ['Sources/DictionaryApp/Capture/SelectionLocation.swift',['swift-capture','swift-request','swift-lifecycle','dom-engine','safari-engine','ui-simulated','model-live']],
    ['Sources/DictionaryApp/Lookup/LookupCoordinator.swift',['swift-lifecycle','swift-request','swift-http','ui-simulated','native','http-live']],
    ['Sources/DictionaryApp/Prompt/PromptBuilder.swift',['swift-request','safari-engine','model-live']],
    ['Sources/DictionaryApp/Server/TranslateRequest.swift',['swift-request','swift-http','chromium-unit','obsidian-unit','http-live']],
    ['Tests/DictionaryAppTests/ControlledProvider.swift',['swift-request','swift-lifecycle','swift-http','safari-engine','ui-simulated']],
    ['Tests/E2E/native-smoke.swift',['infra','native']],
    ['Tests/Fixtures/selection.json',['dom-engine','safari-engine','obsidian-unit']],
    ['Package.swift',['qa-build','dom-engine','safari-engine','swift-request']],
    ['unknown-build.config',['dom-engine','safari-engine']]
  ]) {
    const p=plan([file]);
    for(const id of ids){const hit=p.recommended.find(s=>s.suite===id);assert(hit,`${file} -> ${id}`);assert(hit.reasons.some(r=>r.includes(file)));}
    assert.equal(p.executed,false);assert(!p.recommended.some(s=>s.level==='L4'));
  }
  assert.deepEqual(plan(['docs/new.md']).recommended,[]);
  assert(!plan(['Tests/Extensions/cancellation.test.cjs']).recommended.some(s=>s.suite==='safari-engine'));
});

async function nativeFixture({changeAfter,mutate,popup={}}={}) {
  const cp=require('node:child_process'),{syncBuiltinESMExports}=require('node:module');
  const project=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'dictionary-native-double-')));
  const candidate=path.join(project,'build/qa.noindex/test-build'),runID='test-run',run=path.join(candidate,'runs',runID);
  fs.mkdirSync(run,{recursive:true});fs.mkdirSync(path.join(candidate,'operator-fixtures'));
  const fixture=path.join(candidate,'operator-fixtures/TextEdit-phase1a.txt');
  fs.writeFileSync(fixture,'The bank approved my loan. We sat on the bank of the river.\n');
  const manifest={buildID:'test-build',source:{files:[],fingerprint:'test-source'},identity:{
    executable:path.join(candidate,'Dictionary.app/Contents/MacOS/DictionaryApp'),bundleID:'com.liyunhui.DictionaryApp',
    uuid:'test-uuid',signature:'test-signature',sha256:'test-sha'}};
  const state={pid:101,listeners:[101],processStart:'Mon Oct 26 01:00:00 2026',logOpen:true,identity:structuredClone(manifest.identity)};
  fs.writeFileSync(path.join(run,'runtime-verified.json'),JSON.stringify({pid:101}));
  const log=path.join(run,'events.jsonl');
  const event=(kind,more={})=>({kind,processID:101,buildID:'test-build',runID,...more});
  fs.writeFileSync(log,JSON.stringify(event('processStarted'))+'\n',{mode:0o600});
  const actions=[],snapshot=()=>{
    if(state.failOnce){state.failOnce=false;throw Error('Controlled one-shot inspection failure');}
    if(state.unavailable)throw Error('Controlled runtime unavailable');
    return {processes:[{pid:state.pid,executable:state.identity.executable}],listeners:state.listeners,processStart:state.processStart};
  };
  const call=(program,args)=>{
    if(program===process.execPath){
      if(state.inspectUnavailable)throw Error('Controlled signature inspection failure');
      return JSON.stringify({...manifest,identity:state.identity}); // fake qa-app inspect
    }
    if(program==='/usr/bin/git')return '';
    if(program==='/bin/ps')return args.includes('-axo')?`${state.pid} ${state.identity.executable}\n`:state.processStart+'\n';
    if(program==='/usr/sbin/lsof') {
      if(args.includes('-iTCP:49152'))return `p${state.listeners[0]}\nn127.0.0.1:49152\n`;
      if(!state.logOpen)throw Error('Controlled log binding lost');
      return `p${state.pid}\nn${log}\n`;
    }
    if(program==='/usr/bin/xcrun')return ''; // compile double; never executes a compiler/probe
    if(program.includes('native-probe-')) {
      const mode=args[0];actions.push({mode,pid:Number(args[2]),currentPID:state.pid});
      const result=mode==='popup'?{sentence_matches:true,original_sentence_label:true,sentence_translation_present:true,
        expected_meaning_present:true,meaningCheck:{status:'PASS',observed:true,field:'meaningInContext'},...popup}:
        {TextEditPID:303,start:['guard','restore'].includes(mode)?0:41,end:['guard','restore'].includes(mode)?0:45,source_content_matches:true};
      if(mode==='trigger')for(const kind of ['captureStarted','captureSucceeded','providerSucceeded'])fs.appendFileSync(log,
        JSON.stringify(event(kind,{attemptID:'11111111-1111-1111-1111-111111111111',sourcePID:303,targetLength:4,
          details:{strategy:'axRange',reliability:'anchored'}}))+'\n');
      if(mode===changeAfter)mutate(state);
      return JSON.stringify(result);
    }
    throw Error('Unexpected subprocess in controlled Native fixture');
  };
  const original=cp.spawnSync;
  // Also intercept legacy direct subprocess calls, so RED can exercise old code safely.
  cp.spawnSync=(program,args)=>{try{return {status:0,stdout:call(program,args),stderr:''};}catch{return {status:1,stdout:'',stderr:''};}};
  syncBuiltinESMExports();
  try {
    const {runNative}=await import('../../scripts/e2e/native.mjs');
    const result=await runNative({root:project,output:project,options:{allowGui:true,allowModel:true,qaBuild:candidate},caseID:'second-bank'},
      {invoke:call,runtime:snapshot,wait:async()=>{}});
    return {result,actions};
  } catch(error){return {error,actions};}
  finally {cp.spawnSync=original;syncBuiltinESMExports();}
}

test('H2 production Native entry stops on PID replacement at every operation boundary',async()=>{
  for(const [after,forbidden] of [['guard','select'],['select','trigger'],['trigger','popup'],['popup','dismiss'],['dismiss','restore'],['restore','guard']]) {
    const {error,actions}=await nativeFixture({changeAfter:after,mutate:s=>{s.pid=202;s.listeners=[202];}});
    assert(error,after+' must stop');
    const index=actions.findIndex(a=>a.mode===after);
    assert(!actions.slice(index+1).some(a=>a.mode===forbidden),JSON.stringify(actions));
    assert(actions.every(a=>a.pid===101&&a.currentPID===101),JSON.stringify(actions));
  }
});

test('H2 PID reuse, binary identity, port, log and inspection failures stop before shortcut',async()=>{
  for(const mutate of [s=>{s.processStart='Mon Oct 26 02:00:00 2026';},s=>{s.listeners=[999];},
    s=>{s.identity.uuid='replacement';},s=>{s.identity.signature='replacement';},s=>{s.identity.bundleID='replacement';},
    s=>{s.identity.sha256='replacement';},s=>{s.identity.executable='/other/DictionaryApp';},
    s=>{s.logOpen=false;},s=>{s.unavailable=true;},s=>{s.inspectUnavailable=true;},s=>{s.failOnce=true;}]) {
    const {error,actions}=await nativeFixture({changeAfter:'select',mutate});
    assert(error);assert(!actions.some(a=>a.mode==='trigger'),JSON.stringify(actions));
    assert(!actions.some(a=>a.mode==='restore'),'identity uncertainty must not perform cleanup in another app');
  }
});

test('H2 stable production Native entry records one process/run binding through cleanup',async()=>{
  const {result,error,actions}=await nativeFixture();assert.ifError(error);
  assert.equal(result.status,'PASS');assert.equal(result.identity.pid,101);
  assert.equal(result.identity.runID,'test-run');
  assert.equal(result.identity.processStart,'Mon Oct 26 01:00:00 2026');
  assert.deepEqual(actions.map(a=>a.mode),['guard','select','trigger','popup','dismiss','restore','guard']);
});

test('M3 wrong contextual meaning cannot pass on right sentence/alternative keywords; unknown field is manual',async()=>{
  const bad=await nativeFixture({popup:{expected_meaning_present:true,meaningCheck:{status:'FAIL',observed:true,field:'meaningInContext'}}});
  assert.ifError(bad.error);assert.equal(bad.result.status,'FAIL');
  const missing=await nativeFixture({popup:{expected_meaning_present:true,meaningCheck:{status:'MANUAL_REQUIRED',observed:false}}});
  assert.ifError(missing.error);assert.equal(missing.result.status,'MANUAL_REQUIRED');
  assert.equal(missing.result.captureStatus,'PASS');
  for(const field of ['sentenceTranslation','literalGloss','alternatives',null]) {
    const other=await nativeFixture({popup:{meaningCheck:{status:'PASS',observed:true,field}}});
    assert.ifError(other.error);assert.equal(other.result.status,'MANUAL_REQUIRED');
  }
});

test('M3 actual Swift meaning predicate uses only an identified field, never other popup labels',async()=>{
  const text=fs.readFileSync(path.join(root,'Tests/E2E/native-smoke.swift'),'utf8');
  const scoped=text.match(/\/\/ BEGIN CONTEXTUAL MEANING\n([\s\S]*?)\/\/ END CONTEXTUAL MEANING/);
  const legacy=text.match(/"expected_meaning_present":(labels\.contains \{[^\n]+\}),/);
  assert(scoped||legacy,'production oracle must be exercised');
  const oracle=scoped?scoped[1]:`func assessContextualMeaning(fieldValue:String?,start:Int)->[String:Any] { let labels=testLabels; return ["status":(${legacy[1]}) ? "PASS":"FAIL"] }`;
  const scratch=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'dictionary-meaning-unit-')));
  const modules=path.join(root,'build/e2e/cache/native-unit-modules');
  (await api).safeDirectory(modules);
  const file=path.join(scratch,'meaning.swift'),binary=path.join(scratch,'meaning');
  fs.writeFileSync(file,'import Foundation\nlet testLabels=["银行", "Sentence translation", "我们坐在河岸上。", "Literal", "河岸", "Alternatives", "河边"]\n'+oracle+`
    let results=[assessContextualMeaning(fieldValue:"银行",start:41),assessContextualMeaning(fieldValue:nil,start:41),
      assessContextualMeaning(fieldValue:"河岸",start:41),assessContextualMeaning(fieldValue:"银行",start:4)]
    print(String(decoding:try! JSONSerialization.data(withJSONObject:results),as:UTF8.self))\n`);
  const compiled=spawnSync('/usr/bin/xcrun',['swiftc',file,'-module-cache-path',modules,'-o',binary],{encoding:'utf8'});
  assert.equal(compiled.status,0,compiled.stderr);
  const ran=spawnSync(binary,[],{encoding:'utf8'});assert.equal(ran.status,0,ran.stderr);
  assert.deepEqual(JSON.parse(ran.stdout).map(r=>r.status),['FAIL','MANUAL_REQUIRED','PASS','PASS']);
});

test('GUI, indirect model and full runs have separate fail-closed gates', async () => {
  const {gates} = await api;
  assert(gates('native', {}).includes('--allow-gui'));
  assert(gates('native', {allowGui:true}).includes('--allow-model'));
  assert.deepEqual(gates('native', {allowGui:true,allowModel:true}), []);
  assert(gates('swift-full', {allowGui:true}).includes('--allow-full'));
  assert(gates('model-live', {}).includes('--allow-model'));
});

test('dry-run launches nothing and all cases remain NOT_RUN, including selected native case', async () => {
  const {execute} = await api;
  const out = fs.mkdtempSync(path.join(os.tmpdir(), 'dictionary-e2e-dry-'));
  let launches = 0;
  const result = await execute(root, {suites:['native'],cases:['first-bank'],dryRun:true}, {
    output:out, fingerprint:()=>({files:[],fingerprint:'test'}), metadata:()=>({head:'test'}),
    native:()=>{launches++; throw Error('must not run');}
  });
  assert.equal(launches, 0);
  assert(result.results.every(r => r.status === 'NOT_RUN'));
  const selected = result.results.find(r => r.suite === 'native' && r.case === 'first-bank');
  assert.equal(selected.selected, true);
  assert.deepEqual(selected.missingFlags, ['--allow-gui','--allow-model']);
});

test('missing authorization blocks only selected cases and does not call native adapter', async () => {
  const {execute} = await api;
  const out = fs.mkdtempSync(path.join(os.tmpdir(), 'dictionary-e2e-gates-'));
  const result = await execute(root, {suites:['native'],cases:['second-bank']}, {
    output:out, fingerprint:()=>({files:[],fingerprint:'test'}), metadata:()=>({}),
    native:()=>{throw Error('must not run');}
  });
  assert.equal(result.results.find(r => r.selected).status, 'BLOCKED');
  assert(result.results.filter(r => !r.selected).every(r => r.status === 'NOT_RUN'));
});

test('one suite and one case run; child test counts and failed exits survive into report', async () => {
  const {execute} = await api;
  const calls=[];
  const result = await execute(root, {suites:['chromium-unit'],cases:['sender']}, {
    output:fs.mkdtempSync(path.join(os.tmpdir(),'dictionary-e2e-child-')),
    fingerprint:()=>({files:[],fingerprint:'test'}), metadata:()=>({}),
    command:async command=>{calls.push(command); return {exitCode:1,counts:{PASS:2,FAIL:1,SKIP:0}};}
  });
  assert.equal(calls.length,1);
  assert(calls[0].args.includes('Tests/Extensions/selection-capture.test.cjs'));
  assert.equal(result.results.find(r=>r.selected).status,'FAIL');
  assert.equal(result.counts.FAIL,1);
  assert.equal(result.results.find(r=>r.selected).tests.PASS,2);
});

test('zero matched tests never count as PASS and unavailable routes are honest', async () => {
  const {testOutcome, execute} = await api;
  assert.equal(testOutcome({exitCode:0,counts:{PASS:0,FAIL:0,SKIP:0}}),'FAIL');
  assert.equal(testOutcome({exitCode:0,counts:{PASS:0,FAIL:0,SKIP:2}}),'BLOCKED');
  const result=await execute(root,{suites:['chromium-loaded']},{
    output:fs.mkdtempSync(path.join(os.tmpdir(),'dictionary-e2e-manual-')),
    fingerprint:()=>({files:[],fingerprint:'test'}),metadata:()=>({})
  });
  assert.equal(result.results.find(r=>r.selected).status,'BLOCKED'); // explicit GUI flag absent
  const manual=await execute(root,{suites:['chromium-loaded'],allowGui:true},{
    output:fs.mkdtempSync(path.join(os.tmpdir(),'dictionary-e2e-approved-manual-')),
    fingerprint:()=>({files:[],fingerprint:'test'}),metadata:()=>({})
  });
  assert.equal(manual.results.find(r=>r.selected).status,'MANUAL_REQUIRED');
});

test('test summary parsing preserves actual Node and Swift pass/fail/skip counts', async () => {
  const {parseCounts} = await api;
  assert.deepEqual(parseCounts('# tests 7\n# pass 5\n# fail 1\n# skipped 1\n','node'),{PASS:5,FAIL:1,SKIP:1});
  assert.deepEqual(parseCounts('✔ Test run with 21 tests in 4 suites passed after 1.1 seconds.','swift'),{PASS:21,FAIL:0,SKIP:0});
  assert.equal(parseCounts('Build complete!','swift'),null);
});

test('GUI serial lock never steals an existing lock; own release is idempotent', async () => {
  const {acquireGuiLock} = await api;
  const folder=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'dictionary-e2e-lock-')));
  const release=acquireGuiLock(folder,'one');
  assert.throws(()=>acquireGuiLock(folder,'two'),/lock/i);
  release(); release();
  acquireGuiLock(folder,'three')();
});

test('evidence fingerprint includes untracked code; protected content and symlinks cannot be read', async () => {
  const {fingerprint} = await api;
  const folder=fs.mkdtempSync(path.join(os.tmpdir(),'dictionary-e2e-input-'));
  fs.mkdirSync(path.join(folder,'Sources'));
  fs.writeFileSync(path.join(folder,'Sources/New.swift'),'one');
  const before=fingerprint(folder,['Sources/New.swift','.env','secrets/private']);
  assert.equal(before.files.length,1);
  fs.writeFileSync(path.join(folder,'Sources/New.swift'),'two');
  assert.notEqual(fingerprint(folder,['Sources/New.swift']).fingerprint,before.fingerprint);
  fs.symlinkSync('/etc/hosts',path.join(folder,'Sources/linked.swift'));
  assert.throws(()=>fingerprint(folder,['Sources/linked.swift']),/symlink/i);
});

test('native identity requires current unique PID and sole port owner, never historical PID', async () => {
  const {assertRuntime} = await import('../../scripts/e2e/native.mjs');
  const expected={executable:'/verified/DictionaryApp'};
  assert.equal(assertRuntime(expected,{processes:[{pid:91,executable:expected.executable}],listeners:[91]}),91);
  for(const state of [
    {processes:[{pid:91,executable:expected.executable}],listeners:[82829]},
    {processes:[{pid:91,executable:'/old/DictionaryApp'}],listeners:[91]},
    {processes:[{pid:91,executable:expected.executable},{pid:92,executable:'/other/DictionaryApp'}],listeners:[91]}
  ]) assert.throws(()=>assertRuntime(expected,state),/identity|owner/i);
});

test('historical model failure stays historical and cannot become a current PASS', () => {
  const result=cli('list');
  assert.equal(result.status,0,result.stderr);
  const model=JSON.parse(result.stdout).suites.find(s=>s.id==='model-live');
  assert.equal(model.historical.status,'FAIL');
  assert.equal(model.historical.date,'2026-10-25');
  assert.equal(model.historical.mandatory,'6/12');
  assert(model.cases.every(c=>c.status==='NOT_RUN'));
});

test('report accepts only owned run IDs, and options cannot write elsewhere', () => {
  assert.notEqual(cli('report','../../README.md').status,0);
  assert.notEqual(cli('run','--suite','infra','--output','/tmp/other').status,0);
});

test('explicit goals recommend only; L1 definitions cannot invoke a real GUI/model adapter', async () => {
  const {plan}=await api;
  const {suites}=await import('../../scripts/e2e/registry.mjs');
  const result=plan(['docs/a.md'],['unicode']);
  assert(result.recommended.some(s=>s.suite==='native'));
  assert.equal(result.executed,false);
  for(const s of suites.filter(s=>s.level==='L1')) {
    assert(!s.gui&&!s.model);
    assert(['node','swift'].includes(s.adapter));
    assert(s.cases.every(c=>!['DOMSelectionTests','SafariSelectionTests','EditorLayoutTests','PopupDismissalTests'].includes(c.filter)));
  }
});

test('diagnostic projection drops source/model/credential-like fields and rejects unknown event kinds', async () => {
  const {safeEvents}=await import('../../scripts/e2e/native.mjs');
  const rows=safeEvents(JSON.stringify({kind:'captureSucceeded',attemptID:'BAD',raw:'PRIVATE_SENTINEL',
    details:{strategy:'axRange',reliability:'anchored',context:'PRIVATE_SENTINEL'},token:'PRIVATE_SENTINEL'}));
  assert(!JSON.stringify(rows).includes('PRIVATE_SENTINEL'));
  assert.equal(rows[0].strategy,'axRange');
  assert.equal(rows[0].attemptID,null);
  assert.throws(()=>safeEvents('{"kind":"unknown"}'),/schema/);
});

test('native activity is correlated; concurrency and unfinished attempts block observation', async () => {
  const {ownAttempt,assertIdle}=await import('../../scripts/e2e/native.mjs');
  const started={kind:'captureStarted',sourcePID:10,attemptID:'one'};
  assert.throws(()=>assertIdle([started]),/idle/);
  assert.doesNotThrow(()=>assertIdle([started,{kind:'providerSucceeded',attemptID:'one'}]));
  assert.equal(ownAttempt([started],10),'one');
  assert.throws(()=>ownAttempt([started,{...started,sourcePID:20,attemptID:'two'}],10),/Concurrent/);
  assert.throws(()=>ownAttempt([started],10,'previous'),/Concurrent/);
});

test('test commands force parseable Node output and keep method filtering inside chosen Swift suite', async () => {
  const {commandFor}=await api;
  const {suites}=await import('../../scripts/e2e/registry.mjs');
  const node=suites.find(s=>s.id==='infra'),swift=suites.find(s=>s.id==='swift-capture');
  assert(commandFor(node,node.cases[0],{},root,'unused').args.includes('--test-reporter=tap'));
  const command=commandFor(swift,swift.cases[0],{match:'exactUTF16'},root,'unused');
  assert.equal(command.args.at(-1),'SelectionLocationTests/.*exactUTF16');
});

test('input changes during execution invalidate PASS without erasing child counts', async () => {
  const {execute}=await api; let n=0;
  const report=await execute(root,{suites:['chromium-unit'],cases:['sender']},{
    output:fs.mkdtempSync(path.join(os.tmpdir(),'dictionary-e2e-mutate-')),
    fingerprint:()=>({files:[],fingerprint:String(n++)}),metadata:()=>({}),
    command:async()=>({exitCode:0,counts:{PASS:1,FAIL:0,SKIP:0}})
  });
  assert.equal(report.inputsUnchanged,false);
  assert.equal(report.results.find(r=>r.selected).status,'BLOCKED');
  assert.equal(report.results.find(r=>r.selected).tests.PASS,1);
});

test('symlink output directories cannot redirect artifacts outside the owned location', async () => {
  const {safeDirectory}=await api;
  const folder=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'dictionary-e2e-path-')));
  fs.mkdirSync(path.join(folder,'elsewhere'));
  fs.symlinkSync(path.join(folder,'elsewhere'),path.join(folder,'redirect'));
  assert.throws(()=>safeDirectory(path.join(folder,'redirect','logs')),/Symlink/);
  assert(!fs.existsSync(path.join(folder,'elsewhere','logs')));
});

test('since-run comparison detects new untracked, deleted and changed modes without repeating unchanged inputs', async () => {
  const {changesSince}=await api;
  const one={path:'Sources/one.swift',sha256:'same',mode:420};
  assert.deepEqual(changesSince({files:[one]},{files:[one]}),[]);
  assert.deepEqual(changesSince({files:[one,{path:'Tests/old.swift',sha256:'x'}]},
    {files:[{...one,mode:493},{path:'Tests/new.swift',sha256:'new'}]}),['Sources/one.swift','Tests/new.swift','Tests/old.swift']);
});

test('a native guard/cleanup failure stops subsequent GUI cases before any further input', async () => {
  const {execute}=await api;let calls=0;
  const report=await execute(root,{suites:['native'],allowGui:true,allowModel:true},{
    output:fs.mkdtempSync(path.join(os.tmpdir(),'dictionary-e2e-stop-')),
    fingerprint:()=>({files:[],fingerprint:'test'}),metadata:()=>({}),
    native:async()=>{calls++;throw Error('manual cleanup required');}
  });
  assert.equal(calls,1);
  assert(report.results.filter(r=>r.selected).every(r=>r.status==='BLOCKED'));
  assert(report.results.find(r=>r.case==='second-bank').reason.includes('Earlier GUI'));
});
