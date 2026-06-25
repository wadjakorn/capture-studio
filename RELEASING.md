# Releasing Capture Studio

Modeled on the `capz` release flow: a **free self-signed** code identity, a
tag-triggered CI build that signs + packages a `.dmg` into a GitHub Release, and
a Homebrew cask that auto-bumps. No Apple Developer Program required for this
tier — but it does **not** notarize (see [Limitations](#limitations)).

## Pieces

| File | Role |
| --- | --- |
| `scripts/bump-version.sh` | Set marketing version (`CFBundleShortVersionString`) in `Resources/Info.plist`. |
| `scripts/release.sh` | Bump + commit + tag (no push). Pushing the tag drives CI. |
| `scripts/setup-signing-cert.sh` | One-time: generate a self-signed cert, push it to GitHub Actions secrets. |
| `scripts/build-app.sh` | Build `dist/CaptureStudio.app`, sign with `Capture Studio Dev`, stamp build number. |
| `scripts/make-dmg.sh` | Wrap the `.app` in a drag-to-Applications `.dmg`. |
| `.github/workflows/build.yml` | On tag push: import cert, build, dmg, draft GitHub Release. |
| `.github/workflows/update-cask.yml` | On release publish: bump the Homebrew tap cask. |

## One-time setup

1. **Signing cert → secrets.** On your Mac, in this repo:
   ```sh
   scripts/setup-signing-cert.sh
   ```
   Sets `APPLE_CERTIFICATE`, `APPLE_CERTIFICATE_PASSWORD`, `APPLE_SIGNING_IDENTITY`.
   Identity name is `Capture Studio Dev` — same as your local cert, so TCC grants
   persist across local and CI builds.

2. **Homebrew tap (optional, for `brew install`).** Create a public repo
   `wadjakorn/homebrew-capture-studio` with `Casks/capture-studio.rb`:
   ```ruby
   cask "capture-studio" do
     version "0.1.0"
     sha256 "0000000000000000000000000000000000000000000000000000000000000000"

     url "https://github.com/wadjakorn/capture-studio/releases/download/v#{version}/CaptureStudio-#{version}.dmg"
     name "Capture Studio"
     desc "Menu-bar screen recorder and editor"
     homepage "https://github.com/wadjakorn/capture-studio"

     app "CaptureStudio.app"

     zap trash: [
       "~/Library/Preferences/dev.wadjakorn.capture-studio.plist",
     ]
   end
   ```
   Then add an `HOMEBREW_TAP_TOKEN` secret to this repo: a fine-grained PAT with
   **Contents: write** on the tap repo. `update-cask.yml` patches `version` +
   `sha256` on every release.

## Cutting a release

```sh
scripts/release.sh minor        # 0.1.0 -> 0.2.0, commits + tags v0.2.0
git push --follow-tags          # triggers .github/workflows/build.yml
```

CI then:
1. Imports the self-signed cert and builds `dist/CaptureStudio.app` (signed).
2. Builds `dist/CaptureStudio-<version>.dmg`.
3. Creates a **draft** GitHub Release with the dmg attached.

Review the draft, then **Publish** it. Publishing fires `update-cask.yml`, which
bumps the tap so `brew upgrade --cask capture-studio` picks it up.

Users install via:
```sh
brew install --cask wadjakorn/capture-studio/capture-studio
```

## Versioning

- **Marketing version** (`CFBundleShortVersionString`) — semver, the source of
  truth, bumped by `release.sh`. This is the dmg/tag/cask version.
- **Build number** (`CFBundleVersion`) — git commit count, stamped at package
  time in `build-app.sh`. Always increases; never hand-edited.

## Limitations

- **No notarization.** A direct `.dmg` download shows the macOS "unverified
  developer" prompt (right-click → Open clears it). The **Homebrew** path is
  clean because `brew` strips the quarantine flag. Removing the prompt for direct
  downloads needs a paid Apple Developer ID + notarization.
- **Apple-silicon only** for now (the `macos-15` runner builds `arm64`). For a
  universal build, switch `build-app.sh` to `swift build --arch arm64 --arch
  x86_64` and adjust the binary path.
- **No in-app auto-update.** capz gets this from Tauri's updater; the equivalent
  here would be the Sparkle framework (a separate addition).
