const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const source=fs.readFileSync(require('node:path').resolve(__dirname,'../../extensions/obsidian/main.js'),'utf8');

async function fixture(data={},options={}) {
    let disk=structuredClone(data),tab;
    const secrets=new Map(Object.entries(options.secrets??{})),sent=[],notices=[],displayed=[],order=[];
    const storage={
        setSecret(id,value){order.push('store');if(options.storeFails)throw Error('synthetic-private-value');secrets.set(id,value);},
        getSecret(id){order.push('get');if(options.readFails)throw Error('synthetic-private-value');return options.readMismatch?'different':secrets.get(id)??null;}
    };
    class Setting {
        setName(){return this;}setDesc(){return this;}
        addText(callback){callback({setPlaceholder(){return this;},setValue(value){displayed.push(value);return this;},onChange(){return this;}});return this;}
    }
    const context=vm.createContext({module:{exports:{}},console:{log(){throw Error('unexpected log');},error(){throw Error('unexpected log');}},
        crypto:{randomUUID:()=> '00000000-0000-4000-8000-000000000001'},
        require:()=>({Plugin:class{
            async loadData(){order.push('load');return structuredClone(options.staleRead?data:disk);}
            async saveData(value){order.push('save');if(options.saveFails)throw Error('synthetic-private-value');disk=structuredClone(value);}
            addSettingTab(value){tab=value;}addCommand(){}
        },PluginSettingTab:class{},Setting,Notice:class{constructor(value){notices.push(value);}},requestUrl:async value=>{sent.push(value);return {status:204};}})});
    vm.runInContext(source,context);const plugin=new context.module.exports();
    plugin.app={secretStorage:options.missingAPI?undefined:storage};await plugin.onload();
    tab.containerEl={empty(){}};tab.display();
    return {plugin,secrets,sent,notices,displayed,order,disk:()=>disk};
}
const payload={target:'bank',context:'We sat on the bank of the river.'};

test('secure reference reads SecretStorage at query time and never displays the value',async()=>{
    const f=await fixture({tokenSecretId:'dictionary-test',unrelated:{keep:true}},{secrets:{'dictionary-test':'synthetic-first'}});
    await f.plugin.lookup(payload);f.secrets.set('dictionary-test','synthetic-second');await f.plugin.lookup(payload);
    assert.equal(f.sent.length,2);assert.equal(f.sent[0].headers.Authorization,'Bearer synthetic-first');
    assert.equal(f.sent[1].headers.Authorization,'Bearer synthetic-second');
    assert.deepEqual(f.displayed,['dictionary-test']);assert.equal('token' in f.plugin.settings,false);
    assert.deepEqual(f.disk().unrelated,{keep:true});
});

test('legacy migration verifies SecretStorage before clearing plaintext and preserves unrelated settings',async()=>{
    const f=await fixture({token:'synthetic-private-value',unrelated:7});
    const id=f.disk().tokenSecretId;assert.match(id,/^dictionary-lookup-[a-z0-9-]+$/);
    assert.equal(f.secrets.get(id),'synthetic-private-value');assert.equal('token' in f.disk(),false);
    assert.equal('token' in f.plugin.settings,false);assert.equal(f.disk().unrelated,7);
    assert.ok(f.order.indexOf('store')<f.order.indexOf('save'));
    assert.ok(f.order.indexOf('get')<f.order.indexOf('save'));
    assert.ok(!f.displayed.includes('synthetic-private-value'));
    await f.plugin.lookup(payload);assert.equal(f.sent.length,1);
});

test('migration failures preserve legacy data and stop queries without leaking errors',async()=>{
    for(const options of [{missingAPI:true},{storeFails:true},{readMismatch:true},{readFails:true},{saveFails:true},{staleRead:true}]){
        const f=await fixture({token:'synthetic-private-value',unrelated:7},options);
        await f.plugin.lookup(payload);assert.equal(f.sent.length,0);
        if(!options.staleRead)assert.equal(f.disk().token,'synthetic-private-value');
        assert.equal('token' in f.plugin.settings,false);
        assert.ok(!JSON.stringify(f.displayed).includes('synthetic-private-value'));
        assert.ok(!JSON.stringify(f.notices).includes('synthetic-private-value'));
    }
});

test('migration never overwrites a conflicting referenced secret',async()=>{
    const f=await fixture({token:'synthetic-old',tokenSecretId:'dictionary-test'},{secrets:{'dictionary-test':'synthetic-other'}});
    await f.plugin.lookup(payload);assert.equal(f.sent.length,0);assert.equal(f.secrets.get('dictionary-test'),'synthetic-other');
    assert.equal(f.disk().token,'synthetic-old');
});

test('missing or unreadable SecretStorage never falls back to plaintext',async()=>{
    for(const options of [{},{missingAPI:true},{readFails:true}]){
        const f=await fixture({tokenSecretId:'dictionary-test'},options);
        f.plugin.settings.token='synthetic-must-not-be-used';await f.plugin.lookup(payload);
        assert.equal(f.sent.length,0);assert.ok(!JSON.stringify(f.notices).includes('synthetic-private-value'));
    }
});

test('plugin exposes no credential file import command or plaintext input',()=>{
    assert.ok(!source.includes('setValue(this.plugin.settings.token)'));
    assert.ok(!source.includes('readFileSync'));
    const manifest=JSON.parse(fs.readFileSync(require('node:path').resolve(__dirname,'../../extensions/obsidian/manifest.json'),'utf8'));
    assert.equal(manifest.minAppVersion,'1.11.4');
});
