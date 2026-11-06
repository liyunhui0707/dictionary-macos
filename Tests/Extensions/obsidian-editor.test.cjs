const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const path=require('node:path');
const source=fs.readFileSync(path.resolve(__dirname,'../../extensions/obsidian/main.js'),'utf8');

// Public Editor contract double; the actual plugin command and sender run in VM.
function editorFor(raw,anchor,head,options={}) {
    const lines=raw.split('\n'), starts=[0];
    for (const line of lines.slice(0,-1)) starts.push(starts.at(-1)+line.length+1);
    const pos=offset=>{let line=0;while(line+1<starts.length && starts[line+1]<=offset)line++;return {line,ch:offset-starts[line]};};
    const offset=p=>starts[p.line]+p.ch;
    const a=pos(anchor),h=pos(head), lo=pos(Math.min(anchor,head)),hi=pos(Math.max(anchor,head));
    const reads={lines:0,rangeUnits:0,ranges:0};
    const editor={
        getSelection:()=>options.selection ?? raw.slice(Math.min(anchor,head),Math.max(anchor,head)),
        getCursor:side=>side==='from'?lo:side==='to'?hi:side==='anchor'?a:h,
        listSelections:()=>options.multiple?[{anchor:a,head:h},{anchor:a,head:h}]:[{anchor:a,head:h}],
        getLine:n=>{reads.lines++;if(n<0||n>=lines.length)throw Error('invalid line');return lines[n];},
        lineCount:()=>lines.length,
        getRange:(from,to)=>{reads.ranges++;const n=offset(to)-offset(from);reads.rangeUnits=Math.max(n,reads.rangeUnits);if(n>8000)throw Error('unbounded getRange');const s=raw.slice(offset(from),offset(to));return options.changeSource&&reads.ranges>=5?s+' changed':s;},
        hasFocus:()=>options.focus!==false,
        getValue:()=>{throw Error('whole-document acquisition');}
    };
    return {editor,reads};
}
async function command(raw,anchor,head,options={}) {
    const {editor,reads}=editorFor(raw,anchor,head,options), sent=[], notices=[],logs=[];
    let registered;
    class MarkdownView {}
    const view={editor,getMode:()=>options.mode??'source'};
    const context=vm.createContext({module:{exports:{}},navigator:{language:'en'},
        console:{log:(...x)=>logs.push(x),warn:(...x)=>logs.push(x),error:(...x)=>logs.push(x)},
        window:{getSelection:()=>{throw Error('editor command used unrelated DOM selection');}},
        require:()=>({MarkdownView,Plugin:class {
            async loadData(){return {tokenSecretId:'disposable-editor-test'};} addSettingTab(){} addCommand(c){registered=c;}
        },PluginSettingTab:class {},Setting:class {},Notice:class{constructor(x){notices.push(x);}},
        requestUrl:async r=>{sent.push(JSON.parse(r.body));return {status:204,get json(){throw Error('204 parsed');}};}})});
    const pluginContext={secretStorage:{getSecret:()=> 'disposable-editor-test',setSecret(){throw Error('unexpected credential write');}},workspace:{getActiveViewOfType:t=>{assert.equal(t,MarkdownView);return options.noView?null:view;},activeEditor:{editor:options.staleEditor??editor}}};
    vm.runInContext(source,context);
    const plugin=new context.module.exports();plugin.app=pluginContext;
    await plugin.onload(); await registered.callback();
    return {sent,notices,logs,reads,editor};
}
function located(reply,raw,start,target='bank',sentence=null) {
    assert.equal(reply.target,target);assert.equal(reply.context,raw);
    assert.equal(reply.capture.method,'editorRange');assert.equal(reply.capture.reliability,'anchored');
    assert.deepEqual(reply.capture.range,{start,end:start+target.length});
    assert.equal(reply.containingSentence,sentence);
    assert.equal(reply.capture.reason,sentence===null?'sentenceUnavailable':null);
    if(sentence===null)assert.equal(reply.capture.sentenceRange,null);
}
test('B2-A baseline defect: second bank must not return the first loan sentence',async()=>{
    const r=await command('The bank approved my loan. We sat on the bank of the river.',45,41);
    assert.equal(r.sent[0].target,'bank');
    assert.equal(r.sent[0].containingSentence,'We sat on the bank of the river.');
});
test('B2-A actual command preserves repeated occurrence, reverse and same-sentence coordinates',async()=>{
    const raw='The bank approved my loan. We sat on the bank of the river.';
    for(const [a,b,s]of[[4,8,'The bank approved my loan.'],[45,41,'We sat on the bank of the river.']]){
        const r=await command(raw,a,b);assert.equal(r.sent.length,1);located(r.sent[0],raw,Math.min(a,b),'bank',s);
        assert.equal(r.sent[0].sourceApp,'Obsidian');assert.deepEqual(r.logs,[]);assert.deepEqual(r.notices,[]);
    }
    const same='I called the bank while sitting on the bank of the river.';
    for(const a of[13,39])located((await command(same,a,a+4)).sent[0],same,a,'bank',same);
});
test('B2-A source and Live Preview use raw Markdown coordinates without stripping decoration',async()=>{
    for(const raw of['The **bank** called the [bank](https://example.test/bank).','The bank called the bank.']){
        const a=raw.startsWith('The **')?25:20;
        const r=await command(raw,a,a+4);
        located(r.sent[0],raw,a,'bank',raw.includes('**')?null:raw);
    }
});
test('B2-A Unicode, column offsets, cross-line and selected whitespace stay source-exact',async()=>{
    const raw='🌊 e\u0301 — The bank closed.\nWe sat on the bank of the river.';
    for(const [a,b,t]of[[12,16,'bank'],[39,43,'bank'],[23,30,'.\nWe sa']]){
        const r=await command(raw,b,a);located(r.sent[0],raw,a,t);
    }
    located((await command('  The bank closed.  ',5,11)).sent[0],'The bank closed.',4,'bank','The bank closed.');
});
test('B2-A multiple cursors and mismatched source are word-only; empty editor never uses stale DOM',async()=>{
    for(const options of[{multiple:true},{selection:'bank',mismatch:true}]){
        const r=await command('The bank closed.',options.mismatch?0:4,options.mismatch?3:8,options);
        assert.equal(r.sent[0].target,'bank');assert.equal(r.sent[0].capture.reliability,'targetOnly');
        assert.equal(r.sent[0].context,null);assert.equal(r.sent[0].containingSentence,null);
    }
    for(const options of[{}, {focus:false}, {noView:true}]){
        const r=await command('The bank closed.',4,options.focus===false||options.noView?8:4,options);
        assert.equal(r.sent.length,0);
    }
});
test('B2-A punctuation uncertainty never becomes an exact Original sentence',async()=>{
    for(const [raw,a]of[['Capt. Smith visited the bank.',24],['The bank called pvt. Smith.',4],['A bank near the river',2],['We sat on the\nbank of the river.',14]]){
        located((await command(raw,a,a+4)).sent[0],raw,a);
    }
    for(const raw of['The bank ran.','The bank used 3.5 units.'])located((await command(raw,4,8)).sent[0],raw,4,'bank',raw);
});
test('B2-A long source is acquired around actual selection, bounded and never searches an earlier bank',async()=>{
    const prefix='The bank closed. '+ 'Earlier sentence. '.repeat(1500),raw=prefix+'We sat on the bank of the river.';
    const r=await command(raw,prefix.length+14,prefix.length+18),p=r.sent[0];
    assert.equal(p.capture.reliability,'anchored');assert.equal(p.capture.reason,'sentenceUnavailable');
    assert.ok(p.context.length<=2000);assert.equal(p.context.slice(p.capture.range.start,p.capture.range.end),'bank');
    assert.equal(p.containingSentence,null);assert.ok(r.reads.rangeUnits<=8000);assert.ok(r.reads.lines<4000);
});
test('B2-A paragraph origin and source-change evidence are checked without stale activeEditor use',async()=>{
    const raw='Unrelated bank.\n\nThe bank closed.';
    located((await command(raw,21,25,{staleEditor:{getSelection(){throw Error('stale editor read');}}})).sent[0],'The bank closed.',4,'bank','The bank closed.');
    for(const options of[{mode:'other'},{focus:false},{noView:true}])assert.equal((await command(raw,21,25,options)).sent.length,0);
});
test('B2 adapters retain one accepted raw-text and sentence profile without a runtime loader',()=>{
    const chromium=fs.readFileSync(path.resolve(__dirname,'../../extensions/chromium/content.js'),'utf8');
    const shared=chromium.slice(0,chromium.indexOf('function extractSelection()'));
    assert.ok(source.includes(shared),'Obsidian must deploy identical window/UTF-16/sentence rules');
    const reading=source.slice(source.indexOf('function extractFromDOM(root)'),source.indexOf('module.exports ='));
    // Only the Obsidian pane-viewport proof differs. The raw coordinate,
    // hidden-text, bidi and sentence rules must still match Chromium exactly.
    const clipStart=reading.indexOf('        // Obsidian pane clipping is safe only');
    const clipEnd=reading.indexOf('        const reply=captureRawText',clipStart);
    assert.ok(clipStart>=0&&clipEnd>clipStart,'Reading must retain its bounded pane geometry proof');
    const restored=(reading.slice(0,clipStart)+reading.slice(clipEnd))
        .replace('const checkedLocal=new Set(), checkedOuter=new Set(), clippedAncestors=[];',
            'const checkedLocal=new Set(), checkedOuter=new Set();')
        .replace("local && (['hidden','clip'].includes(c.overflowX) || ['hidden','clip'].includes(c.overflowY))",
            "['hidden','clip'].includes(c.overflowX) || ['hidden','clip'].includes(c.overflowY)")
        .replace("            if (!local && (['hidden','clip'].includes(c.overflowX) || ['hidden','clip'].includes(c.overflowY))) {\n                clippedAncestors.push({el,x:c.overflowX!=='visible',y:c.overflowY!=='visible'});\n            }\n",'')
        .replace('function extractFromDOM(root)','function extractSelection()')
        .replace('    if (!root?.isConnected || root.ownerDocument!==document) return {empty:true};\n','')
        .replace('    if (!root.contains(sel.anchorNode) || !root.contains(sel.focusNode)) return {empty:true};\n','')
        .replace('!block || !root.contains(block) ||','!block ||')
        .replace('!now || !root.isConnected || !root.contains(snapshot[0]) || !root.contains(snapshot[2]) ||','!now ||');
    assert.equal(restored,chromium.slice(chromium.indexOf('function extractSelection()'),chromium.indexOf('chrome.runtime.onMessage')));
});
test('B2-A edge trim applies before the target budget without discarding a valid word',async()=>{
    const raw=' '.repeat(2100)+'Bank near the river.';
    const r=await command(raw,0,2104);
    located(r.sent[0],'Bank near the river.',0,'Bank','Bank near the river.');
    const huge='a'.repeat(2001),p=(await command(huge,0,huge.length)).sent[0];
    assert.equal(p.target,huge);assert.equal(p.context,null);assert.equal(p.capture.reason,'budgetExceeded');
});
test('B2-A changed source and split-surrogate positions cannot remain anchored',async()=>{
    const changed=(await command('The bank closed.',4,8,{changeSource:true})).sent[0];
    assert.equal(changed.capture.reason,'sourceChanged');assert.equal(changed.capture.reliability,'targetOnly');
    const split=(await command('🌊 bank closed.',1,2)).sent[0];
    assert.equal(split.capture.reason,'rangeMismatch');assert.equal(split.capture.reliability,'targetOnly');
});
test('B2-A whitespace boundary inspection cannot bypass the acquisition budget',async()=>{
    const raw='The bank closed.\n'+' '.repeat(6000)+'\nOther bank.';
    const reply=(await command(raw,4,8)).sent[0];
    assert.equal(reply.target,'bank');assert.equal(reply.context,null);
    assert.equal(reply.capture.reliability,'targetOnly');assert.equal(reply.capture.reason,'budgetExceeded');
});
