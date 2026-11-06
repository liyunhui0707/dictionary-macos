import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {inspect, binaryIdentity, assertIdentity, runtime, assertLaunchSafe} from './qa-app.mjs';

// Immutable QA archives are evidence. Only this fixed, separately identified
// testing installation is used for routine desktop acceptance. Never edits TCC.
export function persistentRequirement(identity) {
  const requirement = identity.signature?.split('\n').find(line => line.startsWith('# designated =>'));
  if (!requirement || !/\b(anchor|certificate)\b/.test(requirement) || /\bcdhash\b/.test(requirement) || /Signature=adhoc/.test(identity.signature))
    throw Error('Persistent certificate signature required; refusing ad-hoc testing installation');
  return requirement;
}

export function stageTestingBuild(root, directory, verify=inspect, identify=binaryIdentity, checkRuntime=runtime) {
  if (fs.realpathSync(root) !== root) throw Error('Use the real project path');
  const out = path.resolve(directory);
  if (path.dirname(out) !== path.join(root, 'build/qa') || fs.realpathSync(out) !== out)
    throw Error('Testing target must be a real build/qa directory');
  const source = path.join(out, 'Dictionary.app');
  if (fs.realpathSync(source) !== source) throw Error('Symlink App refused');
  const state = checkRuntime(); assertLaunchSafe(state.processes, state.listeners);
  const manifest = verify(out);
  if (manifest.channel !== 'testing' || manifest.identity.bundleID !== 'com.liyunhui.DictionaryApp.testing')
    throw Error('Only a separately identified testing build may be staged');
  const requirement = persistentRequirement(manifest.identity);
  const build = path.join(root, 'build');
  if (fs.realpathSync(build) !== build) throw Error('Symlink build directory refused');
  const destination = path.join(build, 'testing');
  const appName = 'Dictionary Testing.app';
  let previous;
  if (fs.existsSync(destination)) {
    if (fs.realpathSync(destination) !== destination) throw Error('Symlink testing directory refused');
    previous = JSON.parse(fs.readFileSync(path.join(destination, 'current.json'), 'utf8'));
    const current = identify(path.join(destination, appName));
    assertIdentity(previous.identity, current);
    if (persistentRequirement(current) !== requirement)
      throw Error('Signing requirement changed; stop and investigate identity before touching permissions');
    if (previous.buildID === manifest.buildID) return {entry:path.join(destination, appName), unchanged:true};
  }
  const lock = path.join(build, 'testing-stage.lock');
  fs.mkdirSync(lock); // Exclusive; an interrupted run requires inspection, not blind retry.
  try {
    const history = path.join(build, 'testing-history');
    fs.mkdirSync(history, {recursive:true});
    if (fs.realpathSync(history) !== history) throw Error('Symlink history refused');
    const id = crypto.randomUUID();
    const staged = path.join(build, 'testing-stage-' + id);
    fs.mkdirSync(staged);
    const copied = path.join(staged, appName);
    fs.cpSync(source, copied, {recursive:true, errorOnExist:true, force:false});
    const identity = identify(copied);
    assertIdentity({...manifest.identity, executable:identity.executable}, identity);
    const installedIdentity = {...identity, executable:path.join(destination, appName, 'Contents/MacOS/DictionaryApp')};
    fs.writeFileSync(path.join(staged, 'current.json'), JSON.stringify({buildID:manifest.buildID,
      source:out, identity:installedIdentity}, null, 2) + '\n', {flag:'wx'});
    // Recheck immediately before switching; don't replace a running app or a
    // destination another process changed while the copy was being verified.
    const latest = checkRuntime(); assertLaunchSafe(latest.processes, latest.listeners);
    if (previous) {
      assertIdentity(previous.identity, identify(path.join(destination, appName)));
    } else if (fs.existsSync(destination)) throw Error('Testing destination appeared during staging');
    const backup = previous ? path.join(history, id) : undefined;
    if (backup) fs.renameSync(destination, backup);
    try { fs.renameSync(staged, destination); }
    catch (error) { if (backup) fs.renameSync(backup, destination); throw error; }
    return {entry:path.join(destination, appName), buildID:manifest.buildID, backup, unchanged:false};
  } finally { fs.rmdirSync(lock); }
}
