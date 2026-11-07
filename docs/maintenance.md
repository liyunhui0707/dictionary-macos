# Maintenance and installation

Maintain product source in this public repository. A new patch updates the same
product, not a newly named daily application. Keep one daily installation at
`/Applications/Dictionary.app`. Test builds and rollback evidence are separate.

## Identify the running application

Use **Dictionary → 关于 Dictionary** to see the product version and exact build
identifier. A shared version such as 0.1.0 does not distinguish development builds.
The archive manifest identifies the source revision and input fingerprint. Do
not infer that the newest timestamp is a completed or accepted release.

## Build and test

The maintained builder writes candidates to `build/qa.noindex/<build-id>/`.
Certificate-signed testing uses the fixed
`build/testing.noindex/Dictionary Testing.app`; previous testing installations
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
