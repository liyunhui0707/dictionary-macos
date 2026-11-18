# Maintenance and installation

Wordlit naming applies from 0.11.0. Keep a verified 0.10.0 Dictionary rollback
when moving the daily entry to `/Applications/Wordlit.app`. See
[cutover order](../branding/README.md#public-cutover-order).

Maintain product source in this public repository. A new patch updates the same
product, not a newly named daily application. Keep one daily installation at
`/Applications/Wordlit.app`. Test builds and rollback evidence are separate.

## Identify the running application

Use **Wordlit → 关于 Wordlit** to see the product version and exact build
identifier. A shared version such as 0.1.0 does not distinguish development builds.
The archive manifest identifies the source revision and input fingerprint. Do
not infer that the newest timestamp is a completed or accepted release.

## Build and test

The maintained builder writes candidates to `build/qa.noindex/<build-id>/`.
Certificate-signed testing uses the fixed
`build/testing.noindex/Wordlit Testing.app`; previous testing installations
are retained under `build/testing-history.noindex/`. The `.noindex` directories
keep build products separate from normal application discovery. Check actual
Spotlight results when troubleshooting stale entries; do not rebuild the whole
system index or modify system applications as a routine project cleanup.

The legacy shell packager and build-folder daily shortcut are compatibility
tools, not the normal installation procedure. Prefer `node scripts/qa-app.mjs build`
or certificate-signed `build-testing`. Do not launch every historical archive
or create a new permission entry per patch.

## Update the daily installation

1. Finish the scoped change and its relevant checks. Follow the explicit SemVer
   decision and release procedure; build IDs can distinguish candidates without
   inventing a new version policy.
2. Verify the candidate's signature, architecture, packaged resources and source
   identity. Preserve the existing designated signing requirement for routine
   local updates. If it changes unexpectedly, stop before replacing anything.
3. Quit the running daily app normally. Archive the previous bundle as a ZIP with
   its build identity and checksum, rather than leaving multiple live `.app`
   bundles indexed under the same name. Keep private install receipts local.
4. Verify the copied candidate, replace the same daily path, reopen and check
   first use, settings and capture permission. Do not clear preferences, Keychain
   items or Accessibility records as part of a normal update.
5. Commit and push the coherent reviewed source under current authorization.
   Keep release notes, public artifacts, README and website accurate wherever
   the user-visible behavior or available version changes. Source push is not
   binary publication or website deployment.

## Retire old products

Inventory exact project bundles first and protect the running installation,
source repositories, credentials and Apple's `/System/Applications/Dictionary.app`.
Archive and verify rollback bundles before recoverable removal of historical
copies. Use a private manifest to retain original paths and archive hashes.
Do not keep old rollback `.app` folders scattered through searchable directories.
Cleanup must not delete source or evidence merely to make the project look tidy.

The current product still needs contextual-meaning and cross-application acceptance.
Installation housekeeping and a successful build do not declare development complete.

## Isolated first-use acceptance

The fixed certificate-signed Testing app can opt into a new configuration with
`DICTIONARY_QA_FIRST_USE` set to a fresh UUID. The app requires its Testing bundle
identity and QA build metadata, and rejects provider/model launch overrides in
this mode. Invalid requests stop launch rather than falling back to daily data.
Public and daily builds cannot enable this mode.

The UUID names a separate preferences suite, token directory and dedicated
Keychain item. No existing preference or credential is copied, cleared or read.
Reuse the same UUID only to test that configuration's restart behavior. Do not
read pairing tokens in logs; the operator performs any pairing or key entry.
This verifies a fresh App configuration, not a new macOS account, model download,
system permission grant or cloud account. Those require separate evidence.

## Feedback and regression batches

Normal use is not a standing QA assignment. A useful initial report needs only
“which application, what was selected, what was wrong”. Version, model and a
previewed support report can be added later if they resolve a specific uncertainty.
Never request private reading material as a prerequisite; derive a synthetic case.
The App does not upload feedback or retain a reading history automatically.

For each development batch:

1. Classify the report as capture, configuration/service, explanation, or
   installation/distribution. Separate the selected word, the source sentence,
   the model response and the human semantic judgment. A correct meaning cannot
   prove the source sentence was captured correctly.
2. Deduplicate against existing regressions and known limits. Record whether the
   problem is reproduced, plausible but unconfirmed, a duplicate, or a capability
   limit. Do not relabel an unobserved failure as fixed. Prioritize wrong/stale
   source text, privacy or data loss, blocked common reading paths, then recurring
   quality problems; isolated cosmetic requests can wait for a coherent batch.
3. Reproduce with synthetic inputs, add the smallest meaningful regression and
   review the actual changed path. Capture changes need repeated targets and
   source/page changes; setup changes need controlled unavailable/missing-model/
   cancellation/recovery states; model changes need frozen rubrics and a separate
   holdout, with raw responses reviewed for meaning, POS and complete translation.
4. Map each acceptance check to a changed behavior or explicit distribution risk.
   Reuse a prior actual acceptance only when the path and relevant conditions are
   unchanged, and identify its version. Unit tests, hidden rendering and CI are
   preferred for deterministic behavior. They do not prove universal application
   support, semantic quality or Gatekeeper first open.
5. Request at most one consolidated owner interaction batch when an essential
   new OS permission or real interaction cannot be verified otherwise. State what
   uncertainty it resolves and a bounded interaction budget. Do not routinely
   ask for bank queries, app restarts, pairing or permission rechecks on both Macs.
   Cancelled checks remain cancelled, not passed. A failed required check still
   blocks its dependent change or delivery.
6. Commit coherent reviewed changes on a topic branch, then integrate through a
   PR with required CI under current authorization. A small feedback item does
   not automatically require a version, install or release. When a release is
   justified, explicitly confirm its version, freeze exact assets and preserve
   rollback; follow [the release process](releasing.md).

Capture/configuration/provider regressions live in `Tests/DictionaryAppTests`;
extension and packaging checks live in `Tests/Extensions` and `Tests/QA`.
[Reading compatibility](reading-compatibility.md), [quality evidence](quality.md)
and each published release note state the tested scope. Keep machine receipts,
raw local evaluation records and continuity in ignored `.local/`, never in release
assets. No scheduled jobs, telemetry or automatic issue submission are required.

### Open limitations to revisit with new evidence

| Area | Current boundary | Evidence needed to change the claim |
| --- | --- | --- |
| Capture | App/document support varies; Books OCR requires preview, can conservatively fall back on source changes | A synthetic failing case and source/selection isolation regression; real interaction only for the changed path |
| OCR latency | The earlier slow Vision cause was not isolated; scoped 0.9.1 cases completed without timeout | A bounded reproduction and timing metadata, rather than repeated owner word queries |
| Local meaning | Default 7B has documented collocation, grammar and unknown-word failures; optional model also has limits | Frozen semantic comparison and independent review; parsing success alone is insufficient |
| Browser setup | Loading, pairing and shortcuts still require browser actions; prepared files do not establish connection | Actual extension state for a changed integration, reusing unchanged prior acceptance otherwise |
| Distribution | Public Apple Silicon artifacts remain unnotarized with manual replacement; browser-quarantine first open was not tested for 0.9.1 | Explicit distribution testing or signing-channel work; never infer it from API downloads and matching hashes |
