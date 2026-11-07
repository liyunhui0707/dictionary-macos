# Release process

The selected channel is an **ad-hoc signed, unnotarized macOS download**.
Developer ID signing and Apple notarization remain an upgrade to distribution,
not a requirement to buy membership before this channel can ship. Do not describe
these artifacts as Apple-verified or bypass macOS security to test them.

1. Explicitly approve a SemVer version in `VERSION`. The selected version for this
   delivery is 0.2.0. App packagers read that file; companion extension versions
   change only when their implementation/protocol requires it.
2. Run `swift test` and `node --test Tests/QA/*.test.cjs Tests/Extensions/*.test.cjs`.
   Optional live model tests require separately authorized data, credentials and
   call limits. They are off in normal tests. Review semantic results separately.
3. Complete relevant native capture and interaction acceptance with synthetic
   text. Record unsupported or untested applications honestly.
4. Commit the reviewed candidate, then run `node scripts/release-app.mjs` on macOS.
   It exports only production sources/resources and licenses from that commit,
   builds outside the maintainer's home, strips debug symbols, packages a native
   app without private QA metadata, and ad-hoc signs it. It creates a host-architecture
   ZIP, DMG, SHA256SUMS and public provenance manifest under
   `build/releases.noindex/<version>-<architecture>/`. It refuses dirty source or
   an existing output directory; failed candidates remain for inspection.
5. Inspect actual payloads for private information, resources, version and architecture.
   Checksums are not identity authentication. Never upload the private build log,
   scratch checkout, local certificates, keys or QA evidence. Keep certificate-signed
   local daily/testing builds separate from public ad-hoc assets.
6. On another Mac, verify exact hashes, install without a checkout/Xcode, first-use
   configuration, one contextual lookup, missing-service recovery, exit and upgrade.
   Preserve the previous app for rollback. SCP transfer does not reproduce browser
   quarantine: browser-download first-open acceptance is recorded separately.
   Any security/accessibility consent is performed normally by the owner.
7. Only publish a GitHub Release when required checks for that candidate pass.
   Include exact tested OS/architecture, version, commit, ZIP/DMG, SHA256SUMS,
   `release-manifest.json`, notices, setup requirements and unnotarized status.
   Do not replace an existing asset or tag silently. Incomplete delivery remains
   an explicit candidate rather than becoming an accepted release through wording.
8. Sync README, release notes and the existing website to the actual release.
   Releases are the canonical download source. Source push, binary publication
   and website deployment each need their own verification.

The app's **Check for Updates** action queries GitHub's public latest stable release
only when requested, then opens the validated release page. Replacement is manual.
No background updater or automatic installer exists. Preserve settings and the
same local signing identity when possible; never reset Accessibility permissions
as a routine build/update step. Ad-hoc updates may require new consent.
