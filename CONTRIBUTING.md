# Contributing

Open an Issue describing the observed behavior, expected behavior, macOS version,
source application, provider/model, and a short synthetic sentence. Remove tokens,
private paths and personal documents from screenshots and logs.

Keep pull requests focused. For behavior changes, include relevant automated
checks and describe manual validation. Capture correctness, contextual meaning
and UI behavior are separate acceptance concerns. Do not claim universal application
support based on mocked tests. Run `swift test`, the relevant Node tests, and
`git diff --check` before proposing a change.

Release versions follow SemVer and require an explicit maintainer decision.
The current inherited build version is 0.1.0; it is not a claim that a signed public
binary has been released. Never include signing certificates, keys or local configuration.
