const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');

test('offline pronunciation data and original redistribution license are pinned and packageable', async () => {
  const {verifyPronunciationBundle}=await import('../../scripts/qa-app.mjs');
  const resources=path.resolve(__dirname,'../../Sources/DictionaryApp/Resources');
  const source=verifyPronunciationBundle(resources);
  const provenance=JSON.parse(fs.readFileSync(path.join(source,'provenance.json')));
  assert.equal(provenance.revision,'74790861f652b15e4ac49015a90074ad62a27690');
  assert.match(fs.readFileSync(path.join(source,'LICENSE'),'utf8'),/Redistributions in binary form/);
  assert.match(fs.readFileSync(path.join(source,'cmudict.dict'),'utf8'),/^company K AH1 M P AH0 N IY2$/m);
  const temporary=fs.mkdtempSync(path.join(os.tmpdir(),'dictionary-pronunciation-'));
  fs.cpSync(source,path.join(temporary,'Pronunciation'),{recursive:true});
  fs.appendFileSync(path.join(temporary,'Pronunciation/cmudict.dict'),'changed');
  assert.throws(()=>verifyPronunciationBundle(temporary),/checksum mismatch/);
  fs.renameSync(path.join(temporary,'Pronunciation/LICENSE'),path.join(temporary,'retained-license'));
  assert.throws(()=>verifyPronunciationBundle(temporary),/Missing or unsafe/);
});
