#!/bin/sh
# Sidra's herdr client: a herdr pane types `exec sh ~/.local/share/sidra/herdr-attach.sh [session]`.
# Sidra rewrites this file on the machine before every attach, so edit it in the Sidra repo
# (Sidra/Resources/Scripts/herdr-attach.sh), not on the machine.

# Login shells over SSH can skip the profile; add herdr's usual install paths.
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.nix-profile/bin:$PATH"
command -v herdr >/dev/null || { echo 'herdr is not installed on this machine'; exit 127; }

# Sidra draws the sidebar and the tab row itself, so its client reads a copy of config.toml with the
# sidebar collapsed to zero width, a lone tab's tab row hidden and the first-run dialog skipped.
# herdr's own phone header (below 64 columns) is off too: on an iPhone Sidra shows the space and tab itself.
# Rewritten owner-only on every attach, so edits to config.toml carry over and a private config never
# leaks. A copy herdr rejects is not used.
#
# The client also gets its own state folder: herdr saves the sidebar's open/closed state per socket and
# every client restores it, so a sidebar once opened on the Mac would override sidebar_start_collapsed
# (found 2026-11-14 in herdr's client-shell preferences). Herdr's other clients keep their sidebar.
# ponytail: the own state folder also separates the client's saved machines and plugin state; drop it once herdr scopes preferences by config path upstream
d="$HOME/.config/herdr"
own="$d/sidra-client.toml"
c="$d/config.toml"
[ -f "$c" ] || c=/dev/null
mkdir -p "$d"
if (umask 077; awk -v k='sidebar_start_collapsed = true\nsidebar_collapsed_mode = "hidden"\nhide_tab_bar_when_single_tab = true\nmobile_width_threshold = 0' '
      BEGIN { print "onboarding = false" }
      /^onboarding[[:space:]]*=/ { next }
      /^[[:space:]]*(mobile_width_threshold|hide_tab_bar_when_single_tab|sidebar_start_collapsed|sidebar_collapsed_mode)[[:space:]]*=/ { next }
      { print }
      /^[[:space:]]*\[ui\][[:space:]]*(#.*)?$/ { print k; u = 1 }
      END { if (!u) print "[ui]\n" k }' "$c" > "$own.$$" && mv -f "$own.$$" "$own") \
   && HERDR_CONFIG_PATH="$own" herdr config check >/dev/null 2>&1; then
  export HERDR_CONFIG_PATH="$own" XDG_STATE_HOME="$HOME/.local/state/sidra-herdr"
  mkdir -p "$XDG_STATE_HOME"
fi

# herdr has no setting that hides the tab row when a space has several tabs, and Sidra shows those tabs
# as chips. tools/herdr-client.sh builds this machine's herdr version with one patched line (the row
# stays hidden while SIDRA_HIDE_TAB_BAR is set) at ~/.local/share/sidra/herdr-client. It is used only
# while its version matches the installed herdr, so a herdr upgrade falls back to the stock client.
h=herdr
p="$HOME/.local/share/sidra/herdr-client"
if [ -x "$p" ] && [ "$("$p" --version 2>/dev/null)" = "$(herdr --version 2>/dev/null)" ]; then
  h="$p"; export SIDRA_HIDE_TAB_BAR=1
fi

exec "$h" ${1:+--session "$1"}
