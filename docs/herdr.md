# Patch herdr for Sidra

Instructions for a coding agent (Claude Code, Codex or similar) on the machine that runs herdr.
A person can follow them too.

The result is a herdr client with one patched line at `~/.local/share/sidra/herdr-client`.
Sidra uses it to hide herdr's tab row, because Sidra shows those tabs as chips.
The patch is optional, and the installed `herdr` stays as it is.

## 1. Check the requirements

Run every step as the user that Sidra signs in as over SSH.

```sh
herdr --version && git --version && cargo --version && curl --version | head -1
```

All four must print a version. herdr's build also needs the Zig version from herdr's build instructions.
If `zig` is not on `PATH`, set it for the build:

```sh
export ZIG=/path/to/zig
```

If herdr is missing, install it first: `curl -fsSL https://herdr.dev/install.sh | sh`.

## 2. Build and install

With a checkout of this repository:

```sh
sh tools/herdr-client.sh
```

Without a checkout, download the script, read it, then run it:

```sh
curl -fsSL -o /tmp/herdr-client.sh https://raw.githubusercontent.com/Kunba-Labs/sidra/main/tools/herdr-client.sh
sh /tmp/herdr-client.sh
```

The script clones herdr at the tag of the installed version, patches one line, runs
`cargo build --release` and installs the binary. The build takes a few minutes.

## 3. Verify

These two lines must print exactly the same text:

```sh
~/.local/share/sidra/herdr-client --version
herdr --version
```

Report to the user: the installed path, the two version lines, and that they match.
Then ask the user to close the herdr tab in Sidra, open it again, and look at a space with
two or more tabs. herdr's own tab row is gone. (A space with one tab never shows the row.)

## 4. If a step fails

Report the herdr version and the full error to the user. Do not report success.
Sidra then uses the stock herdr client, so nothing breaks.

| Error | Cause and fix |
| --- | --- |
| `tab-bar line not found; patch needs updating` | This herdr version changed the patched line. Open an issue on Kunba-Labs/sidra with the herdr version. |
| `Remote branch v… not found` during the clone | The installed herdr has no release tag. Install a released herdr, then run step 2 again. |
| A Zig error during `cargo build` | Install the Zig version from herdr's build instructions, `export ZIG=/path/to/zig`, and run step 2 again. |

## The patch

herdr's `src/client/shell/config.rs` has this line:

```rust
let show_tab_bar = rows > 1 && …
```

The patch adds one condition. The tab row stays hidden while `SIDRA_HIDE_TAB_BAR` is set:

```rust
let show_tab_bar = rows > 1 && std::env::var_os("SIDRA_HIDE_TAB_BAR").is_none() && …
```

Sidra's attach script sets `SIDRA_HIDE_TAB_BAR` and runs the patched client only while its version
matches the installed herdr. After a herdr upgrade, Sidra uses the stock client until you run step 2 again.

## Undo

```sh
rm ~/.local/share/sidra/herdr-client
```

herdr is open source under the Apache 2.0 license.
