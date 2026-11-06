// Dependency-free registry. Entries describe evidence, not claims of acceptance.
const unit = 'Unit / Helper';
const integration = 'Production-entry Integration';
const real = 'Real-App E2E with synthesized input';
const c = (id, filter, ac, evidence=integration) => ({id, filter, ac, evidence});
export const suites = [
  {id:'infra',level:'L1',adapter:'node',files:['Tests/QA/e2e.test.cjs'],
    description:'On-demand selection, reporting, identity and authorization guards',cases:[c('runner',null,[11,12],unit)]},
  {id:'qa-build',level:'L1',adapter:'node',files:['Tests/QA/qa-app.test.cjs','Tests/QA/build-app.test.cjs'],
    description:'Existing isolated QA packaging/identity safety tests; no App build or launch',cases:[c('guards',null,[11,12],unit)]},
  {id:'swift-capture',level:'L1',adapter:'swift',description:'Pure ranges and injected AX/pipeline tests; no source-app input',cases:[
    c('ranges','SelectionLocationTests',[1,2,4,5,7,8],unit),c('ax-tree','ContextSelectionTests',[6,7,11]),
    c('diagnostics','CaptureDiagnosticsTests',[4,6,7,11]),c('controller','SelectionCaptureTests',[6,7,10])]},
  {id:'swift-request',level:'L1',adapter:'swift',description:'Request/Prompt/handler seams, controlled providers; no live Ollama',cases:[
    c('request','LookupRequestTests',[1,2,4,5,8,9]),c('prompt','PromptBuilderTests',[2,8,9]),
    c('http-contract','TranslateHandlerTests',[8,9,10]),c('presentation','LookupResultPresentationTests',[5,8,10])]},
  {id:'swift-lifecycle',level:'L1',adapter:'swift',description:'Injected coordinator, clipboard and metadata tests; no physical keyboard',cases:[
    c('coordinator','LookupCoordinatorTests',[8,10]),c('clipboard','SelectionReaderTests',[9,10]),
    c('manual-state','ManualLookupStateTests',[9,10]),c('privacy','QADiagnosticsTests',[11])]},
  {id:'swift-http',level:'L1',adapter:'swift',description:'Parser and real test-process sockets on an OS-assigned ephemeral port; fake provider/token, never 49152',cases:[
    c('parser','HTTPParserTests',[9]),c('socket','HTTPServerConnectionTests',[9,10])]},
  {id:'chromium-unit',level:'L1',adapter:'node',files:['Tests/Extensions/selection-capture.test.cjs'],
    description:'Production sender in controlled Node harness; not a loaded extension',cases:[c('sender',null,[8,9,11])]},
  {id:'obsidian-unit',level:'L1',adapter:'node',files:['Tests/Extensions/obsidian-editor.test.cjs'],
    description:'Actual command with public Editor doubles; not installed CodeMirror',cases:[c('editor',null,[1,2,3,4,5,8,9,11])]},
  {id:'client-lifecycle',level:'L1',adapter:'node',files:['Tests/Extensions/cancellation.test.cjs'],
    description:'Both production senders with controlled transport',cases:[c('cancellation',null,[9,10])]},
  {id:'dom-engine',level:'L2',adapter:'swift',gui:true,description:'Production Chromium/Reading scripts in WKWebView; not loaded integrations',cases:[
    c('chromium-reading','DOMSelectionTests',[1,2,3,4,5,8,11])]},
  {id:'safari-engine',level:'L2',adapter:'swift',gui:true,description:'Production Safari injection/decoder in WKWebView; no Safari Apple Events',cases:[
    c('injection','SafariSelectionTests',[1,2,3,4,5,8,9,11])]},
  {id:'ui-simulated',level:'L2',adapter:'swift',gui:true,description:'Test-process AppKit windows/views with controlled provider; not packaged-App or physical acceptance',cases:[
    c('editor-layout','EditorLayoutTests',[9,10],'Simulated GUI'),c('popup','PopupDismissalTests',[10],'Simulated GUI')]},
  {id:'native',level:'L2',adapter:'native',gui:true,model:true,description:'Owned TextEdit AX → synthesized Option+D → running QA App → real provider → popup predicates',
    prerequisites:['Explicit --allow-gui AND --allow-model (lookup invokes the configured real provider)',
      '--qa-build <existing unique build directory>; no build/launch/quit is performed',
      'Owned operator-fixtures/TextEdit-phase1a.txt already open and frontmost; no Dictionary popup; idle test session',
      'Current AX/post-event access; no permission requests; keep hands off during the selected case'],cases:[
      c('first-bank',null,[1,7,8,12],real),c('second-bank',null,[1,7,8,12],real)]},
  {id:'chromium-loaded',level:'L2',adapter:'manual',gui:true,description:'Actual loaded extension → QA App; engine harness is insufficient',
    reason:'Dedicated-profile extension installation/reload and credential setup require separate approval; no automated adapter in MVP',
    cases:[c('installed-route',null,[1,2,3,4,5,8,9,10,11,12],real)]},
  {id:'obsidian-editor-live',level:'L2',adapter:'manual',gui:true,description:'Installed Source and Live Preview, independently',
    reason:'Isolated Vault/plugin/configuration approval and installed payload observation are required; no automatic installation',cases:[
      c('source',null,[1,2,4,5,8,9,10,11,12],real),c('live-preview',null,[1,2,3,4,5,8,9,10,11,12],real)]},
  {id:'obsidian-reading-live',level:'L2',adapter:'manual',gui:true,description:'Installed active-pane Reading Selection/Range',
    reason:'Same isolated Vault approval; installed theme/DOM/transport still needs observation',cases:[c('reading',null,[1,2,3,4,5,8,9,10,11,12],real)]},
  {id:'safari-live',level:'L2',adapter:'manual',gui:true,description:'Safari stable actual Apple Events/injection → QA App',
    reason:'Existing Automation/JavaScript settings and actual source selection require operator confirmation; no settings changed',cases:[c('apple-events',null,[1,2,3,4,5,8,9,10,11,12],real)]},
  {id:'http-live',level:'L2',adapter:'unavailable',model:true,description:'Authenticated packaged-App contract/lifecycle (requests may invoke real model)',
    reason:'Historical probe is run-specific; credential scope, idle gate and safe self-supersession need a separately approved reusable adapter',cases:[c('contract',null,[8,9,10,11,12],integration)]},
  {id:'model-live',level:'L3',adapter:'unavailable',model:true,description:'Fixed clean/decoy/SHE rubric; no retry-until-pass',
    reason:'IQA-M1 remains open. Live adapter deliberately deferred to the separately authorized semantic investigation; no Prompt/model changes',
    historical:{date:'2026-10-25',build:'2026-10-25T08-49-39-605Z-392ab3',status:'FAIL',mandatory:'6/12',format:'18/18',meanings:'12/18',
      evidence:'docs/qa/phase1a/integration-2026-10-25/automation/qa-summary.json'},cases:[c('fixed-rubric',null,[2,8,12],'Live Model')]},
  {id:'swift-full',level:'L4',adapter:'swift',gui:true,description:'Explicit full Swift regression, including WebKit engine tests; not full acceptance',cases:[c('all',null,[1,2,3,4,5,6,7,8,9,10,11,12])]},
  {id:'acceptance',level:'L4',adapter:'manual',gui:true,model:true,description:'Q01–Q07 physical/installed/model acceptance; never automatically expands',
    reason:'Requires owner-requested full acceptance, approved integrations, physical checklist and independent semantic review',
    cases:[c('Q01-Q07',null,[1,2,3,4,5,6,7,8,9,10,11,12],'Real-App E2E with physical input')]}
];

// Shared dependency groups, used as recommendations only. Swift suites share one
// compiled test target; core capture/request/HTTP contracts also cross adapters.
const swift=['swift-capture','swift-request','swift-lifecycle','swift-http','dom-engine','safari-engine','ui-simulated'];
const clients=['chromium-unit','obsidian-unit','client-lifecycle'];
const live=['native','chromium-loaded','obsidian-editor-live','obsidian-reading-live','safari-live','http-live'];
const rules=[
  {pattern:/^(scripts\/e2e(?:\.mjs|\/)|Tests\/QA\/e2e\.test\.cjs)/,suites:['infra','qa-build'],why:'executor and QA adapter tests'},
  {pattern:/^(scripts\/e2e\/native\.mjs|Tests\/E2E\/)/,suites:['infra','native'],why:'native probe/adapter consumer'},
  {pattern:/^(scripts\/(qa-app\.mjs|build-app\.sh)|Tests\/QA\/(qa-app|build-app)\.test\.cjs)/,suites:['infra','qa-build','native'],why:'QA identity/build dependency'},
  {pattern:/^extensions\/chromium\//,suites:['chromium-unit','client-lifecycle','dom-engine','chromium-loaded'],why:'Chromium capture/transport'},
  {pattern:/^extensions\/chromium\/content\.js$/,suites:['obsidian-unit','safari-engine'],why:'direct deployed-core parity consumers'},
  {pattern:/^extensions\/obsidian\//,suites:['obsidian-unit','client-lifecycle','dom-engine','obsidian-editor-live','obsidian-reading-live'],why:'Editor/Reading capture/transport'},
  {pattern:/^Sources\/DictionaryApp\/Capture\//,suites:['swift-capture','swift-request','native'],why:'capture/range pipeline'},
  {pattern:/SafariContextExtractor\.swift$/,suites:['safari-engine','safari-live'],why:'Safari injection/decoder'},
  {pattern:/\/(SelectionLocation|LookupRequest|TranslateRequest)\.swift$/,suites:[...swift,...clients,...live,'model-live'],why:'shared capture/request/transport schema'},
  {pattern:/\/(LookupCoordinator|ControlledProvider)\.swift$/,suites:[...swift,...live],why:'shared coordinator/provider lifecycle'},
  {pattern:/\/PromptBuilder\.swift$|^Sources\/DictionaryApp\/Providers\//,suites:[...swift,'native','http-live','model-live'],why:'Provider input/protocol and model routing'},
  {pattern:/^Sources\/DictionaryApp\/(Lookup|Server)\//,suites:['swift-request','swift-http','swift-lifecycle','http-live'],why:'request/server lifecycle'},
  {pattern:/^Sources\/DictionaryApp\/Server\//,suites:[...clients,...live],why:'HTTP/auth/lifecycle contract consumers'},
  {pattern:/^Sources\/DictionaryApp\/UI\//,suites:['swift-request','swift-lifecycle','ui-simulated','native'],why:'presentation and window state'},
  {pattern:/^Tests\/DictionaryAppTests\//,suites:swift,why:'shared Swift test target and fixtures'},
  {pattern:/^Tests\/(Fixtures|Support)\/|^docs\/qa\/.*\/(fixtures|browser-fixtures)\//,suites:[...swift,...clients,...live],why:'shared acquisition/transport fixtures'},
  {pattern:/^Tests\/QA\/fixtures\//,suites:['infra','qa-build'],why:'shared QA test fixtures'},
  {pattern:/^(Package\.(swift|resolved)|\.gitignore)$/,suites:[...swift,'infra','qa-build','native'],why:'build/config input shared by Swift and QA packaging'}
];

export function plan(paths,goals=[]) {
  const found=new Map(),warnings=[];
  function add(ids, reason) {
    for(const id of ids) {
      const suite=suites.find(s=>s.id===id);
      if(!found.has(id)) found.set(id,{suite:id,level:suite.level,reasons:[],automatic:false});
      if(!found.get(id).reasons.includes(reason))found.get(id).reasons.push(reason);
    }
  }
  for(const p of paths) {
    let known=false;
    for(const rule of rules)if(rule.pattern.test(p)){known=true;add(rule.suites,`${p}: ${rule.why}`);}
    for(const suite of suites)if(suite.files?.includes(p)){known=true;add([suite.id],`${p}: direct test input`);}
    if(!known&&(p==='README.md'||p.startsWith('docs/')))continue;
    if(!known) {
      warnings.push(`Unclassified path: ${p}; review scope, do not infer acceptance.`);
      add(suites.filter(s=>s.level!=='L4').map(s=>s.id),`${p}: unclassified dependency; review scope`);
    }
  }
  const goalMap={native:['swift-capture','native'],chromium:['chromium-unit','dom-engine','chromium-loaded'],
    obsidian:['obsidian-unit','dom-engine','obsidian-editor-live','obsidian-reading-live'],safari:['safari-engine','safari-live'],
    lifecycle:['swift-lifecycle','client-lifecycle','ui-simulated','http-live'],model:['swift-request','model-live'],unicode:['swift-capture','dom-engine','native','chromium-loaded','obsidian-editor-live','obsidian-reading-live','safari-live']};
  for(const goal of goals) {
    if(goalMap[goal])add(goalMap[goal],'Explicit goal: '+goal);
    else if(suites.some(s=>s.id===goal))add([goal],'Explicit goal: '+goal);
    else throw Error('Unknown goal; use a suite ID or native/chromium/obsidian/safari/lifecycle/model/unicode');
  }
  return {command:'plan',executed:false,paths,goals,recommended:[...found.values()],warnings,
    note:'Recommendations only. L2/L3 require explicit selection and flags; L4 is never inferred. Historical evidence is not a new execution.'};
}
