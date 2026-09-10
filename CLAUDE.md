# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# vtirc

Minimal IRC client written in FreeBASIC on top of libvt (an SDL2-backed text-mode/TUI library). Windows + Linux (+ Mac via `__FB_MAC__`).

`PLAN.md` holds the roadmap for VTIRC 2.0 (multi-server, TLS/SASL, full command set, win32 + linux64 releases). The architecture notes below describe the current 1.23 code.

## Build

```bash
fbc vtirc.bas                 # produces ./vtirc (vtirc.exe on Windows)
fbc vtirc.bas -x /some/path   # build to a different output file
```

- All compiler flags live in the `#cmdline` line at the top of `vtirc.bas` (`-s gui -w all -arch native -gen gcc -O 3`). Keep the build warning-free under `-w all`.
- There is one compilation unit. The other `.bas` files are pulled in with `#Include Once`, so never compile or link them separately.
- There are no tests and no linter. To verify a change, compile it and run the app.

## Dependencies

- **FreeBASIC 1.10.1** (`fbc`)
- **libvt 1.9.0+**: include-only. The `vt/` folder must be either next to `vtirc.bas` or in fbc's `inc/` folder. `vtirc.bas` enables its optional modules with `VT_USE_NET`, `VT_USE_SORT` and `VT_USE_TUI` before including `vt/vt.bi`. For libvt API details (`vt_tui_*`, `vt_net_*`, form items, key macros), read its sources (`vt_tui.bi`, `vt_tui.bas`, `vt_net.bas`).
- **SDL2**: linked by libvt (`libsdl2-dev` on Linux, `SDL2.dll` next to the exe on Windows). On Linux, X11 is also linked for the taskbar-urgency notification (`IRC_LINUX_NOTIFY`).

Cloud sessions install these through `.claude/hooks/session-start.sh`.

## Runtime files

The client reads and writes everything next to the executable (`ExePath()`), not the working directory:
- `.vtirc`: plain `key=value` config. The password is stored in plaintext. If the file is missing on startup, the F2 server form opens.
- `<server>_<channel>.log` (without the `#`) and `<server>_<nick>_pm.log`: chat logs. The last `LOG_TAIL_N` lines are replayed into a channel window when it opens.

These files are gitignored user data. Don't edit or commit them.

## Architecture

**Single-threaded poll loop.** The main loop sits at the bottom of `vtirc.bas`. Each 16 ms tick (`IDLE_MS`) it runs these steps in order:
1. Auto-reconnect timer
2. `vt_inkey`
3. Menu bar (`menu_rebuild` / `menu_handle`)
4. Resize check
5. Mouse (pane listbox, focus zones, URL clicks)
6. Key handling (command history, TAB nick completion, F-keys, Enter / slash commands)
7. `irc_poll()` (non-blocking socket, split on CRLF, `irc_handle` for each line)
8. `draw_ui()`

There are no threads. All state is `Dim Shared` globals declared in `vtirc.bi`.

**Include order matters.** The order is `vt/vt.bi` → `vtirc.bi` (types, constants, globals, `Declare`s) → the body of `vtirc.bas`. The dialog files (`vtirc_help/svconfig/config/chanbrowser.bas`) are included partway through `vtirc.bas`, right after `draw_ui()`. Code they call that is defined later in `vtirc.bas` needs a `Declare` in `vtirc.bi`.

**Dirty-flag rendering.** `draw_ui()` only redraws the regions whose flag is set:
- `df_hist`: chat history
- `df_pane`: user list
- `df_input`: title, menu bar and status bar

`pane_dirty` separately triggers a rebuild of the sorted `pane_items()` / `pane_display_items()`. Any state change that affects the screen must set the matching flag, or nothing will redraw.

**Windows (`wins()` / `win_count` / `active_win`).**
- Up to `WIN_MAX` slots. Channel windows always come before PM windows: `win_open` inserts channels before the first PM and shifts the array.
- `win_close` compacts the array, so window indices are not stable. Look windows up by target with `win_find`.
- `hist_append` always writes to window 0 (status / first channel).
- Each window holds its own user list, which is filled from 353/366 replies (`names_receiving`).

**History.** Each window has a ring buffer of `HISTORY_MAX` `irc_line`s. Text is word-wrapped once, at append time (`mirc_wordwrap` to `g_chat_wide`). The first line of each message keeps the unwrapped `raw_txt` so that `hist_reflow` can re-wrap everything on resize.
- `win_hist_append` adds the timestamp, writes the log and sets the unread / new-message flags.
- `win_hist_raw` does none of that; it is used for log replay.

**Text encoding and formatting.**
- The IRC wire format is UTF-8, but libvt strings are CP437. `irc_handle` converts only `trail_str` with `vt_utf8_to_cp437`.
- Outgoing text goes through `q3_to_mirc` (turns the `^0`–`^15` colour shorthand into mIRC `Chr(3)` codes), then `vt_cp437_to_utf8`, before `PRIVMSG`.
- mIRC control codes (3 = colour, 2, 15, 22 = reverse, 31) stay in the stored history and are rendered by `draw_mirc_line`. Use `mirc_visual_len` for widths, and `irc_strip_colors` before logging or matching text.

**IRC protocol.** `irc_parse` splits a line into prefix / command / params / trailing. `irc_handle` is one big `Select Case` over commands and numerics (PRIVMSG with CTCP ACTION, NOTICE, JOIN, PART, QUIT, NICK, 001, 305/306 away, 321–323 channel list into `chlist_*` while `chlist_active`, 332, 353/366, 433 → `nick_alt`). There are two connection flags:
- `sock_valid`: the socket is open.
- `connected`: the server sent 001.

`irc_connect` does a fresh connect when `is_reconnect = 0` (resets windows, reopens channels from `cfg.channel`). When `is_reconnect = 1` it keeps history.

**Slash commands** are handled in the `Select Case cmd_word` block inside the Enter handler of the main loop. When you add or change a command or keybinding, also update the help text in `vtirc_help.bas`. `/join` and `/part` rewrite `cfg.channel` (comma-separated) and save it, so joined channels persist.

**Modal dialogs** (F1–F4, `vtirc_*.bas`) each run their own `Do` loop, driven by `vt_inkey` and `vt_tui_form_handle` or `vt_tui_listbox_handle`. Required pattern:
- On entry: call `vt_tui_theme_default()` and `dialog_lock_size()`.
- On **every** exit path: call `scheme_apply()` and `dialog_unlock_size()`.
- Call `irc_poll()` inside the loop so PINGs are answered while the dialog is open. The F2 server form skips this because it only opens while disconnected.

**Menu bar.** The menu is rebuilt every frame in `menu_rebuild()`. The `VTIRC_MENU_*` enums in `vtirc.bi` must match the item order and counts there. The Window menu is dynamic: item `MENU_WINDOW_FIRST + i` selects `wins(i)`.

**Layout.** The user-list pane is fixed at columns 1–`PANE_W` (18), with a separator in column 19; chat starts at `CHAT_COL` (20). Row 1 is the menu bar. `screen_relayout()` derives the other rows (`g_chat_rows`, `g_row_input`, `g_row_status`) from the window size, with a minimum of `MIN_SCREEN_COLS`×`MIN_SCREEN_ROWS`. It also resizes `url_hit_map` (one clickable-URL entry per visible chat row, rebuilt in `draw_history`).

**Adding a config setting** takes four edits: the `irc_config` type in `vtirc.bi`, `cfg_defaults`, `cfg_load`, and `cfg_save`. If users should be able to change it, also add it to the F3 form (`vtirc_config.bas`).

**Platform code.** Selected with `#ifdef __FB_WIN32__` / `__FB_MAC__` / `IRC_LINUX_NOTIFY`, mainly in `open_url` and `notify_user`:
- Windows: `ShellExecuteEx`, `PlaySound`, and `FlashWindowEx`.
- Linux: `xdg-open`, X11 `_NET_WM_STATE_DEMANDS_ATTENTION`, and `paplay`/`aplay` with a fallback to `Beep`.
- Mac: `open` and `Beep`. The version string is `IRC_VERSION` in `vtirc.bi`.
