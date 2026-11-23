# Releasing Capture Studio

Modeled on the `capz` release flow: a tag-triggered CI build that signs +
packages a `.dmg` into a GitHub Release, and a Homebrew cask that auto-bumps.

Two signing tiers, same scripts:

- **Developer ID + notarization** (Apple Developer Program). Direct `.dmg`
  downloads open with no Gatekeeper warning. See
  [Developer ID + notarization](#developer-id--notarization).
- **Free self-signed** (`Capture Studio Dev`). No notarization; direct downloads
  show the "unverified developer" prompt (see [Limitations](#limitations)).

Every build is signed with **Hardened Runtime** and
`Resources/CaptureStudio.entitlements` (camera + microphone), so local builds
behave like the notarized release.

## Pieces

| File | Role |
| --- | --- |
| `scripts/bump-version.sh` | Set marketing version (`CFBundleShortVersionString`) in `Resources/Info.plist`. |
| `scripts/release.sh` | Bump + commit + tag (no push). Pushing the tag drives CI. |
| `scripts/setup-signing-cert.sh` | One-time: generate a self-signed cert, push it to GitHub Actions secrets. |
| `scripts/build-app.sh` | Build `dist/CaptureStudio.app`, sign with `Capture Studio Dev`, stamp build number. |
| `scripts/make-dmg.sh` | Wrap the `.app` in a drag-to-Applications `.dmg` (`create-dmg`, or plain `hdiutil` fallback). |
| `scripts/notarize.sh` | Notarize + staple a Developer ID signed `.app` or `.dmg` (signs the dmg first). |
| `scripts/package-release.sh` | Local one-shot: build → notarize app → dmg → notarize dmg. |
| `scripts/make-appcast.sh` | Write `dist/appcast.xml` (Sparkle feed, EdDSA-signed) for a release dmg. |
| `Resources/CaptureStudio.entitlements` | Hardened Runtime entitlements (camera, audio-input). |
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

## Developer ID + notarization

### One-time (local Mac)

1. Create the **Developer ID Application** cert: Xcode → Settings → Accounts →
   Manage Certificates → `+` → Developer ID Application. Check it:
   ```sh
   security find-identity -v -p codesigning   # "Developer ID Application: NAME (TEAMID)"
   ```
   Export it (with private key) from Keychain Access as a `.p12` and keep it in a
   password manager. Apple caps how many of these you can create.
2. Store notary credentials in the keychain (app-specific password from
   account.apple.com → Sign-In and Security → App-Specific Passwords):
   ```sh
   xcrun notarytool store-credentials notary \
     --apple-id <you@example.com> --team-id <TEAMID> --password <app-specific-pw>
   ```

### Local release build

```sh
CS_SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" CS_UNIVERSAL=1 \
  scripts/package-release.sh
```

Output: `dist/CaptureStudio-<version>.dmg`, notarized and stapled.

### CI (tag push)

Replace / add these repo secrets; `build.yml` notarizes automatically when the
identity is Developer ID and the API key secrets exist:

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE` | `base64 -i DeveloperID.p12` |
| `APPLE_CERTIFICATE_PASSWORD` | the `.p12` export password |
| `APPLE_SIGNING_IDENTITY` | `Developer ID Application: NAME (TEAMID)` |
| `APPLE_API_KEY` | contents of `AuthKey_XXXX.p8` (App Store Connect → Users and Access → Integrations → Team Keys, role Developer) |
| `APPLE_API_KEY_ID` | the key ID |
| `APPLE_API_ISSUER` | the issuer UUID |

CI builds **universal** (arm64 + x86_64).

### Switching identity resets permissions once

macOS keys Screen Recording / Camera / Mic grants to the code signature. The
first Developer ID build is a new identity to TCC, so users (and you) re-grant
once. Builds after that keep their grants. For local debug builds you can keep
using `Capture Studio Dev` (the default when `CS_SIGN_IDENTITY` is unset).

## Auto-update (Sparkle 2)

- The app checks
  `https://github.com/wadjakorn/capture-studio/releases/latest/download/appcast.xml`
  (`SUFeedURL` in Info.plist) daily, plus the menu's **Update** button.
- Each release uploads `appcast.xml` next to the dmg. `/releases/latest` only
  resolves to a **published, non-prerelease** release: publishing the draft is
  what ships the update. Don't mark betas as GitHub "pre-release" or
  installed apps won't see them.
- Updates are verified with an **EdDSA key**, separate from Apple's cert.
  Public key = `SUPublicEDKey` in Info.plist. Private key lives in the login
  keychain of the Mac that ran `generate_keys`.
- Sparkle compares `CFBundleVersion` (git commit count), so every release must
  come from a later commit than the previous one (always true with
  `release.sh`).

**Back up the private key — losing it means installed apps can never accept
another update** (users would have to reinstall manually):

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-private-key.txt
# store the file in your password manager, then delete it
```

CI secret: `gh secret set SPARKLE_PRIVATE_KEY < sparkle-private-key.txt`.
Without it CI still builds, but skips `appcast.xml` (with a warning).

Signing note: Sparkle.framework is embedded in `Contents/Frameworks`.
Self-signed/ad-hoc builds have no Team ID, so `build-app.sh` adds
`com.apple.security.cs.disable-library-validation` for them only; Developer ID
builds keep full library validation.

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

- **Self-signed tier only:** no notarization, so a direct `.dmg` download shows
  the "unverified developer" prompt (right-click → Open clears it). Homebrew is
  clean because `brew` strips the quarantine flag.
- **Auto-update across the signing switch:** the first Developer ID release is
  accepted by older self-signed installs via the EdDSA signature, but macOS
  will ask for Screen Recording/Camera/Mic permission again once.
