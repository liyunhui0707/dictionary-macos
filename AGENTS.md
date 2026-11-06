# Project guidance

This is the public Dictionary macOS repository. Keep the accepted native interface
and prioritize reliable target/context capture and useful contextual explanations.

- Never include credentials, personal paths, real user documents, machine inventories,
  private chat logs, signing identities or certificates in commits or release assets.
- Use synthetic samples for tests and screenshots. Do not read protected secret files.
- Run focused checks, then relevant regression before delivery. Automated capture
  tests do not prove semantic quality or support in every application.
- Keep version changes explicit and follow the release process in docs/releasing.md.
- Never reset Accessibility permission as a routine build step. Preserve signing identity.
- Respect third-party notices. Do not relabel model output as a dictionary definition.
- Website source lives in website/dist. Releases are the canonical download/update
  channel. The app opens that page for manual updates; no automatic installer exists.
- .local/ is ignored, private continuity/evidence only. Do not publish its content.
