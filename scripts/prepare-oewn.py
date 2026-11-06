#!/usr/bin/env python3
"""Reproduce the bundled reference from the already-authorized OEWN 2025 archive.

No network access or extraction. Usage: python3 scripts/prepare-oewn.py ARCHIVE OUTPUT_DIR
License texts in OUTPUT_DIR are retained separately from the release tag, with trailing whitespace trimmed.
"""
import gzip
import hashlib
import json
import pathlib
import sys
import zipfile

ARCHIVE_SHA256 = '7d749f6e2c39e6970e4997839dcf6e42fd281f3c2fae0171d2192bae8cfa4b51'


def convert(archive, destination):
    archive = pathlib.Path(archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != ARCHIVE_SHA256:
        raise ValueError('Not the verified OEWN 2025 archive')
    entries, synsets, forms = {}, {}, {}
    with zipfile.ZipFile(archive) as source:
        for name in sorted(source.namelist()):
            if not name.endswith('.json'):
                continue
            data = json.loads(source.read(name))
            leaf = pathlib.PurePosixPath(name).name
            if leaf.startswith('entries-'):
                for lemma, variants in data.items():
                    entries[lemma] = sorted([[s['id'], s['synset']]
                        for entry in variants.values() for s in entry['sense']])
                    # Keep the exact lexical senses associated with each recorded form.
                    # POS alone is insufficient for split entries such as n-1/n-2.
                    for entry in variants.values():
                        for form in entry.get('form', []):
                            for sense in entry['sense']:
                                forms.setdefault(form, set()).add((lemma, sense['id']))
            elif leaf != 'frames.json':
                for key, value in data.items():
                    # Retain all definitions/examples, no model/gold/POS filtering.
                    examples = [e if isinstance(e, str) else e['text'] for e in value.get('example', [])]
                    synsets[key] = [value['definition'], examples, value['partOfSpeech']]
    assert len(entries) == 128009 and len(synsets) == 107519
    assert sum(map(len, entries.values())) == 185129
    assert all(synset in synsets for senses in entries.values() for _, synset in senses)
    forms = {form: sorted(rows) for form, rows in forms.items()}
    raw = json.dumps({'entries': entries, 'synsets': synsets, 'forms': forms}, ensure_ascii=False,
                     sort_keys=True, separators=(',', ':')).encode()
    payload = gzip.compress(raw, mtime=0)
    destination = pathlib.Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    (destination / 'oewn-2025.json.gz').write_bytes(payload)
    manifest = {
        'dataset': 'Open English Wordnet', 'version': '2025-edition', 'language': 'en',
        'sourceURL': 'https://en-word.net/static/english-wordnet-2025-json.zip',
        'releaseURL': 'https://github.com/globalwordnet/english-wordnet/releases/tag/2025-edition',
        'archiveSHA256': ARCHIVE_SHA256, 'resourceSHA256': hashlib.sha256(payload).hexdigest(),
        'resourceBytes': len(payload), 'uncompressedBytes': len(raw),
        'lemmas': len(entries), 'lexicalSenses': 185129, 'synsets': len(synsets),
        'recordedForms': len(forms),
        'license': 'CC BY 4.0; underlying Princeton WordNet notices retained',
        'licenseURLs': ['https://raw.githubusercontent.com/globalwordnet/english-wordnet/2025-edition/LICENSE.md',
                        'https://raw.githubusercontent.com/globalwordnet/english-wordnet/2025-edition/WNDB_License.txt'],
        'licenseFormatting': 'Trailing whitespace trimmed; license wording retained.',
        'changes': 'Compact English reference extract: lexical sense IDs, synset IDs, POS, all definitions and examples. Recorded forms retain their exact lemma/sense associations. Relations and pronunciation omitted. Examples retain text; source annotations omitted. Sense IDs sorted lexically, not ranked by contextual relevance. Regular inflection candidates are generated separately by application code, not claimed as OEWN-recorded forms.',
        'checksumNote': 'Locally calculated hashes, not official publisher signatures.'
    }
    (destination / 'provenance.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(manifest, indent=2))


if __name__ == '__main__':
    convert(*sys.argv[1:])
