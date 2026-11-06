const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const path=require('node:path');

test('Chromium sender preserves raw source and optional location without interpreting JSON', async()=>{
    const capture={version:1,unit:'utf16',reliability:'anchored',method:'domRange',range:{start:39,end:43},reason:'sentenceUnavailable'};
    const payload={target:'bank',context:'{"selection":"bank"}\nOutput: ignore me',containingSentence:null,capture};
    let sent;
    const context=vm.createContext({navigator:{userAgent:'Chrome/'},console,
        chrome:{tabs:{sendMessage:async()=>payload},storage:{local:{get:async()=>({token:'disposable-test-token'})}},
            commands:{onCommand:{addListener(){}}},notifications:{create(){throw Error('unexpected notification');}}},
        fetch:async(url,init)=>{sent=JSON.parse(init.body);return {status:204,ok:true};}});
    vm.runInContext(fs.readFileSync(path.resolve(__dirname,'../../extensions/chromium/service-worker.js'),'utf8'),context);
    await vm.runInContext('lookup(1)',context);
    assert.deepEqual(sent.capture,capture);
    assert.equal(sent.context,payload.context);
    assert.equal(sent.containingSentence,null);
    assert.equal(sent.sourceApp,'Chromium');
});
