#!/bin/sh
# Builds Sidra's herdr client for this machine: the installed herdr's version with one patched line, so
# the tab row stays hidden while SIDRA_HIDE_TAB_BAR is set (Sidra draws the tabs as chips). Installs it at
# ~/.local/share/sidra/herdr-client, which herdr-attach.sh uses while its version matches herdr's.
# Needs cargo, git and the Zig version herdr's build asks for (set ZIG=/path/to/zig if it is not on PATH).
# Run again after upgrading herdr. herdr is Apache-2.0.
set -eu
v=$(herdr --version | awk '{print $2}')
src=$(mktemp -d)
trap 'rm -rf "$src"' EXIT
git -c advice.detachedHead=false clone -q --depth 1 --branch "v$v" https://github.com/herdrdev/herdr "$src"
f="$src/src/client/shell/config.rs"
grep -q 'let show_tab_bar = rows > 1 && ' "$f" || { echo "herdr $v: tab-bar line not found; patch needs updating" >&2; exit 1; }
sed 's/let show_tab_bar = rows > 1 && /let show_tab_bar = rows > 1 \&\& std::env::var_os("SIDRA_HIDE_TAB_BAR").is_none() \&\& /' "$f" > "$f.new" && mv "$f.new" "$f"
(cd "$src" && cargo build --release --quiet)
mkdir -p "$HOME/.local/share/sidra"
install -m 755 "${CARGO_TARGET_DIR:-$src/target}/release/herdr" "$HOME/.local/share/sidra/herdr-client"
"$HOME/.local/share/sidra/herdr-client" --version
