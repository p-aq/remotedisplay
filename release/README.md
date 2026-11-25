# release/ — Remote Display binaries

> **Current version: 1.0.16** (source of truth: `version:` in `client/pubspec.yaml`; it's
> reflected here, in the main README, and in the `v<version>` tag).
>
> **Version bump**: only when explicitly requested. When requested, the number changes
> in `client/pubspec.yaml` (`version: X.Y.Z+N`), in the main README and in this line, and
> the next release uses the new tag. If not requested, the current version is reused (the
> artifacts are re-uploaded/updated to the existing Release with `--clobber`).

Binaries go to **GitHub Releases** of the (private) repo, tag `v<version>`. No
binaries in git (`release/out/` is in .gitignore).

## Artifacts and how they're produced

| Artifact | Built on | Command |
|---|---|---|
| `RemoteDisplay-Setup-<ver>.exe` (Inno) + `RemoteDisplay-<ver>-windows-x64-portable.zip` | Windows PC | `release/release-windows.ps1 -Upload` |
| `RemoteDisplay-<ver>-android-arm64.apk` | Mac | `release/release-mac.sh` |
| `RemoteDisplay-<ver>-macos-client.dmg` | Mac | `release/release-mac.sh` |
| `RemoteDisplay-Server-<ver>-macos.dmg` | Mac | `release/release-mac.sh` |
| `RemoteDisplay-<ver>-ios.ipa` | Mac | `release/release-mac.sh` |

## Full release flow

1. Bump `version:` in `client/pubspec.yaml` and in the main README, commit+push.
2. **Windows PC**: `powershell -ExecutionPolicy Bypass -File release/release-windows.ps1 -Upload`
   (builds, validates, creates the `v<ver>` Release and uploads zip+installer). Over a
   non-interactive SSH session `gh` on the PC may be unauthenticated (401): then fetch the
   two files from `release\out` with `scp` and upload them from the Mac
   (`gh release upload v<ver> <files> --repo p-aq/remotedisplay`).
   Requires an up-to-date engine DLL (`engine/rustdesk/target/release/librustdesk.dll`,
   recipe in `tools/README.md`).
3. **Mac** (run by the Mac's Claude or Sam; codesign needs the graphical session):
   `git pull && bash release/release-mac.sh [--upload]` → builds the 4 artifacts into
   `release/out/`; with `--upload` it also uploads them to the `v<ver>` Release (creates it if it doesn't exist).
   The three Flutter builds (macOS client, iOS, Android) need **Rosetta**: Flutter 3.24.5's host tools
   (`gen_snapshot`) are x86_64. macOS 27 came without it (1.0.13 shipped server + Windows first for that
   reason); `softwareupdate --install-rosetta --agree-to-license` brings it back (on macOS 27.0 it ran
   without sudo). Without Rosetta, `--skip-client --skip-ios --skip-android` still builds and notarizes
   the server DMG. Xcode 27 notes (2026-10-06): deployment targets must be ≥ 12.0 (macOS) / 15.0 (iOS),
   set in the two Podfiles and Runner projects; the client dylib is linked unstripped and stripped with
   Xcode's `strip -x` (rustc's strip mis-aligns the LINKEDIT string pool and Xcode 27's `ld` refuses it).
   The Mac's `gh` must be authenticated as an account that can publish to the release repo
   (`RD_RELEASE_REPO`, by default `p-aq/remotedisplay`); then it uploads directly — step 4 (fetch
   from Windows) is only an alternative if it can't. All three scripts publish to the same repo,
   and the one that creates the `v<ver>` release tags the commit it built (`--target`), so the
   release's source archives match its binaries: build from a pushed commit, and from the same
   commit on both machines.
   With the Developer ID identity present the two DMGs come out notarized and stapled
   (about 2–5 minutes per submission; `--skip-notarize` for a quick local build).
   - Server's `ENGINE_BIN`: defaults to `engine/rustdesk/target/release/rustdesk` (the monorepo's
     engine binary, already with the serverless patches). Pass another path if you want.
4. **Windows PC** (alternative, if the Mac doesn't have `gh`): `release/release-fetch-mac.ps1` —
   fetches the artifacts from the Mac via scp and uploads them to the same Release.

## Signing and notarization (Mac)

- Team: `server-mac/team-id.sh` says which Apple team signs:
  - `RD_TEAM_ID` from the environment (also inside `release-mac.sh`, which sources `signing.env`);
  - else from `~/.config/remotedisplay/signing.env`;
  - else the original project's team, K45698KZ4W.

  A fork sets its own team in `signing.env` and never commits it. The Makefile and
  `release-mac.sh` pass it on: it goes into the server's designated requirement and its
  entitlements. A `SIGN_ID=` override with another team's certificate would break that
  requirement: `make sign` then fails at its `codesign --verify -v`.
  iOS keeps the Xcode project's team (`DEVELOPMENT_TEAM` in `client/ios/Runner.xcodeproj`, used by
  `tools/build-ios.sh`): a fork with another team changes it there, or runs `--skip-ios`.
- Identity: `server-mac/sign-identity.sh` picks that team's *Developer ID Application*
  certificate, else its *Apple Development* one. Never another team's certificate.
- `signing.env` (mode 600, sourced by `release-mac.sh`) holds:
  - `RD_TEAM_ID`;
  - `RD_SIGNING_KEYCHAIN` and `RD_SIGNING_KEYCHAIN_PASSWORD`, for a dedicated keychain;
  - `RD_NOTARY_PROFILE`, by default `remotedisplay-notary`;
  - `RD_SERVER_PROFILE` and `RD_CAMERA_PROFILE`: the Developer ID provisioning profiles for
    `app.remotedisplay.server` and `app.remotedisplay.server.camera`. Without both, the
    server ships without the camera extension;
  - `RD_RELEASE_REPO`, by default `p-aq/remotedisplay`, where `--upload` publishes (the Windows
    scripts take the same variable, or `-Repo`). The apps' update checks are compiled in
    (`client/lib/update_check.dart`, `server-mac/.../ServerController.swift`): publishing
    elsewhere means changing those too.
- The Developer ID identity is kept in a dedicated keychain,
  `~/Library/Keychains/remotedisplay-signing.keychain-db`, unlocked for `codesign` without
  prompts (`security set-key-partition-list`) and listed in the user search list. Its
  password and the notary profile name are in `~/.config/remotedisplay/signing.env`
  (mode 600, outside the repo; `release-mac.sh` sources it if present). The keychain locks on
  every reboot; `server-mac/unlock-signing-keychain.sh` (run by the release script, the client
  build script and `make sign`) unlocks it, otherwise codesign shows a password dialog and the
  build hangs. The identity was
  imported from Sam's private backup of the certificate and key; nothing of it is in this
  repository.
- Notarization uses `xcrun notarytool --keychain-profile remotedisplay-notary`, an App
  Store Connect API key stored with `notarytool store-credentials`. Apps are submitted as
  zips and stapled, then the DMG is signed, submitted and stapled too; the script fails on
  anything but `Accepted` and prints Apple's log. `spctl` must report
  `source=Notarized Developer ID`.
- The macOS server signs with an explicit designated requirement (identifier + team), so a
  development build and a notarized build share the TCC grants; see `server-mac/README.md`.

## Installing the IPA on the iPad/iPhone

The `.ipa` is signed with the development certificate (team K45698KZ4W) — Sam's
devices are already in the profile. From the Mac, with the device connected
and unlocked:

```sh
xcrun devicectl list devices            # UDID
xcrun devicectl device install app --device <UDID> RemoteDisplay-<ver>-ios.ipa
```

(Also: drag it onto the device in Finder, or Apple Configurator.)
The development signature expires: reinstall when the profile lapses.

## Notes

- The Windows portable ZIP runs from any folder without installing; the config
  lives in `%APPDATA%\RemoteDisplay` (older 0.x builds used `%APPDATA%\RustDesk`; that folder can be deleted).
- Installer validated with silent install/uninstall (`/VERYSILENT`).
- The release scripts pass `--repo` to every `gh release` call. For other `gh` commands, point
  `gh` at this repo: it's a fork, and unconfigured `gh` resolves to the parent
  (`gh repo set-default p-aq/remotedisplay`; run it again after a reclone).
