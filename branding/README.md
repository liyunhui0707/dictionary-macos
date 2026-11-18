# Wordlit

**在语境里理解，然后继续阅读。**

Wordlit is the new public name of Dictionary. The product remains a native macOS
English reading companion: contextual word lookup, complete sentence/paragraph
translation and click-to-play American English speech.

## Visual identity

![Wordlit](wordlit-wordmark.svg)

The original mark combines a rounded W with a small warm light. Forest green
retains continuity with the previous app; ivory keeps the mark readable; a restrained
gold accent expresses “lit”. Do not add the old `d.` or change the W into text at
small sizes. The mark has a transparent margin for native app-icon placement.

| Element | Value |
| --- | --- |
| Product / application | Wordlit / `Wordlit.app` |
| Repository target | `liyunhui0707/wordlit` (rename the existing repository) |
| New checkout directory | `wordlit` |
| Future release files | `Wordlit-<version>-macOS-<architecture>.dmg` and `.zip` |
| Companion display name | Wordlit Lookup |
| Accent | `#386751` / `#254C3B` |
| Paper / mark | `#FCFCF4` |
| Light accent | `#EBCB86` |
| Typography | Native system UI; serif word/brand display |

`scripts/generate-brand-assets.swift` is the editable, dependency-free artwork
source. Run it from the project root on macOS with `xcrun swift
scripts/generate-brand-assets.swift`. It creates the SVG marks, 1024px PNG, native
ICNS, extension icons, website favicons and a local preview under
`build/branding.noindex/`. It never opens windows, plays audio or downloads assets.
The artwork is original project material under the repository's MIT license.

## Compatibility is part of the rename

Public branding is separate from existing storage and protocol identity:

- Retain `com.liyunhui.DictionaryApp`, its testing counterpart, preference keys,
  Keychain service names, token location and local connection port. A new brand
  must not manufacture an empty user profile or ask users to pair again.
- Retain the internal `DictionaryApp` Swift module and packaged executable name.
  The Swift package/product is Wordlit; implementation namespaces are not branding.
- Retain the Obsidian plugin ID, browser command IDs and extension storage keys.
  Extension version numbers are unchanged for this branding-only source group;
  a future published extension update must follow its own version policy.
  An already-loaded Dictionary Lookup keeps working through the unchanged protocol;
  no reload or pairing is required just to upgrade the app. Exporting to a new
  folder can create a different Chromium extension identity, so it is not claimed
  to preserve browser pairing or shortcuts. Do not force that step during the rename.
- The updater accepts only the two exact first-party repository paths and both
  artifact prefixes. On a rename response it may try the fixed new API endpoint;
  it never follows an arbitrary redirect. New artifacts are preferred when present.
- Frozen pre-rename archives remain inspectable. Historical release notes, hashes,
  filenames, synthetic acceptance book titles and previously published assets
  stay unchanged. A historical Dictionary binary is never relabelled Wordlit.
- Preserve the local checkout path during the active session. A fresh clone may
  use `wordlit`; moving this checkout requires a separate workspace transition.

## Public cutover order

This branch prepares branding; it does not declare a new release. `VERSION`
remains 0.10.0; the current public 0.10.0 artifacts are still Dictionary.

1. Review and integrate the brand/compatibility change through the normal PR and CI.
2. Choose the next release version explicitly; build and verify its Wordlit artifacts.
3. Upgrade the daily apps from the approved candidate, retaining rollback and signing
   continuity. Do not run Dictionary and Wordlit simultaneously: they share identity
   and the same singleton connection port. Do not reset permissions during migration.
4. Rename the existing GitHub repository to `wordlit`, preserving history, issues,
   tags and Releases. Never recreate or reuse `dictionary-macos`: that would break
   GitHub's redirect. Update the clone remote, README/app links and website links.
5. Publish the accepted Wordlit release and sync the existing website identity.
   Old app updaters may reject renamed release URLs, so provide the browser/manual
   upgrade path in the old release notes before cutover; redirects alone are insufficient.

Repository rename, push/merge, website deployment and daily-app installation are
distinct external operations. None has been performed by preparing this branch.
No automatic installation, model change or new permission is introduced.
