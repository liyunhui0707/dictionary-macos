import fs from 'node:fs';
import path from 'node:path';

// Fixed public payload only: no recursive copying of local browser settings.
export const browserExtensionFiles = ['manifest.json','content.js','service-worker.js','options.html','options.js',
  'icons/16.png','icons/48.png','icons/128.png'];
export function bundleBrowserExtension(source, destination) {
  for (const file of browserExtensionFiles) {
    for (const component of [source, ...(file.startsWith('icons/') ? [path.join(source,'icons')] : []), path.join(source,file)]) {
      if (fs.lstatSync(component).isSymbolicLink()) throw Error('Symlink extension payload refused');
    }
    if (!fs.statSync(path.join(source,file)).isFile()) throw Error('Missing extension file');
  }
  const manifest = JSON.parse(fs.readFileSync(path.join(source,'manifest.json'),'utf8'));
  if (manifest.manifest_version !== 3 || manifest.name !== 'Dictionary Lookup') throw Error('Unexpected extension manifest');
  fs.mkdirSync(destination); fs.mkdirSync(path.join(destination,'icons'));
  for (const file of browserExtensionFiles) fs.copyFileSync(path.join(source,file),path.join(destination,file),fs.constants.COPYFILE_EXCL);
}
