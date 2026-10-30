# Notices

Remote Display — Copyright © 2026 Samuel Rioja.
Licensed under the GNU Affero General Public License, version 3 (see `LICENSE`).

## Third-party software

- **RustDesk** — https://github.com/rustdesk/rustdesk — Copyright © RustDesk
  contributors, licensed under the GNU AGPL-3.0. `engine/rustdesk/` is a modified
  copy of RustDesk 1.4.9; the modifications are documented in `engine/SYNC.md` and
  `HOOKS.md`, and `bash engine/diff.sh` prints the complete diff against upstream.
  Remote Display is not affiliated with or endorsed by RustDesk.
- **BlackHole** — https://github.com/ExistentialAudio/BlackHole — Copyright ©
  Existential Audio Inc., licensed under the GNU GPL-3.0, which section 13 of the AGPL-3.0
  lets us combine with. `server-mac/AudioDriver/BlackHole/` is BlackHole.c and its LICENSE at
  v0.7.2 (commit `561d934`), unmodified; Remote Display Microphone is built from it with our
  own names and constants. Its LICENSE reserves the BlackHole name and branding, which
  Remote Display Microphone doesn't use. Remote Display is not affiliated with or endorsed
  by Existential Audio.
- The Flutter, Rust and other third-party dependencies keep their own licenses; see
  the respective `pubspec.yaml`, `Cargo.toml` and license files in the tree.
