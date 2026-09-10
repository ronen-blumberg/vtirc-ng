# Changelog

## 2.0.1

**Fixed**
- Linux: connecting to a server by hostname (for example irc.libera.chat) crashed with a segmentation
  fault. FreeBASIC gives new threads a 16 KB stack on Linux, too small for a DNS lookup; the connect
  thread now gets 1 MB. The tests only used 127.0.0.1, which needs no DNS query; a DNS test was added.
- Closing the window while a dialog was open (for example the Networks dialog on the first start)
  did nothing until the dialog was closed; open dialogs are now cancelled and the program quits.

## 2.0.0 -- vtirc-ng

A rewrite of VTIRC 1.23 as vtirc-ng: a full-featured client with several networks at once.

**Connections**
- Several networks at the same time, each with its own server list, identity, login, autojoin and perform list
- Network list dialog with presets; `/server`, `/connect`, `/disconnect`, `/reconnect`
- TLS with certificate pinning (`/cert`), SASL PLAIN, NickServ identification, server passwords
- IPv4 and IPv6, SOCKS5 and HTTP proxies; connecting happens in the background
- Reconnects automatically with increasing delays and rotates through the server list; detects ping
  timeouts and shows the lag
- IRCv3 capability negotiation: server-time, echo-message, multi-prefix, away-notify, account-notify,
  extended-join, chghost, userhost-in-names, batch, cap-notify, invite-notify, setname
- Flood-controlled sending and message splitting that never cuts a UTF-8 character
- Legacy code page fallback per network (cp1252, cp1255, cp1251, cp1253, cp1256)

**Interface**
- Window tree, chat, nick list, topic bar and status bar; Alt+number window switching; activity colours
- Unicode rendering (GNU Unifont): Hebrew and Arabic laid out right to left, Arabic letters joined,
  CJK and emoji
- mIRC colours and formatting, clickable links and #channels, "last read" marker, join/part filters
- UTF-8 input line with history, tab completion and formatting keys; multi-line paste asks first
- Mouse selection and copying, context menus, dialogs for networks, preferences, channel list,
  ignore list, highlight words, aliases, DCC transfers and help
- Highlights window, notifications (sound, taskbar flash, desktop notifications on Linux), per-window
  notification levels, themes with colour overrides

**Commands**
- 101 commands, including `/whois`, `/wii`, `/whowas`, `/who`, `/ns`, `/cs`, `/ms`, `/hs`, `/os`, `/bs`,
  `/identify`, `/ghost`, `/op`, `/deop`, `/voice`, `/kick`, `/ban`, `/kb`, `/quiet`, `/topic`, `/mode`, `/invite`,
  `/knock`, `/list`, `/names`, `/ctcp`, `/ping`, `/away`, `/amsg`, `/raw`, `/lastlog`, `/urls`, `/set`
- Commands vtirc-ng doesn't know are sent to the server unchanged
- Aliases, triggers, perform lists, ignore list, notify list (MONITOR / ISON), auto-away
- DCC CHAT, SEND and RECEIVE with passive DCC and resume

**Other**
- Settings in `%APPDATA%\vtirc-ng` or `~/.config/vtirc-ng`, or next to the program in portable mode;
  a VTIRC 1.x `.vtirc` is imported on the first start
- Logs per network and window, replayed when a window opens
- Builds for Windows 32-bit and Linux 64-bit with FreeBASIC 1.10.1; unit, network and scripted UI tests

**Fixed compared to 1.23**
- On 64-bit Linux, the X11 notification code corrupted the stack; taskbar flashing now uses SDL_FlashWindow
- The nick in use no longer overwrites the saved nick
- Channels the server joins you to (for example forwarded channels) get a window
- KICK is handled; long messages are split instead of truncated
- Release builds no longer use `-arch native`

**libvt changes (in `vt/`)**
- Unicode cells with text attributes, Unicode keyboard input, a UTF-8 clipboard, an idle callback,
  and Alt+digit keys
- `vt_tls.bas` linked the non-thread-safe FreeBASIC runtime, which corrupted strings in threaded programs;
  it now uses `#libpath`
