#!/bin/bash
# Prints the Apple team that signs Remote Display. In order:
#   1. RD_TEAM_ID in the environment;
#   2. RD_TEAM_ID in ~/.config/remotedisplay/signing.env (mode 600, outside the repository,
#      release/README.md "Signing and notarization");
#   3. the original project's team, K45698KZ4W.
# A fork's own team is set in 1 or 2 and never written into the repository.
if [ -z "${RD_TEAM_ID:-}" ] && [ -f "$HOME/.config/remotedisplay/signing.env" ]; then
  RD_TEAM_ID="$(. "$HOME/.config/remotedisplay/signing.env" >/dev/null 2>&1; echo "${RD_TEAM_ID:-}")"
fi
echo "${RD_TEAM_ID:-K45698KZ4W}"
