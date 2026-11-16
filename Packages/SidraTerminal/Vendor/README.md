# Vendor — libghostty-vt

Prebuilt `ghostty-vt.xcframework` (VT emulation core, C ABI) for SidraTerminal's GhosttyVT engine.
Licence: MIT (see `LICENSE-ghostty`). Ghostty © Mitchell Hashimoto and contributors.

## Provenance

| | |
| --- | --- |
| Source | https://github.com/ghostty-org/ghostty |
| Commit | `eb895f6128dba382ffeb5fedea97dcd61fcb5979` (main, 2026-11-08) |
| libghostty-vt version | 1.1.0 (dylib `libghostty-vt.1.1.0`) |
| Zig | 0.17.1 (Homebrew; `minimum_zig_version` in `build.zig.zon` is 0.17.0) |
| Xcode / SDKs | Xcode 27.2 (27B52) |
| Build command | `zig build -Demit-lib-vt -Demit-xcframework=true -Doptimize=ReleaseFast` (from repo root; ~3.5 min on M-series) |
| Output | `zig-out/lib/ghostty-vt.xcframework` |

Slices (`plutil -p ghostty-vt.xcframework/Info.plist`):

| LibraryIdentifier | Arch | Library | min OS |
| --- | --- | --- | --- |
| `ios-arm64` | arm64 | `libghostty-vt-fat.a` | iOS 13.0 |
| `ios-arm64-simulator` | arm64 | `libghostty-vt-fat.a` | iOS Simulator 14.0 |
| `macos-arm64_x86_64` | arm64 + x86_64 | `libghostty-vt.a` | macOS |

Total 52 MB (static, 13 MB per iOS slice). iOS slices are emitted automatically when the iOS SDK is detected
(`src/build/GhosttyLibVt.zig: initStaticAppleUniversal`). tvOS/watchOS/visionOS are not supported by Zig's std yet.

To rebuild: clone ghostty, `brew install zig` (must be 0.17.x), run the build command, copy `zig-out/lib/ghostty-vt.xcframework` here.

## Swift integration

Each slice ships `Headers/module.modulemap` (`module GhosttyVt { umbrella header "ghostty/vt.h" }`), so in
`Package.swift` add `.binaryTarget(name: "GhosttyVt", path: "Vendor/ghostty-vt.xcframework")` and `import GhosttyVt`.
`example/main.swift` is upstream's minimal Swift example (create terminal, write VT, format screen as text);
`example/c-vt-render-main.c` is upstream's C renderer walkthrough and the best reference for the render loop below.

## C API surface for a renderer

Headers live under `Headers/ghostty/vt/`: `terminal.h` (129 KB), `render.h`, `screen.h`, `style.h`, `color.h`,
`key/encoder.h`, `key/event.h`, `selection.h`, `grid_ref.h`, `formatter.h`, `kitty_graphics.h`.
Everything is an opaque handle plus `_get(handle, DATA_ENUM, &out)` / `_set(handle, OPT_ENUM, &in)` accessors returning
`GhosttyResult` (`GHOSTTY_SUCCESS`, `GHOSTTY_NO_VALUE`, ...). Structs tagged "sized" must be initialised with
`GHOSTTY_INIT_SIZED(T)`. First arg `NULL` = default allocator.

1. **Lifecycle:** `ghostty_terminal_new(alloc, &term, cols, rows)` / `ghostty_terminal_free(term)` / `ghostty_terminal_reset`.
2. **Input bytes:** `ghostty_terminal_vt_write(term, bytes, len)` (void) and `ghostty_terminal_vt_write_until(...)` to stop at stream boundaries.
3. **Replies to the PTY** (DSR, DECRQM, etc.): set `GHOSTTY_TERMINAL_OPT_WRITE_PTY` to a `GhosttyTerminalWritePtyFn` callback (+ `OPT_USERDATA`); NULL ignores them. Other callbacks: `OPT_TITLE_CHANGED`, `OPT_BELL`, `OPT_CLIPBOARD_WRITE`, `OPT_PWD_CHANGED`, `OPT_RESIZE_WINDOW`.
4. **Resize:** `ghostty_terminal_resize(term, cols, rows, cell_width_px, cell_height_px)`; `OPT_SCROLLBACK_MAX_BYTES` / `OPT_SCROLLBACK_MAX_LINES` cap scrollback.
5. **Scrollback / viewport:** `ghostty_terminal_scroll_viewport(term, GhosttyTerminalScrollViewport{top|bottom|delta})`; read `DATA_SCROLLBACK_ROWS`, `DATA_TOTAL_ROWS`, `DATA_VIEWPORT_ACTIVE`, `DATA_SCROLLBAR`.
6. **Render state** (snapshot of one frame): `ghostty_render_state_new(alloc, &rs)`; per frame `ghostty_render_state_update(rs, term)` (or `begin_update`/`end_update`), then read, then `ghostty_render_state_clean(rs)`. Optional `GHOSTTY_RENDER_STATE_OPT_OVERSCAN` captures rows above/below the viewport for smooth scrolling.
7. **Dirty tracking:** `ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_DIRTY, &d)` gives `FALSE | PARTIAL | FULL`. Per row: `GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY` (bool) or iterate only dirty rows with `ghostty_render_state_row_iterator_next_dirty(it, &y)`. `clean()` resets global and row flags; row data is invalid after the next `update`.
8. **Rows:** `ghostty_render_state_row_iterator_new(alloc, &it)` once, then `ghostty_render_state_get(rs, DATA_ROW_ITERATOR, &it)` per frame; `row_iterator_next(it, &y)` walks top to bottom. Row data: `ROW_DATA_ID` (stable row id, use as cache key), `ROW_DATA_VIEWPORT_Y`, `ROW_DATA_SELECTION` (row-local inclusive `start_x..end_x`, or `GHOSTTY_NO_VALUE`), `ROW_DATA_CELLS_RAW` (borrowed `GhosttyCellsView {ptr,len}` for zero-call-per-cell loops).
9. **Cells:** `ghostty_render_state_row_cells_new(alloc, &cells)` once; `row_get(it, ROW_DATA_CELLS, &cells)` per row; `row_cells_next(cells)` / `row_cells_select(cells, x)`. Cell data via `row_cells_get(cells, ENUM, &out)`:
   `GRAPHEMES_LEN` (0 = empty cell), `GRAPHEMES_BUF` (`GhosttyCodepointBuffer{ptr,cap,len}` of UTF-32 codepoints, first is the base), `GRAPHEMES_UTF` (UTF-8 into `GhosttyBuffer`), `STYLE` (`GhosttyStyle`), `FG_COLOR` / `BG_COLOR` (palette-resolved `GhosttyColorRgb {r,g,b}`, `GHOSTTY_NO_VALUE` = use terminal default), `SELECTED` (bool), `HAS_STYLING` (bool, skip style fetch when false), `RAW` (`GhosttyCell`).
10. **Wide chars:** on the raw cell, `ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &w)` -> `GhosttyCellWide`: `NARROW`, `WIDE` (draw at 2 cells), `SPACER_TAIL` (do not render), `SPACER_HEAD` (soft-wrap filler). Also `CELL_DATA_CODEPOINT`, `HAS_TEXT`, `HAS_HYPERLINK`, `CONTENT_TAG`, `STYLE_ID`.
11. **Style struct** (`style.h`): `GhosttyStyle { fg_color, bg_color, underline_color: GhosttyStyleColor{tag: NONE|PALETTE|RGB, value}; flags: GhosttyStyleFlags; }`. Flags: `BOLD, ITALIC, FAINT, BLINK, INVERSE, INVISIBLE, STRIKETHROUGH, OVERLINE`; underline style via `GHOSTTY_STYLE_UNDERLINE(style)` macro (none/single/double/curly/dotted/dashed).
12. **Colors:** `ghostty_render_state_get(rs, DATA_COLORS, &c)` -> `GhosttyRenderStateColors { background, foreground, cursor, palette[256] }` (sized struct); or individual `DATA_COLOR_BACKGROUND/FOREGROUND/CURSOR/PALETTE`. Set theme with `GHOSTTY_TERMINAL_OPT_COLOR_SCHEME` / `OPT_COLOR_PALETTE` / `OPT_COLOR_FOREGROUND/BACKGROUND/CURSOR`.
13. **Cursor:** `ghostty_render_state_get(rs, DATA_CURSOR, &cur)` -> `GhosttyRenderStateCursor { visible, viewport_has_value, viewport_x, viewport_y, visual_style: BAR|BLOCK|UNDERLINE|BLOCK_HOLLOW, blinking, wide_tail }` (sized); `DATA_CURSOR_PASSWORD_INPUT` separately. `OPT_DEFAULT_CURSOR_STYLE` / `OPT_DEFAULT_CURSOR_BLINK` set defaults.
14. **Selection:** `ghostty_terminal_grid_ref(term, GhosttyPoint{ACTIVE|VIEWPORT|SCREEN, x, y}, &ref)` twice, then `ghostty_terminal_set(term, OPT_SELECTION, &GhosttySelection{start,end,rectangle})`; read `DATA_SELECTION`. `ghostty_terminal_grid_ref_track` keeps refs valid across scroll. Extract text with `formatter.h` (`ghostty_formatter_terminal_new` + `OPT_SELECTION` + `format_alloc`).
15. **Key encoding:** `ghostty_key_event_new(alloc, &ev)`; `set_action(PRESS|RELEASE|REPEAT)`, `set_key(GhosttyKey)`, `set_mods`, `set_utf8(GhosttyString)` / `set_unshifted_codepoint`, `set_composing`. `ghostty_key_encoder_new(alloc, &enc)`; `ghostty_key_encoder_set_from_terminal(enc, term)` each frame (picks legacy vs Kitty protocol, cursor-key/keypad modes); `ghostty_key_encoder_set(enc, OPT_MACOS_OPTION_AS_ALT|..., &v)`; `ghostty_key_encoder_encode(enc, ev, buf, buf_len, &written)` -> bytes for the PTY.
16. **Paste / mouse / focus:** `ghostty_terminal_paste(term, bytes, len, ...)` applies bracketed-paste; `mouse.h` / `focus.h` encode mouse reports and focus events honouring `DATA_MOUSE_TRACKING`.
17. **Images:** `DATA_IMAGE_ITERATOR` + `ghostty_render_state_image_iterator_next` / `image_get(...)` yield Kitty graphics placements (`IMAGE_ID`, `VIEWPORT_ROW/COL`, `PIXEL_WIDTH/HEIGHT`, `SOURCE_*`, `Z`, `LAYER`); image bytes via `kitty_graphics.h`. `DATA_IMAGE_PLACEMENTS_GENERATION` tells you when to re-upload textures.
18. **Memory:** `DATA_MEMORY_USAGE`, `ghostty_terminal_compress` (compress cold scrollback), `OPT_KITTY_IMAGE_STORAGE_LIMIT`. Relevant for the iPad memory budget (M5).
19. **Allocation:** every `_new` takes a `GhosttyAllocator*` (NULL = libc); `ghostty_free(alloc, ptr, len)` frees buffers from `*_alloc` helpers.
20. **Threading:** no internal locking. Guard the terminal with a lock shared by the IO (bytes in) and render threads. `ghostty_render_state_begin_update(rs, term)` is the only call that needs the terminal, so hold the lock for it alone, release, then `ghostty_render_state_end_update(rs)` and read on the render thread until the next update.
