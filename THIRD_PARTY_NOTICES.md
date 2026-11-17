# Third-party notices

The application code is licensed under MIT. This does not relicense third-party resources.

## Open English Wordnet, 2025 edition

The bundled English reference extract is derived from Open English Wordnet 2025.
It retains definitions, examples, sense identifiers and recorded forms. It is not
ranked by contextual relevance. Source and transformation hashes are recorded in
`Sources/DictionaryApp/Resources/EnglishDictionary/provenance.json`.

- Source: https://github.com/globalwordnet/english-wordnet/releases/tag/2025-edition
- License: CC BY 4.0; see `Sources/DictionaryApp/Resources/EnglishDictionary/LICENSE.md`.
- Underlying Princeton WordNet notices: `Sources/DictionaryApp/Resources/EnglishDictionary/WNDB_License.txt`.

These notices and files must accompany redistributed application bundles.
No Chinese Open Wordnet data is included. Ollama models are not bundled; users
must observe the licenses of the models they obtain. Cloud services have their
own terms and are not sublicensed by this repository.


## CMU Pronouncing Dictionary

American pronunciation references use CMUdict from cmusphinx/cmudict, revision
`74790861f652b15e4ac49015a90074ad62a27690`, under its BSD-style two-clause license.
The original dictionary, full copyright/license and source hashes are bundled in
`Sources/DictionaryApp/Resources/Pronunciation/`. ARPAbet is converted by the app to
broad American IPA. Multiple readings retain upstream order and are not ranked
by contextual relevance. This is a pronunciation reference, not a guarantee of
all pronunciations or a learner-dictionary transcription. Recorded audio is not
included. Playback uses installed Apple US-English system synthesis voices.

Source: https://github.com/cmusphinx/cmudict
