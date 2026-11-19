# Sidra: notes for coding agents

Sidra is a native SwiftUI app for iPad and iPhone (iOS 26+). One workspace of pane cards under a title
bar of pill tabs. The public baseline has six tab kinds: herdr, SSH host, Theasa, Pipelines (GitLab),
HackerTab and Chess. New tab kinds are added one by one; each kind runs its own setup from the
"+" sheet (`Sidra/Panes/NewTab.swift`). There is no global onboarding.

## Build and test

- `xcodegen generate` after any change to `project.yml`; the `Sidra` scheme runs on any iPad or iPhone simulator.
- Pass `-skipPackagePluginValidation -skipMacroValidation` to `xcodebuild`.
- Unit tests: `-skip-testing:SidraUITests`. UI tests drive the new-tab cards (`newtab-<kind>` identifiers).
- `-sidra.demo` (Debug, simulator) fills every tab with made-up data from `Sidra/Demo/DemoMode.swift`.
- `tools/store-shots.sh` makes the App Store screenshots; `tools/testflight.sh` uploads a build;
  `tools/asc.rb` drives App Store Connect (`store/metadata.md` holds the listing text).
- Mac app (`SidraMac`): every push to main is a release. `.github/workflows/release-mac.yml` builds it, signs it with
  Developer ID, notarizes it and publishes a DMG plus a Sparkle `appcast.xml` as a GitHub release (`mac-v<version>.<commits>`).
  `tools/package-mac.py --identity <Developer ID> [--notary-profile sidra]` does the same locally; `tools/release-secrets` sets the CI secrets.

## Design system (Packages/SidraDesign)

- Ground `#0c0e12`, pane `#12151a`, raised `#191e25`, hairline `rgba(255,255,255,.065)`.
- Text `#d9dde3`, muted `#828b98`, dim `#5a626e`. Jade `#5ad6a0` is status and primary buttons.
- The gradient (`SidraGradient`) is for selection and progress only.
- Process icons are flat solid squares. Inter for UI, JetBrains Mono for terminals.
- Use the tokens and catalog components; a raw colour or radius needs a reason.

## Rules

- Secrets go to the Keychain, never to UserDefaults or the repo.
- Every platform-risky subsystem sits behind a protocol with a fake for tests.
- Public repo: no personal names, hosts, tokens or client data in code, tests or fixtures.
- Copy (README, site, store text, UI strings) follows plain STE-style English: active voice, short
  sentences, no em dashes.
