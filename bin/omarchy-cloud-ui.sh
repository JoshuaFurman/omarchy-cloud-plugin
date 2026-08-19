#!/bin/bash
#
# Shared terminal presentation for the Cloud plugin's interactive scripts.
#
# Deliberately does not use omarchy-launch-floating-terminal-with-presentation.
# That wrapper opens with a large solid-colour ASCII logo, and Omarchy
# terminals are translucent by default (ghostty ships background-opacity 0.9),
# so the logo composites over whatever window is behind it and reads as
# corruption. A plain heading survives a translucent background; the logo does
# not.
#
# Sourced, not executed.

# Match gum's colours to the active theme. The compositor environment is
# captured once at login and not refreshed on a theme switch, so this re-exports
# the current values the same way Omarchy's own scripts do.
if [[ -r "$(command -v omarchy-restart-gum 2>/dev/null)" ]]; then
  # shellcheck source=/dev/null
  source omarchy-restart-gum
fi

say()  { gum style --foreground 4 "$*"; }
warn() { gum style --foreground 3 "$*"; }
bad()  { gum style --foreground 1 "$*"; }
good() { gum style --foreground 2 "$*"; }

heading() {
  echo
  gum style --bold "$*"
}

title() {
  clear
  gum style --bold --border rounded --padding "0 2" --margin "1 0" "$*"
}

# Keep the window up so the result is readable, and make closing it explicit.
# Skipped on SIGINT (130) so ctrl-c closes immediately.
hold_open() {
  local status=$?
  if ((status != 130)); then
    echo
    gum spin --spinner globe --title "Done. Press any key to close…" -- bash -c 'read -n 1 -s'
  fi
}
