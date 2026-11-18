# Dictionary website

Buildless static site in `dist/`. No dependencies, analytics, cookies or API keys.
The interactive bank examples are explicitly labelled illustrations, not live model responses.
`reading-check.html` provides selectable synthetic reading passages and optional answer hints,
without simulated popups, scripts or model calls. Actual lookups are initiated through the installed extension.
Download and update links point to the public repository's Releases page. Do not
add an installation download or version claim until the matching artifact is published.

Before the Sites source helper commits, set the checkout-local public Git identity
explicitly; do not inherit a machine-wide email. Deployment archives contain only
the static output and hosting manifest, never Git history or local evidence.

The tab favicon reuses the native `Sources/DictionaryApp/Resources/AppIcon.icns`
artwork: `dist/favicon.ico` contains 16, 32 and 64 pixel frames, with an explicit
32 pixel PNG alternative. Keep these assets aligned when the app logo changes.

Preview: `python3 -m http.server 8080 --directory website/dist`.
