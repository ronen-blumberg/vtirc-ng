# VTIRC 2.0: plan for a full-featured IRC client

Goal: turn VTIRC 1.23 into a production-quality IRC client for **Windows 32-bit** and **Linux 64-bit**, with the features people expect from mIRC and HexChat. That means multiple servers at once, TLS and SASL, services commands (`/ns`, `/cs`, ...), `/whois`, full channel management, and a proper nick list and window list, all while keeping VTIRC's character: one small executable, a text-mode UI, and no installer.

---

## 1. Where 1.23 stands today

### 1.1 Limits that come from the design

| Area | Today | Why it blocks "production" |
|---|---|---|
| Connections | One global `sock`, and `cfg` holds one server | Can't use more than one server; every feature assumes a single connection |
| Windows | Fixed `wins(16)`, reordered by copying whole windows around, looked up by `LCase` name | Too few windows for multiple servers; a window's position changes when others close; names don't compare correctly under IRC's own case rules |
| User list | Fixed at 200 users; `@+%&~` stripped | Big channels are cut off; you can't see who is an op or has voice |
| Protocol | No CAP, SASL, 005 (ISUPPORT), KICK, MODE, live TOPIC changes, INVITE, CTCP replies, or WHOIS formatting; unknown numerics just go to the status window in grey | Behind every modern client; services and moderation don't work |
| Sending | `irc_send` gives up when the socket would block and cuts anything longer than 510 bytes | Silently loses text; no flood protection |
| Connecting | Address lookup (`gethostbyname`) and `vt_net_connect` block | The whole UI freezes while connecting, and again on every auto-reconnect attempt |
| Dead connections | Only noticed when `recv` fails | A connection that silently dies (NAT timeout) looks alive forever |
| Security | No TLS; the password is plaintext in `.vtirc` next to the exe | Can't be used on Libera, OFTC, etc. over TLS |
| Encoding | Everything is converted to CP437 as it arrives | Non-Latin text (Hebrew, Cyrillic, CJK, emoji) can't be shown and gets garbled if relayed |
| Commands | 9 slash commands; anything else is "Unknown command" | No `/whois`, `/ns`, `/cs`, `/mode`, `/kick`, `/topic`, `/raw`, ... |
| Code layout | 2.5k-line `vtirc.bas`; protocol, UI and state are mixed together | Hard to grow and impossible to test without a screen |

### 1.2 Bugs found while reading the code (fix in Phase 0)

1. **X11 code corrupts memory on 64-bit Linux** (`x11_find_toplevel`, `vtirc.bas:49`). `nitems`, `bytes_after` and `actual_type` are 32-bit `ULong`s, but `XGetWindowProperty` writes a 64-bit C `long` through each pointer, which overwrites the stack. The window list returned for format-32 data is also an array of 64-bit longs, but it is indexed as a `ULong Ptr`. These variables and the list need FB types that match C `long` on the target platform (`Window`, `Atom`, `CULong`-sized integers).
2. **Notifications can't find their own window after connecting.** `notify_user` looks for the window titled `"VTIRC " & IRC_VERSION`, but `update_window_title` renames it to `"VTIRC - server / target"`. Fix: remember the window handle once at startup (on Windows via SDL/`vt_internal.sdl_window`), not by searching by title.
3. **The nick you end up with overwrites your saved nick.** 001 and NICK both assign `cfg.nick`, and `cfg_save()` then saves it. If the alt nick or a `/nick` change is in effect, it becomes the saved primary nick.
4. **Joins the server makes for you never get a window.** A JOIN for a channel with no open window goes to the status window. Examples: Libera redirects `#linux` to `##linux`, ChanServ can join you to a channel, and bouncers join channels on your behalf. In all these cases you end up with a dead window and no real one.
5. **KICK isn't handled.** Kicked users stay in the user list. If you are the one kicked, the window still looks joined.
6. **Long messages are silently cut** at 510 bytes after UTF-8 conversion, possibly in the middle of a character.
7. **`-arch native` in `#cmdline`** makes binaries that can crash with "illegal instruction" on other people's CPUs. Release builds must not use it.

### 1.3 What libvt can and can't do (it's in `/usr/local/include/freebasic/vt`, v1.11.0)

- ✅ **TLS** through mbedtls (`VT_USE_TLS`, `vt_tls_connect/send/recv/fingerprint`), with prebuilt `mbedtls_win32.a` and `mbedtls_linux64.a` included. Non-blocking reads are supported.
- ⚠️ TLS runs with `MBEDTLS_SSL_VERIFY_NONE`, so **certificates are never checked**. Short term: trust-on-first-use (TOFU) pinning with `vt_tls_fingerprint`. Long term: add CA-bundle checking to `vt_tls_glue.c`.
- ⚠️ `vt_net_resolve` uses `gethostbyname`, so it is **IPv4 only and blocks**.
- ⚠️ Screen cells are **8-bit CP437**. Full Unicode rendering would need changes inside libvt.
- ✅ The TUI toolkit (forms, listbox, menubar, dialogs, read-only editor, copy/paste) is enough for every dialog in this plan. There are no context menus, but one can be built from a listbox in a small window.
- ✅ `vt_net_bind/listen/accept` exist, which is enough for DCC.

---

## 2. Target architecture

### 2.1 Two layers: IRC core and UI

```
            ┌───────────────────────── UI layer (libvt) ─────────────────────────┐
 keyboard → │ input line · command dispatcher · window list · nick list · dialogs │
   mouse  → │ renderer (dirty flags) · themes · notifications                    │
            └───────────────▲───────────────────────────────┬────────────────────┘
                            │ buffer events                 │ commands / actions
            ┌───────────────┴───────────────────────────────▼────────────────────┐
            │                  IRC core (no libvt drawing calls)                 │
            │  conn[] ─ state machine ─ send queue ─ parser ─ ISUPPORT/CAP/SASL  │
            │  channels / users / modes · CTCP · ignore · logging                │
            └───────────────▲───────────────────────────────┬────────────────────┘
                            │ bytes                         │ bytes
            ┌───────────────┴───────────────────────────────▼────────────────────┐
            │ transport: plain TCP / TLS / SOCKS5 · connect worker thread        │
            └────────────────────────────────────────────────────────────────────┘
```

- The core never draws anything. It calls a small set of hooks (`ui_buf_print`, `ui_buf_created`, `ui_nicklist_changed`, `ui_activity`...). The real program wires these to the renderer. A headless test program wires them to stubs, so the parser and state logic can be tested without SDL.
- It stays **one compilation unit** (`fbc vtirc.bas`, everything pulled in with `#include`) and only moves into a `src/` tree. Compiling this way takes about 6 s and keeps the "single exe, no separate module compilation" workflow.

### 2.2 Data model

```freebasic
Enum CONN_STATE : CS_OFFLINE, CS_RESOLVING, CS_CONNECTING, CS_TLS, CS_REGISTERING, CS_ONLINE, CS_WAIT_RECONNECT : End Enum

Type irc_conn                    ' one per network connection
    id, net_idx                  ' which saved network / server entry
    state      As CONN_STATE
    sock       As SOCKET, tls As Any Ptr
    recv_buf   As String
    sendq(Any) As String, sendq_tokens As Double   ' flood control (token bucket)
    cur_nick   As String         ' the nick in effect on the server (never written back to config)
    isupport   : prefix_modes, prefix_chars, chantypes, chanmodes A/B/C/D, casemapping, network, nicklen, targmax, modes
    caps_on    As String         ' negotiated IRCv3 capabilities
    last_rx, ping_sent, lag      ' ping timeout + lag meter
    reconnect_n, reconnect_at    ' exponential backoff
    away, away_msg
End Type

Type irc_user_entry : nick As String, modes As String  ' "@+" (multi-prefix), account, away As Byte : End Type

Type irc_buffer                  ' a "window": status, channel, query, list, raw, whois...
    id As Long                   ' stable -- never reused, never renumbered
    conn_id As Long, kind As Byte, name As String
    hist(Any) As irc_line, hist_head, hist_count, hist_max
    users(Any) As irc_user_entry, user_count     ' channel buffers only, grows as needed
    topic, topic_by, topic_at, chan_modes, chan_key
    activity As Byte             ' 0 none · 1 events · 2 messages · 3 highlight
    scroll, marker_line, joined As Byte, draft As String   ' per-window unsent input
End Type
```

- Windows are kept in a growable pool plus an **ordering array** grouped by connection. The switch bar and window tree read that ordering. Other code refers to windows by `id` and never by array position.
- `buf_find(conn_id, name)` compares names using the server's CASEMAPPING (`rfc1459` treats `[]\~` and `{}|^` as equal).
- **Text storage:** store and log the original UTF-8 and convert to CP437 **only when drawing**. That way nothing is lost in logs or when text is copied, quoted or re-sent, and a Unicode-capable renderer can be added later without migrating any data.

### 2.3 Source layout

```
vtirc.bas            entry point, main loop, includes
src/core/            conn.bas, transport.bas (tcp/tls/socks), parser.bas, isupport.bas, cap_sasl.bas,
                     handlers.bas (numerics + commands), ctcp.bas, casemap.bas, sendq.bas, ignore.bas
src/ui/              render.bas, input.bas, commands.bas (dispatcher table), winlist.bas, nicklist.bas,
                     topicbar.bas, statusbar.bas, popup.bas, notify.bas, theme.bas
src/dialogs/         networks.bas (network list), prefs.bas, chanbrowser.bas, help.bas, ignorelist.bas, dcc.bas
src/util/            config_ini.bas, paths.bas, log.bas, strutil.bas
tests/               test_main.bas (headless), fixtures/*.txt (recorded server traffic)
build/               build.sh (linux64), build.bat (win32), ci workflow
```

---

## 3. Features compared with mIRC and HexChat

| Feature | mIRC | HexChat | VTIRC 1.23 | VTIRC 2.0 phase |
|---|:-:|:-:|:-:|:-:|
| Several servers at once | ✅ | ✅ | ❌ | 2 |
| Network list (servers, per-network nick, autojoin, perform) | ✅ | ✅ | ❌ | 2 |
| TLS, cert pinning | ✅ | ✅ | ❌ | 1 |
| SASL PLAIN / EXTERNAL | ✅ | ✅ | ❌ | 1 / 5 |
| IRCv3 capabilities (server-time, away-notify, account-notify, multi-prefix, echo-message, ...) | partly | ✅ | ❌ | 1 |
| `/whois` with formatted output | ✅ | ✅ | ❌ | 1 |
| `/ns /cs /ms /hs /os /bs` services shortcuts | alias | ✅ | ❌ | 1 |
| Moderation: `/op /voice /kick /ban /kb /mode /topic /invite` | ✅ | ✅ | ❌ | 1 |
| Nick list with op/voice prefixes and a right-click menu | ✅ | ✅ | partly | 3 |
| Window tree / switch bar with activity colours | ✅ | ✅ | ❌ | 2 |
| Topic bar | ✅ | ✅ | ❌ | 3 |
| Highlight words, per-channel notification settings | ✅ | ✅ | nick only | 3 |
| Ignore list with masks | ✅ | ✅ | ❌ | 3 |
| Lastlog / search, marker line | ✅ | ✅ | ❌ | 3 |
| Hide join/part noise ("smart filter") | ✅ | ✅ | ❌ | 3 |
| CTCP VERSION/PING/TIME replies, `/ctcp` | ✅ | ✅ | ❌ | 1 |
| Flood protection, long-message splitting | ✅ | ✅ | ❌ | 1 |
| Lag meter, ping-timeout reconnect | ✅ | ✅ | ❌ | 1 |
| Aliases / user commands, perform on connect | ✅ | ✅ | ❌ | 4 |
| Event triggers / scripting | mIRC script | Python/Lua | ❌ | 4 (triggers), 5 (Lua) |
| DCC CHAT / SEND | ✅ | ✅ | ❌ | 5 |
| SOCKS5 / HTTP proxy (Tor) | ✅ | ✅ | ❌ | 5 |
| IPv6 | ✅ | ✅ | ❌ | 5 (needs libvt) |
| Unicode rendering | ✅ | ✅ | ❌ | 5 (needs libvt) |
| Logging (per network, daily rotation, viewer) | ✅ | ✅ | basic | 3 |

---

## 4. Phases

Each phase ends with a build that runs, has been tested against a real server, and has been committed. Size: S = a day or less, M = a few days, L = a week or more of focused work.

### Phase 0: Foundation (no new features) · **L**

1. **Build scripts and CI**
   - `build.sh` for 64-bit Linux and `build.bat` for 32-bit Windows, with explicit flags: `-s gui -w all -gen gcc -O 2`, plus `-arch 686` for win32 and `-arch x86-64` for linux64. Drop `-arch native` from `#cmdline` (keep a local dev override).
   - A GitHub Actions matrix: Linux runs the fbc 1.10.1 tarball; Windows runs the FreeBASIC-1.10.1-win32 package, which bundles its own gcc. Each run produces release zips (win32 zip includes the 32-bit `SDL2.dll`).
   - Build with the fbc version pinned to the minimum supported version, because the local dev fbc is 1.20.0.
2. **Fix the bugs in 1.2**, starting with the X11 memory corruption on 64-bit Linux and the nick/config mix-up.
3. **Split the code into modules** following the layout in 2.3, moving code without changing behaviour. Pull the IRC core out behind the UI hooks.
4. **New data model** (2.2) with room for several connections, even though the UI still shows only one: `conn(0)`, growable window pool, stable ids, per-channel user lists with modes.
5. **Store text as UTF-8** and convert to CP437 only when drawing.
6. **Tests**
   - `tests/test_main.bas` (headless) covering the parser, CASEMAPPING, ISUPPORT, MODE parsing, UTF-8-safe splitting, word-wrap and mIRC codes.
   - A local **Ergo** test server: a single binary for both platforms, with TLS, SASL, IRCv3 and built-in NickServ/ChanServ, so it can test `/ns` and `/cs` end to end. A script starts Ergo and runs a scripted session against it.

Done when: it behaves exactly like 1.23; `tests/test_main` passes; both builds come out of CI; running under Valgrind/ASan on Linux shows no invalid writes.

### Phase 1: Protocol core (one server, done properly) · **L**

- **Connecting without freezing:** address lookup, TCP connect and TLS handshake run on a worker thread (`ThreadCreate` plus a mutex-protected result). The UI keeps updating and shows "Connecting…" with a cancel option. Only raw sockets are touched off the main thread, never libvt drawing.
- **TLS:** `VT_USE_TLS`; port 6697 by default when TLS is on. Certificates are pinned on first use and saved per server. If a pinned certificate changes, a warning dialog lets you accept or abort. An "accept invalid certificate" option exists per network.
- **Registration:**
  - `CAP LS 302`, then request the supported set: `multi-prefix away-notify account-notify extended-join chghost server-time message-tags echo-message batch cap-notify userhost-in-names invite-notify setname sasl`.
  - `AUTHENTICATE PLAIN` (base64 helper), with a fallback to `PRIVMSG NickServ :IDENTIFY` or a server password.
- **ISUPPORT (005):** PREFIX, CHANTYPES, CHANMODES, CASEMAPPING, NETWORK, NICKLEN, TOPICLEN, TARGMAX, MODES, STATUSMSG.
- **Send queue:** token-bucket flood control (burst of 4, then about 1 line per 2 s, tunable). Messages are split on UTF-8 character boundaries, sized to the real byte budget (`PRIVMSG <target> :` plus the prefix the server adds). Partial writes and would-block are handled, so nothing is lost.
- **Connection health:** a PING is sent after 90 s of silence; after 180 s without a reply the connection is treated as dead. A lag meter appears in the status bar. Reconnect uses exponential backoff (5 s up to 5 min, with jitter) and rejoins channels with their keys.
- **Handlers:**
  - Events: KICK, MODE (channel and user; keeps user prefixes and channel modes up to date), TOPIC, INVITE, AWAY/away-notify, ACCOUNT, CHGHOST, SETNAME, ERROR, and joins the server makes for you.
  - Numerics: 324/329, 331/332/333, 341, 346–349, 367/368, 4xx errors shown in the active window, and MOTD (optionally collapsed).
- **WHOIS:** 311/312/313/317/318/319/301/330/338/378/379/671/276 are gathered into one formatted block, shown in the active window (configurable, like HexChat's "whois in front tab").
  ```
  ── WHOIS alice ─────────────────────────────
   alice (~al@user/alice) : Alice Example
   channels : @#freebasic +#linux
   server   : tungsten.libera.chat (Stockholm)
   account  : alice   · secure connection (TLS)
   idle     : 4m12s   · signed on 2026-09-10 08:14
  ────────────────────────────────────────────
  ```
- **CTCP:** replies to VERSION, PING, TIME, CLIENTINFO and SOURCE, rate-limited to resist CTCP flooding. Incoming CTCP is shown; ACTION is supported in both directions.
- **Timestamps** come from the server's `server-time` tag when available (correct times for bouncer playback), falling back to local time.

Done when: VTIRC connects to Libera over TLS with SASL; kicks and modes update the nick list; `/whois` output is complete; pasting 20 lines never gets you disconnected for flooding.

### Phase 2: Multiple servers · **L**

- **Network list dialog** (like HexChat's, opened with F2 and replacing the current server form):
  - Networks, each with an ordered list of servers (`host/port/TLS/password`) that it cycles through.
  - Per network: nick, alt nicks, username, real name, login method (none / SASL PLAIN / NickServ / server password), autojoin channels with keys, perform commands, auto-connect at startup, accept-invalid-certificate, and a proxy setting.
  - Preset networks included: Libera.Chat, OFTC, EFnet, IRCnet, Rizon, DALnet, QuakeNet, Undernet, plus "Local / I2P" (127.0.0.1).
- **Config file:** INI with sections (`[global]`, `[network "Libera"]`, `[server "Libera" 1]`), still parsed by our own code. The 1.23 `.vtirc` is migrated automatically on first start.
  - Config location: `%APPDATA%\vtirc\` on Windows or `$XDG_CONFIG_HOME/vtirc/` on Linux. A **portable mode** (a `portable` file next to the exe) keeps today's behaviour.
  - On Linux the config file is created with `0600` permissions.
- **Everything works per connection:** every handler and command uses the connection of the window it came from. `irc_poll` goes through all connections.
- **Status and switch bar:**
  - The status bar shows the network, window, modes, user count, lag and activity.
  - Window switching: Alt+1..9/0, Alt+←/→, Ctrl+Tab, Ctrl+PgUp/PgDn. Alt+letter keeps opening the menus, so the new shortcuts use digits and arrow keys.
- **Commands:**
  - `/server <host> [port] [+tls]` reconnects the current connection.
  - `/server -m …` or `/connect <network>` opens a new connection.
  - `/disconnect [network]`, `/reconnect`, `/networks`.
- **Logging per network:** `logs/<network>/<#chan>-YYYY-MM-DD.log`, with daily rotation. File names are sanitised; channel names like `#a/..` must not become paths.

Done when: VTIRC is connected to Libera, OFTC and a local I2P server at once; each reconnects on its own; windows are grouped correctly; restarting auto-connects and autojoins everything.

### Phase 3: HexChat/mIRC-level UI · **M–L**

- **Layout** (each pane can be toggled and resized, and the nick list hides itself when the window is too narrow):
  ```
  IRC  Settings  Channel  Window  Help                                   (menu bar)
  #freebasic: FreeBASIC compiler chat | https://freebasic.net       [+nt] (topic bar)
  ┌ windows ───┬ chat ──────────────────────────────────────┬ nicks ────┐
  │ Libera     │ [12:01] <bob> hi all                       │ @ChanServ │
  │  #freebasic│ ── marker: last read ──────────────────── │ @alice    │
  │  #linux  3 │ [12:03] <alice> bob: welcome               │ +bob      │
  │  alice   ! │                                            │  dave     │
  │ OFTC       │                                            │           │
  │  #debian   │                                            │           │
  ├────────────┴────────────────────────────────────────────┴───────────┤
  │ [bob] > _                                                           │
  │ Libera/#freebasic [+nt] 42 users · lag 0.1s · Act: 3 #linux ! alice │
  └─────────────────────────────────────────────────────────────────────┘
  ```
- **Nick list:** sorted by rank (`~&@%+`), then case-insensitively by name. Away users are greyed out. Double-click opens a query.
  - **Right-click menu:** Whois, Query, Op/Deop, Voice/Devoice, Kick, Ban, Kick+Ban, Ignore, CTCP Version/Ping. It is built from a listbox in a small window. Right-click copy stays in the chat area, so the two uses don't clash.
- **Window tree:** activity colours (events / messages / highlight), click to switch, right-click to close, part or reconnect.
- **Highlights:**
  - Your nick plus a configurable list of words and regex-free wildcard patterns.
  - Per-channel notification levels (all / highlights / none).
  - A "Highlights" window that collects every mention.
- **Notifications:** Windows flashes the taskbar and plays a sound. Linux sets the X11 urgency hint, optionally runs `notify-send`, and plays a sound through paplay/aplay.
- **Ignore list:** `nick!user@host` wildcard masks, by type (messages, notices, CTCP, invites, joins/parts). Adds `/ignore`, `/unignore` and a dialog.
- **Search and navigation:** `/lastlog <text>` and Ctrl+F search in the current window; a marker line showing where you last read; `/find` jumps to the next match.
- **Hiding noise:** a smart filter hides join/part/quit from people who haven't spoken in the last N minutes; a per-channel setting hides joins/parts entirely.
- **URL list window** collects recent links; clicking one opens it.
- **Input:**
  - Each window keeps its own unsent draft and input history.
  - Tab-completes nicks (most recent speakers first), channels, commands and `/set` keys.
  - Pasting more than one line asks for confirmation and is sent through the queue.
  - Colour and format keys: Ctrl+K colour, Ctrl+B bold, Ctrl+U underline, Ctrl+R reverse, Ctrl+O reset. The `^n` shorthand is kept.
- **Themes file:** the three built-in schemes plus user themes in `themes/*.ini`, and configurable nick colours.

### Phase 4: Power features · **M**

- **Aliases / user commands** in the style of HexChat and mIRC: `/alias ghost /ns ghost $1 $2-`, with `$1 $2- $nick $chan $network $me` variables. They are stored in the config and can be edited in a dialog.
- **Perform lists** run per network after 001: commands, delays and joins.
- **Triggers:** `on text/notice/join/kick matching <wildcard> [in <chan>] do <command>`. This gives most of what people use mIRC scripting for, without a scripting engine.
- **Away:** optional auto-away when idle, and an away log that collects highlights received while away.
- **Channel browser (F4):** works per network, with server-side `LIST` filters (`>50`, `*linux*`), sorting and joining several channels.
- **Channel-mode dialog:** topic editor, mode checkboxes (+n +t +s +i +m +k +l), and ban, exception and invite lists with remove buttons.

### Phase 5: Advanced / needs libvt changes · **L each**

- **DCC CHAT, SEND and RECEIVE:** active and passive (reverse) DCC, configurable port range, resume, and a transfer window. Incoming DCC is never auto-accepted by default, and file names are sanitised.
- **Proxies:** SOCKS5 (with Tor-friendly remote DNS) and HTTP CONNECT. Both are small handshakes on top of the plain TCP socket.
- **IPv6:** `getaddrinfo`-based lookup and connect. Needs a new libvt function or our own small wrapper.
- **Certificate checking against a CA bundle** and **SASL EXTERNAL (client certificates):** both need changes to `vt_tls_glue.c` (`MBEDTLS_SSL_VERIFY_REQUIRED`, a CA file, and `mbedtls_ssl_conf_own_cert`).
- **Unicode rendering:** needs libvt cells wider than 8 bits and a Unicode font (for example GNU Unifont 8×16 for BMP characters). Because phase 0 stores text as UTF-8, this touches only the renderer and libvt.
- **Lua scripting (optional):** FreeBASIC includes Lua headers. Hooks would cover events, commands and timers. Only worth doing if triggers and aliases turn out not to be enough.
- **Bouncer support:** `chathistory` / `znc.in/playback`, and the `draft/read-marker` capability.

### Phase 6: Release · **S–M**

- Version 2.0.0 with semantic versioning, a CHANGELOG, and an About box that shows the version, fbc version and libvt version.
- Release zips: `vtirc-2.0.0-win32.zip` (exe, SDL2.dll, README, LICENSE) and `vtirc-2.0.0-linux-x86_64.tar.gz`.
- Help: update the F1 help, add `/help <command>` generated from the command table, and a manual in `docs/`.
- A crash log (last N protocol lines plus the error) written to the config directory.

---

## 5. Command set (Phases 1–4)

The dispatcher is **table-driven**: one table holds each command's name, minimum arguments, which window types it works in, a usage line and a help line. The same table drives `/help`, tab completion and the F1 command list. **Commands it doesn't know are sent to the server as-is** (HexChat behaviour, can be switched off), so network-specific commands work without writing code for them.

| Group | Commands |
|---|---|
| Messaging | `/msg /query /notice /me /say /ctcp /amsg /ame` |
| Services | `/ns /cs /ms /hs /os /bs` → `PRIVMSG NickServ/ChanServ/… :args` (service nicks configurable per network), `/identify`, `/ghost`, `/regain` |
| Info | `/whois /wii /whowas /who /names /topic /list /motd /lusers /version /time /stats /links /ping /lag` |
| Channel | `/join #a,#b key` `/part [reason]` `/cycle` `/hop` `/invite` `/knock` `/close` |
| Moderation | `/mode /op /deop /voice /devoice /halfop /kick /ban /unban /kb /quiet /unquiet /topic /banlist` |
| Self | `/nick /away /back /afk /umode /setname /quit [msg]` |
| Connection | `/server [-m] /connect /disconnect /reconnect /networks /raw /quote` |
| Client | `/clear /lastlog /find /ignore /unignore /alias /set /help /window /log /exec`* |

\* `/exec` (run a local command and show its output) is optional, because of the security risk.

---

## 6. Testing

1. **Headless unit tests** (`tests/test_main.bas`, built with `fbc tests/test_main.bas`, no SDL): parser edge cases (tags, no-trailing, empty params), CASEMAPPING, PREFIX/CHANMODES parsing, MODE application (`+ov-b nick1 nick2 mask`), splitting, base64, word-wrap, wildcard matching.
2. **Replaying recorded traffic:** real server output from Libera, OFTC and Ergo stored in `tests/fixtures/` is fed through the core, and the resulting state (users, modes, topic, buffers) is checked.
3. **Integration against a real server:** a local Ergo server started by `tests/run_ergo.sh` / `.bat`, with TLS, SASL, NickServ and ChanServ. Scripted checks: connect, register, `/ns identify`, `/cs op`, kick and ban, flood test, killing the server to test reconnect.
4. **Robustness:** malformed lines, very long lines, 10k-user NAMES, CTCP floods. On Linux, Valgrind or ASan builds (`-gen gcc -Wc -fsanitize=address`).
5. **Manual release checklist:** Win32 on Windows 10/11 (including the SDL2.dll lookup and a HiDPI display), Linux x86-64 on X11 and Wayland/XWayland.

---

## 7. Risks

| Risk | Mitigation |
|---|---|
| The refactor breaks behaviour that works today | Phase 0 changes no behaviour; record 1.23 sessions first and replay them after each step |
| Threads for connecting in FreeBASIC plus libvt | Only raw sockets are touched off the main thread; results are handed over through one mutex-protected slot; no libvt calls from the worker |
| libvt limits (TLS verification, IPv6, Unicode) | Keep a **vendored copy of libvt** in the repo (a `vt/` folder, which the build already supports), or send patches to upstream (rbreitinger/libvt) |
| Code that only works on 32-bit or only on 64-bit | CI builds both every commit; never use `Integer` for sizes that must match C types; FB types for Xlib values must match C `long` |
| Getting disconnected for flooding while testing | The send queue lands in Phase 1, before any bulk features |

---

## 8. Decisions (answered 2026-09-10)

The project is named **vtirc-ng**, kept apart from the original vtirc, which stays as it is for preservation.

1. **Non-Latin text:** yes, required. The libvt Unicode work moved into Phase 0 and is done.
2. **libvt:** vendored into `vt/`, with vtirc-ng's extensions (see `vt/vt_uni.bas`).
3. **Scripting:** aliases, perform lists and triggers are enough. Lua is optional.
4. **DCC:** yes, in scope.
5. **Config location:** per-user folders plus portable mode.
6. **FreeBASIC:** 1.10.1 (`/usr/local/bin/fbc`; win32 via `fbc32.exe` under wine).

Environment limits:
- Only GNU Unifont was approved for download.
- So there's no Ergo server: integration tests use a scripted fake IRC server (`tests/fakeircd.py`).
- There's no mbedTLS source: TLS uses certificate pinning only, with no CA-chain checking and no SASL EXTERNAL.
- Windows builds use the existing 32-bit `SDL2.dll` in `deps/win32/`.

Since the whole program gets rewritten on the new architecture, the 1.23 bugs from 1.2 are fixed by the rewrite rather than patched in the old code.

## 8a. Progress

- [x] 0.1 Build scripts (`build/build.sh`, `build/build.bat`), `-arch native` removed, libvt vendored
- [x] 0.2 libvt Unicode extension, Unifont fonts, display-width tables
- [x] 0.3 Util modules (UTF-8, width, bidi, INI config, paths, base64, wildcards) + unit tests
- [x] 0.4 IRC core (parser, casemap, ISUPPORT, transport+threads+TLS, conn state machine, sendq, CAP/SASL, handlers, CTCP, buffers, events, logging) + fake-server integration tests
- [x] 0.5 Command table and full command set
- [x] 1.x UI: layout, window tree, nick list, topic bar, UTF-8/bidi input line, status bar, selection/copy, menus, dialogs
- [x] 2.x Multi-server UI, network list, config migration
- [x] 3.x Highlights (+window), ignore, lastlog/search, smart filter, URL list, notifications, theme overrides, notify list
- [x] 4.x Aliases, perform, triggers, auto-away, per-window notify levels, clickable #channels
- [x] 5.x DCC, SOCKS5/HTTP proxy, IPv6 (proxies + IPv6 landed with the core)
- [x] 6.x Release packaging (build/package.sh), README, CHANGELOG, LICENSE, CLAUDE.md

### Not done / known limits in 2.0.0

- Certificates are pinned on first use; there is no certificate-authority chain check and no SASL EXTERNAL (client certificates). Both need the mbedTLS source to rebuild `vt_tls_glue.c`.
- Lua scripting was left out (aliases, perform lists and triggers were chosen instead).
- There's no channel-mode dialog; `/mode`, `/banlist`, `/exceptlist` and `/invitelist` cover it.
- Logs are one file per window, with no daily rotation.
- Passwords in the network dialog are shown in clear text; libvt form fields can't be masked.
- Combining marks (Hebrew niqqud, Arabic harakat) are not drawn. Persian/Urdu letters outside basic Arabic are not shaped. Italic is drawn upright.
- libvt dialogs (forms) accept only CP437 input; the main input line takes any Unicode.
- The Windows build has been tested under wine, not on a real Windows machine yet.
- `.github/workflows/ci.yml` has not run yet; the Windows job's FreeBASIC download needs checking on the first run.

## 9. Suggested first steps

1. Phase 0.1–0.2: build scripts, removing `-arch native`, and the X11 and nick/config bug fixes. Small, low risk, and useful straight away.
2. A **quick win before the big refactor:** `/whois` with formatted output, `/ns`, `/cs`, sending unknown commands to the server, and KICK/MODE handling, all on the current code. You get the commands you asked for right away, and they then move into the new command table in Phase 1.
3. Then Phase 0.3–0.6 (the refactor and tests), which makes multiple servers possible.
