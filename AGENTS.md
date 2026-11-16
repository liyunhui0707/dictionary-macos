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

## Git workflow

- Start each development group on a topic branch from the current `main`; do not
  accumulate development edits on `main`. Preserve existing uncommitted work when
  moving it to a topic branch.
- Commit reviewed, tested logical changes as checkpoints during development.
  Keep code with its regression tests; keep independent QA findings or workflow
  changes in separate commits when that makes review and rollback clearer.
- Integrate completed groups through a PR with relevant test evidence and honest
  acceptance limits. Require successful CI and review the final head before merge.
  Development integration does not require a version bump or authorize a release.
- Pushes, GitHub mutations and repository protection changes still require current
  task authorization. Never force-push or bypass required checks to finish a task.
- After an authorized merge, synchronize `main` safely and verify a clean worktree.
  Delete a topic branch only when cleanup is authorized and its tip is confirmed
  merged; preserve release tags and record branch tips before batch cleanup.
