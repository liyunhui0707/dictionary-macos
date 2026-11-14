const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const root = require('node:path').resolve(__dirname, '../..');
const worker = fs.readFileSync(`${root}/Extensions/chromium/service-worker.js`, 'utf8');
const options = fs.readFileSync(`${root}/Extensions/chromium/options.js`, 'utf8');
function harness({token='synthetic-token', status=200, body={service:'dictionary',protocol:1}, network=false, payload={target:'bank',context:'They walked along the bank of the river.', capture:{version:1}}}={}) {
    const calls=[], notifications=[], badges=[]; let command, message; let saved;
    const elements = Object.fromEntries(['token','status','verify','check','lookup','shortcut','clear'].map(id=>[id,{value:'',textContent:'',addEventListener(){}}]));
    const context = vm.createContext({console, AbortSignal, document:{getElementById:id=>elements[id]}, navigator:{userAgent:'Edg/'},
        chrome:{ storage:{local:{get:async()=>({token}), set:async v=>{saved=v}}},
            tabs:{query:async()=>[{id:7}],sendMessage:async()=>payload},
            notifications:{create:async n=>notifications.push(n)}, action:{setBadgeText:async v=>badges.push(v.text),setBadgeBackgroundColor:async()=>{}},
            commands:{onCommand:{addListener:f=>{command=f}},getAll:async()=>[{name:'lookup-selection',shortcut:'Alt+D'}]},
            runtime:{id:'test-extension',getURL:p=>`chrome-extension://test-extension/${p}`,onMessage:{addListener:f=>{message=f}},sendMessage:async()=>({ok:true,message:'synthetic'})}},
        fetch:async(url,init)=>{calls.push({url,init});if(network) throw Error('SECRET_INTERNAL_FAILURE');return {status,ok:status>=200&&status<300,json:async()=>body}}});
    vm.runInContext(worker,context);
    return {context,calls,notifications,badges,elements,command:()=>command,message:()=>message,saved:()=>saved};
}
test('saved pairing status is authenticated, bounded, and never invokes translate',async()=>{
    const h=harness();const result=await vm.runInContext('checkConnection()',h.context);
    assert.equal(result.ok,true);assert.equal(h.calls.length,1);
    assert.match(h.calls[0].url,/\/v1\/status$/);assert.equal(h.calls[0].init.headers.Authorization,'Bearer synthetic-token');
    assert.equal(h.calls[0].init.body,undefined);assert.ok(h.calls[0].init.signal);
    assert.ok(!JSON.stringify(result).includes('synthetic-token'));
});
for(const scenario of [{token:''},{status:401},{status:404},{status:500},{body:{service:'other',protocol:1}},{body:{service:'dictionary',protocol:2}},{network:true}]) {
    test(`connection rejects ${JSON.stringify(scenario)}`,async()=>{
        const h=harness(scenario);const r=await vm.runInContext('checkConnection()',h.context);
        assert.equal(r.ok,false);assert.ok(!r.message.includes('SECRET_INTERNAL_FAILURE'));
        if(scenario.token==='') assert.equal(h.calls.length,0);
    });
}
test('shortcut and toolbar share selected-tab capture and preserve metadata',async()=>{
    const h=harness();h.command()('lookup-selection');
    await new Promise(r=>setImmediate(r));
    assert.equal(h.calls.length,1);const body=JSON.parse(h.calls[0].init.body);
    assert.equal(body.target,'bank');assert.equal(body.capture.version,1);assert.equal(body.sourceApp,'Edge');
    let reply;const keep=h.message()({type:'LOOKUP_ACTIVE_TAB'},{id:'test-extension',url:'chrome-extension://test-extension/options.html'},r=>{reply=r});
    assert.equal(keep,true);await new Promise(r=>setImmediate(r));assert.equal(reply.ok,true);assert.equal(h.calls.length,2);
});
test('web content cannot invoke extension-owned diagnostics or lookup',()=>{
    const h=harness();assert.equal(h.message()({type:'CHECK_CONNECTION'},{id:'test-extension',tab:{id:7},url:'https://example.test'},()=>assert.fail()),undefined);
    assert.equal(h.calls.length,0);
});
test('missing selection never sends authenticated translation and sets visible badge',async()=>{
    const h=harness({payload:{empty:true}});const r=await vm.runInContext('lookupActiveTab()',h.context);
    assert.equal(r.ok,false);assert.equal(h.calls.length,0);assert.deepEqual(h.badges,['!']);
});
for(const status of [401,404,500,503]) {
    test(`failed verification ${status} cannot persist candidate token`,async()=>{
        const h=harness({status});vm.runInContext(options,h.context);h.elements.token.value='candidate-secret';
        await vm.runInContext('verifyAndSave()',h.context);assert.equal(h.saved(),undefined);
        assert.ok(!h.elements.status.textContent.includes('candidate-secret'));
    });
}
test('verified token is saved only for the expected service; input is cleared without reloading stored token',async()=>{
    const h=harness();vm.runInContext(options,h.context);assert.equal(h.elements.token.value,'');
    h.elements.token.value='candidate-secret';await vm.runInContext('verifyAndSave()',h.context);
    assert.equal(h.saved().token,'candidate-secret');assert.equal(h.elements.token.value,'');
    assert.ok(h.calls.every(c=>c.url.endsWith('/v1/status')));
});
