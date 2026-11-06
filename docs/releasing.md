# Release process

1. Select a version explicitly. Keep the app and companion extension versions
   coordinated where necessary; do not change versions automatically for every commit.
2. Run automated checks and a consolidated Books/browser acceptance session.
   Validate target identity, contextual meaning, cancellation and missing-service recovery.
3. Build the matching architecture. Current packagers use the host architecture;
   do not label an arm64 build Universal or Intel-compatible.
4. For ordinary public installation, sign with Developer ID Application using
   hardened runtime, notarize with Apple, and staple/validate the resulting ticket.
   Apple Development and ad-hoc builds do not establish this distribution acceptance.
5. On a separate Mac/user profile, install the exact artifact without a checkout,
   Xcode or maintainer configuration. Verify model/provider setup and contextual
   lookup. Any permission consent is performed normally by that Mac's user.
6. Publish a GitHub Release with the version, tested OS/architecture, ZIP/DMG,
   SHA-256, setup requirements, notices and specific update notes. Do not publish
   unsigned test artifacts as a normal signed release.
7. The website links to the same release page and reflects the actual available
   assets. The app's update menu opens this page. Updating is currently manual:
   quit the app, replace the bundle, reopen and verify settings and permission state.

Current blockers for a normal binary release: Developer ID/notarization setup and
new-Mac end-to-end acceptance. Source publication can proceed separately with
accurate setup instructions. Do not advertise automatic in-app installation;
adding a signed updater requires a separately implemented and tested update channel.
