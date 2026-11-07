# Dictionary website

Buildless static site in `dist/`. No dependencies, analytics, cookies or API keys.
The interactive bank examples are explicitly labelled illustrations, not live model responses.
Download and update links point to the public repository's Releases page. Do not
add an installation download or version claim until the matching artifact is published.

The tab favicon reuses the native `Sources/DictionaryApp/Resources/AppIcon.icns`
artwork: `dist/favicon.ico` contains 16, 32 and 64 pixel frames, with an explicit
32 pixel PNG alternative. Keep these assets aligned when the app logo changes.

Preview: `python3 -m http.server 8080 --directory website/dist`.
