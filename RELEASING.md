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

## Android companion (Capture Studio Phone)

The phone app (`android/`, package `dev.wadjakorn.capturestudio.phone`) is
released by hand, separately from the macOS CI flow, and attached to the same
GitHub Release.

1. **One-time keystore.** Create it outside the repo (or anywhere; `*.jks` under
   `android/` is git-ignored) and back it up. Losing it means phones cannot
   update in place.
   ```sh
   keytool -genkeypair -v -keystore capturestudio-phone.jks \
     -alias capturestudio-phone -keyalg RSA -keysize 2048 -validity 10000
   ```
2. **Export the signing env vars** (never commit the keystore or passwords):
   ```sh
   export CS_PHONE_KEYSTORE=/absolute/path/to/capturestudio-phone.jks
   export CS_PHONE_KEYSTORE_PASSWORD=...
   export CS_PHONE_KEY_ALIAS=capturestudio-phone
   export CS_PHONE_KEY_PASSWORD=...
   ```
   The release signing config is applied only when all four are set; otherwise
   `assembleRelease` still works and produces an unsigned APK.
3. **Build.**
   ```sh
   cd android && ./gradlew assembleRelease
   ```
   Output: `android/app/build/outputs/apk/release/app-release.apk` (with the env vars unset the file is
   `app-release-unsigned.apk`; do not publish that one).
4. **Publish.** Rename it to `CaptureStudioPhone.apk` and attach it to the GitHub
   Release next to the macOS zip/dmg.

Bump `versionCode` / `versionName` in `android/app/build.gradle.kts` for each
release. The wire **protocol major (1)** must match between the Mac app and the
phone app; on a mismatch the Mac picker shows "Update required".

**Build/test.** `cd android && ./gradlew testDebugUnitTest` runs the JVM unit
tests. Needs Java 17 and the Android SDK 34 (`ANDROID_HOME` or
`android/local.properties`); Android Studio is not required.

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
