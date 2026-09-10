' =============================================================================
' src/core/config.bas -- settings and the network list
'
' <cfg>/vtirc-ng.ini
'   [global]            client-wide settings (see settings_* below)
'   [network <name>]    one per network: server=host/port[/tls][/password] (repeated),
'                       nick, altnicks, username, realname, login, login_user,
'                       login_pass, autojoin=#chan[ key] (repeated), perform (repeated),
'                       autoconnect, accept_invalid_cert, charset, proxy
'   [ignore]            mask=types
'   [alias]             name=expansion
'   [trigger]           trigger=event|mask|target|command
'   [highlight]         word=...
'   [notify]            <network>/<target>=all|highlights|none
' <cfg>/certs.ini       [pins] host:port=sha256 fingerprint
' =============================================================================

Const NET_MAX = 64
Const SRV_MAX = 16

Enum LOGIN_KIND
    LOGIN_NONE = 0
    LOGIN_SASL           ' SASL PLAIN
    LOGIN_NICKSERV       ' PRIVMSG NickServ :IDENTIFY
    LOGIN_SERVERPASS     ' PASS
End Enum

Type srv_entry
    host As String
    port As Long
    tls  As Byte
    pass As String
End Type

Type net_entry
    name        As String
    servers(SRV_MAX - 1) As srv_entry
    srv_count   As Long
    nick        As String       ' empty = global default
    altnicks    As String       ' comma separated
    username    As String
    realname    As String
    login       As Long
    login_user  As String
    login_pass  As String
    autojoin(Any) As String     ' "#chan" or "#chan key"
    aj_count    As Long
    perform(Any) As String
    pf_count    As Long
    autoconnect As Byte
    accept_invalid_cert As Byte ' skip certificate pinning
    charset     As String       ' "utf-8" (default) or a legacy code page
    proxy       As Long         ' -1 = global setting, 0 = none, 1 = socks5, 2 = http
End Type

Type app_settings
    ' identity defaults
    nick          As String
    altnicks      As String
    username      As String
    realname      As String
    quit_msg      As String
    part_msg      As String
    away_msg      As String
    ' display
    theme         As Long       ' 0 dark, 1 classic, 2 light
    font_size     As Long       ' 0 = 8x16, 1 = 16x32 (scaled), 2 = 8x14
    renderer_hw   As Byte
    screen_cols   As Long
    screen_rows   As Long
    show_time     As Byte
    time_fmt      As String
    nick_width    As Long       ' prefix column width (0 = no alignment)
    show_tree     As Byte
    show_nicklist As Byte
    tree_width    As Long
    nicklist_width As Long
    show_topic    As Byte
    colored_nicks As Byte
    strip_colors  As Byte
    hide_joinpart As Byte       ' 0 show, 1 smart filter, 2 hide all
    smart_minutes As Long
    whois_to_active As Byte
    hl_window     As Byte       ' copy highlights into a (highlights) window
    scrollback    As Long
    unicode_font  As Byte       ' load fonts/vtirc-ng.vtuf if present
    ' behaviour
    reconnect     As Byte
    reconnect_max_s As Long
    rejoin_on_kick As Byte
    ping_timeout_s As Long
    flood_burst   As Long
    flood_rate_ms As Long
    ctcp_reply    As Byte
    raw_unknown   As Byte       ' send unknown /commands to the server
    remember_chans As Byte      ' /join and /part update the network's autojoin list
    confirm_paste As Long       ' ask when pasting more than N lines (0 = never)
    auto_away_min As Long
    ' notifications
    beep          As Byte
    flash         As Byte
    notify_send   As Byte       ' Linux notify-send desktop notifications
    notify_pm     As Byte
    ' logging
    log_enabled   As Byte
    log_pm        As Byte
    log_replay    As Long       ' lines replayed from the log when a window opens
    log_timestamps As Byte
    ' DCC
    dcc_dir       As String
    dcc_auto_accept As Byte
    dcc_port_lo   As Long
    dcc_port_hi   As Long
    dcc_ip        As String     ' external IP to announce (empty = auto)
    dcc_passive   As Byte
    ' proxy
    proxy_kind    As Long
    proxy_host    As String
    proxy_port    As Long
    proxy_user    As String
    proxy_pass    As String
End Type

Dim Shared cfg As app_settings
Dim Shared nets(0 To NET_MAX - 1) As net_entry
Dim Shared net_count As Long
Dim Shared cfg_ini As ini_file       ' whole file (keeps sections owned by other modules)
Dim Shared cfg_path As String
Dim Shared cert_ini As ini_file
Dim Shared cert_path As String

Sub settings_defaults()
    With cfg
        .nick = "vtircng" & (Int(Rnd * 9000) + 1000)
        .altnicks = ""
        .username = "vtirc"
        .realname = "vtirc-ng user"
        .quit_msg = "vtirc-ng -- a FreeBASIC IRC client"
        .part_msg = ""
        .away_msg = "Away"
        .theme = 0 : .font_size = 0 : .renderer_hw = 0
        .screen_cols = 120 : .screen_rows = 40
        .show_time = 1 : .time_fmt = "%H:%M"
        .nick_width = 12
        .show_tree = 1 : .show_nicklist = 1 : .tree_width = 18 : .nicklist_width = 16
        .show_topic = 1 : .colored_nicks = 1 : .strip_colors = 0
        .hide_joinpart = 0 : .smart_minutes = 10
        .whois_to_active = 1
        .hl_window = 1
        .scrollback = 2000
        .unicode_font = 1
        .reconnect = 1 : .reconnect_max_s = 300 : .rejoin_on_kick = 0
        .ping_timeout_s = 180
        .flood_burst = 5 : .flood_rate_ms = 2000
        .ctcp_reply = 1 : .raw_unknown = 1 : .confirm_paste = 3 : .remember_chans = 1
        .auto_away_min = 0
        .beep = 1 : .flash = 1 : .notify_send = 0 : .notify_pm = 1
        .log_enabled = 1 : .log_pm = 1 : .log_replay = 50 : .log_timestamps = 1
        .dcc_dir = "" : .dcc_auto_accept = 0 : .dcc_port_lo = 0 : .dcc_port_hi = 0
        .dcc_ip = "" : .dcc_passive = 0
        .proxy_kind = 0 : .proxy_host = "" : .proxy_port = 1080 : .proxy_user = "" : .proxy_pass = ""
    End With
End Sub

' "host/port/tls/password" <-> srv_entry
Function srv_parse(ByRef s As String, ByRef e As srv_entry) As Byte
    Dim a() As String
    Dim n As Long = str_split(s, "/", a())
    e.host = Trim(a(0))
    e.port = 6667 : e.tls = 0 : e.pass = ""
    If n > 1 Then e.port = str_to_int(a(1), 6667)
    Dim k As Long
    For k = 2 To n - 1
        If LCase(a(k)) = "tls" OrElse LCase(a(k)) = "ssl" Then
            e.tls = 1
        ElseIf LCase(a(k)) = "plain" Then
            e.tls = 0
        Else
            ' password: everything from here on (may contain '/')
            Dim j As Long
            e.pass = a(k)
            For j = k + 1 To n - 1
                e.pass &= "/" & a(j)
            Next j
            Exit For
        End If
    Next k
    If e.port <= 0 OrElse e.port > 65535 Then e.port = IIf(e.tls, 6697, 6667)
    Return IIf(Len(e.host) > 0, 1, 0)
End Function

Function srv_format(ByRef e As srv_entry) As String
    Dim r As String = e.host & "/" & e.port & IIf(e.tls, "/tls", "/plain")
    If Len(e.pass) > 0 Then r &= "/" & e.pass
    Return r
End Function

Function net_find(ByRef nm As String) As Long
    Dim i As Long
    For i = 0 To net_count - 1
        If LCase(nets(i).name) = LCase(nm) Then Return i
    Next i
    Return -1
End Function

' Returns the new index, or -1 when the list is full or the name exists.
Function net_add(ByRef nm As String) As Long
    If net_count >= NET_MAX OrElse Len(Trim(nm)) = 0 Then Return -1
    If net_find(nm) >= 0 Then Return -1
    Dim i As Long = net_count
    net_count += 1
    With nets(i)
        .name = nm : .srv_count = 0
        .nick = "" : .altnicks = "" : .username = "" : .realname = ""
        .login = LOGIN_NONE : .login_user = "" : .login_pass = ""
        Erase .autojoin : .aj_count = 0
        Erase .perform : .pf_count = 0
        .autoconnect = 0 : .accept_invalid_cert = 0 : .charset = "utf-8" : .proxy = -1
    End With
    Return i
End Function

Sub net_remove(idx As Long)
    If idx < 0 OrElse idx >= net_count Then Exit Sub
    Dim i As Long
    For i = idx To net_count - 2
        nets(i) = nets(i + 1)
    Next i
    net_count -= 1
    nets(net_count).name = ""
    Erase nets(net_count).autojoin
    Erase nets(net_count).perform
    nets(net_count).aj_count = 0
    nets(net_count).pf_count = 0
    nets(net_count).srv_count = 0
End Sub

Sub net_add_server(idx As Long, ByRef host As String, port As Long, tls As Byte, ByRef pass As String = "")
    If idx < 0 OrElse nets(idx).srv_count >= SRV_MAX Then Exit Sub
    With nets(idx).servers(nets(idx).srv_count)
        .host = host : .port = port : .tls = tls : .pass = pass
    End With
    nets(idx).srv_count += 1
End Sub

Sub net_add_autojoin(idx As Long, ByRef chan As String)
    If idx < 0 Then Exit Sub
    Dim k As Long
    For k = 0 To nets(idx).aj_count - 1
        If LCase(str_word(nets(idx).autojoin(k), 0)) = LCase(str_word(chan, 0)) Then
            nets(idx).autojoin(k) = chan
            Exit Sub
        End If
    Next k
    With nets(idx)
        If .aj_count > UBound(.autojoin) Then ReDim Preserve .autojoin(0 To .aj_count * 2 + 7)
        .autojoin(.aj_count) = chan
        .aj_count += 1
    End With
End Sub

Sub net_remove_autojoin(idx As Long, ByRef chan As String)
    If idx < 0 Then Exit Sub
    Dim k As Long
    Dim w As Long = 0
    For k = 0 To nets(idx).aj_count - 1
        If LCase(str_word(nets(idx).autojoin(k), 0)) = LCase(chan) Then Continue For
        nets(idx).autojoin(w) = nets(idx).autojoin(k)
        w += 1
    Next k
    nets(idx).aj_count = w
End Sub

' Effective identity values (network override or global default).
Function net_nick(idx As Long) As String
    If idx >= 0 AndAlso Len(nets(idx).nick) > 0 Then Return nets(idx).nick
    Return cfg.nick
End Function
Function net_altnicks(idx As Long) As String
    If idx >= 0 AndAlso Len(nets(idx).altnicks) > 0 Then Return nets(idx).altnicks
    Return cfg.altnicks
End Function
Function net_username(idx As Long) As String
    If idx >= 0 AndAlso Len(nets(idx).username) > 0 Then Return nets(idx).username
    Return IIf(Len(cfg.username) > 0, cfg.username, "vtirc")
End Function
Function net_realname(idx As Long) As String
    If idx >= 0 AndAlso Len(nets(idx).realname) > 0 Then Return nets(idx).realname
    Return IIf(Len(cfg.realname) > 0, cfg.realname, "vtirc-ng user")
End Function

Sub nets_add_presets()
    Dim i As Long
    i = net_add("Libera.Chat")
    net_add_server(i, "irc.libera.chat", 6697, 1)
    i = net_add("OFTC")
    net_add_server(i, "irc.oftc.net", 6697, 1)
    i = net_add("EFnet")
    net_add_server(i, "irc.efnet.org", 6697, 1)
    net_add_server(i, "irc.efnet.org", 6667, 0)
    i = net_add("IRCnet")
    net_add_server(i, "open.ircnet.net", 6667, 0)
    i = net_add("Rizon")
    net_add_server(i, "irc.rizon.net", 6697, 1)
    i = net_add("DALnet")
    net_add_server(i, "irc.dal.net", 6697, 1)
    i = net_add("QuakeNet")
    net_add_server(i, "irc.quakenet.org", 6667, 0)
    i = net_add("Undernet")
    net_add_server(i, "irc.undernet.org", 6667, 0)
    i = net_add("Local / I2P")
    net_add_server(i, "127.0.0.1", 6668, 0)
End Sub

' -----------------------------------------------------------------------------
' Load / save
' -----------------------------------------------------------------------------
#Define _G(k, d) ini_get(cfg_ini, "global", k, d)
#Define _GI(k, d) ini_get_int(cfg_ini, "global", k, d)

Sub settings_from_ini()
    With cfg
        .nick = _G("nick", .nick)
        .altnicks = _G("altnicks", .altnicks)
        .username = _G("username", .username)
        .realname = _G("realname", .realname)
        .quit_msg = _G("quit_msg", .quit_msg)
        .part_msg = _G("part_msg", .part_msg)
        .away_msg = _G("away_msg", .away_msg)
        .theme = _GI("theme", .theme)
        .font_size = _GI("font_size", .font_size)
        .renderer_hw = _GI("renderer_hw", .renderer_hw)
        .screen_cols = _GI("screen_cols", .screen_cols)
        .screen_rows = _GI("screen_rows", .screen_rows)
        .show_time = _GI("show_time", .show_time)
        .time_fmt = _G("time_fmt", .time_fmt)
        .nick_width = _GI("nick_width", .nick_width)
        .show_tree = _GI("show_tree", .show_tree)
        .show_nicklist = _GI("show_nicklist", .show_nicklist)
        .tree_width = _GI("tree_width", .tree_width)
        .nicklist_width = _GI("nicklist_width", .nicklist_width)
        .show_topic = _GI("show_topic", .show_topic)
        .colored_nicks = _GI("colored_nicks", .colored_nicks)
        .strip_colors = _GI("strip_colors", .strip_colors)
        .hide_joinpart = _GI("hide_joinpart", .hide_joinpart)
        .smart_minutes = _GI("smart_minutes", .smart_minutes)
        .whois_to_active = _GI("whois_to_active", .whois_to_active)
        .hl_window = _GI("hl_window", .hl_window)
        .scrollback = _GI("scrollback", .scrollback)
        .unicode_font = _GI("unicode_font", .unicode_font)
        .reconnect = _GI("reconnect", .reconnect)
        .reconnect_max_s = _GI("reconnect_max_s", .reconnect_max_s)
        .rejoin_on_kick = _GI("rejoin_on_kick", .rejoin_on_kick)
        .ping_timeout_s = _GI("ping_timeout_s", .ping_timeout_s)
        .flood_burst = _GI("flood_burst", .flood_burst)
        .flood_rate_ms = _GI("flood_rate_ms", .flood_rate_ms)
        .ctcp_reply = _GI("ctcp_reply", .ctcp_reply)
        .raw_unknown = _GI("raw_unknown", .raw_unknown)
        .remember_chans = _GI("remember_chans", .remember_chans)
        .confirm_paste = _GI("confirm_paste", .confirm_paste)
        .auto_away_min = _GI("auto_away_min", .auto_away_min)
        .beep = _GI("beep", .beep)
        .flash = _GI("flash", .flash)
        .notify_send = _GI("notify_send", .notify_send)
        .notify_pm = _GI("notify_pm", .notify_pm)
        .log_enabled = _GI("log_enabled", .log_enabled)
        .log_pm = _GI("log_pm", .log_pm)
        .log_replay = _GI("log_replay", .log_replay)
        .log_timestamps = _GI("log_timestamps", .log_timestamps)
        .dcc_dir = _G("dcc_dir", .dcc_dir)
        .dcc_auto_accept = _GI("dcc_auto_accept", .dcc_auto_accept)
        .dcc_port_lo = _GI("dcc_port_lo", .dcc_port_lo)
        .dcc_port_hi = _GI("dcc_port_hi", .dcc_port_hi)
        .dcc_ip = _G("dcc_ip", .dcc_ip)
        .dcc_passive = _GI("dcc_passive", .dcc_passive)
        .proxy_kind = _GI("proxy_kind", .proxy_kind)
        .proxy_host = _G("proxy_host", .proxy_host)
        .proxy_port = _GI("proxy_port", .proxy_port)
        .proxy_user = _G("proxy_user", .proxy_user)
        .proxy_pass = _G("proxy_pass", .proxy_pass)
        If .scrollback < 100 Then .scrollback = 100
        If .scrollback > 100000 Then .scrollback = 100000
        If .flood_burst < 1 Then .flood_burst = 1
        If .flood_rate_ms < 200 Then .flood_rate_ms = 200
        If .ping_timeout_s < 30 Then .ping_timeout_s = 30
    End With
End Sub

#Define _S(k, v) ini_set(cfg_ini, "global", k, v)

Sub settings_to_ini()
    With cfg
        _S("nick", .nick) : _S("altnicks", .altnicks) : _S("username", .username)
        _S("realname", .realname) : _S("quit_msg", .quit_msg) : _S("part_msg", .part_msg)
        _S("away_msg", .away_msg)
        _S("theme", int_str(.theme)) : _S("font_size", int_str(.font_size))
        _S("renderer_hw", int_str(.renderer_hw))
        _S("screen_cols", int_str(.screen_cols)) : _S("screen_rows", int_str(.screen_rows))
        _S("show_time", int_str(.show_time)) : _S("time_fmt", .time_fmt)
        _S("nick_width", int_str(.nick_width))
        _S("show_tree", int_str(.show_tree)) : _S("show_nicklist", int_str(.show_nicklist))
        _S("tree_width", int_str(.tree_width)) : _S("nicklist_width", int_str(.nicklist_width))
        _S("show_topic", int_str(.show_topic)) : _S("colored_nicks", int_str(.colored_nicks))
        _S("strip_colors", int_str(.strip_colors)) : _S("hide_joinpart", int_str(.hide_joinpart))
        _S("smart_minutes", int_str(.smart_minutes)) : _S("whois_to_active", int_str(.whois_to_active))
        _S("hl_window", int_str(.hl_window))
        _S("scrollback", int_str(.scrollback)) : _S("unicode_font", int_str(.unicode_font))
        _S("reconnect", int_str(.reconnect)) : _S("reconnect_max_s", int_str(.reconnect_max_s))
        _S("rejoin_on_kick", int_str(.rejoin_on_kick)) : _S("ping_timeout_s", int_str(.ping_timeout_s))
        _S("flood_burst", int_str(.flood_burst)) : _S("flood_rate_ms", int_str(.flood_rate_ms))
        _S("ctcp_reply", int_str(.ctcp_reply)) : _S("raw_unknown", int_str(.raw_unknown))
        _S("remember_chans", int_str(.remember_chans))
        _S("confirm_paste", int_str(.confirm_paste)) : _S("auto_away_min", int_str(.auto_away_min))
        _S("beep", int_str(.beep)) : _S("flash", int_str(.flash))
        _S("notify_send", int_str(.notify_send)) : _S("notify_pm", int_str(.notify_pm))
        _S("log_enabled", int_str(.log_enabled)) : _S("log_pm", int_str(.log_pm))
        _S("log_replay", int_str(.log_replay)) : _S("log_timestamps", int_str(.log_timestamps))
        _S("dcc_dir", .dcc_dir) : _S("dcc_auto_accept", int_str(.dcc_auto_accept))
        _S("dcc_port_lo", int_str(.dcc_port_lo)) : _S("dcc_port_hi", int_str(.dcc_port_hi))
        _S("dcc_ip", .dcc_ip) : _S("dcc_passive", int_str(.dcc_passive))
        _S("proxy_kind", int_str(.proxy_kind)) : _S("proxy_host", .proxy_host)
        _S("proxy_port", int_str(.proxy_port)) : _S("proxy_user", .proxy_user)
        _S("proxy_pass", .proxy_pass)
    End With
End Sub

Sub nets_from_ini()
    net_count = 0
    Dim secs() As String
    Dim ns As Long = ini_sections(cfg_ini, secs())
    Dim s As Long
    Dim a() As String
    Dim n As Long
    Dim k As Long
    For s = 0 To ns - 1
        If LCase(Left(secs(s), 8)) <> "network " Then Continue For
        Dim sec As String = secs(s)
        Dim idx As Long = net_add(Trim(Mid(sec, 9)))
        If idx < 0 Then Exit For
        With nets(idx)
            n = ini_get_all(cfg_ini, sec, "server", a())
            For k = 0 To n - 1
                Dim e As srv_entry
                If srv_parse(a(k), e) AndAlso .srv_count < SRV_MAX Then
                    .servers(.srv_count) = e
                    .srv_count += 1
                End If
            Next k
            .nick = ini_get(cfg_ini, sec, "nick")
            .altnicks = ini_get(cfg_ini, sec, "altnicks")
            .username = ini_get(cfg_ini, sec, "username")
            .realname = ini_get(cfg_ini, sec, "realname")
            Select Case LCase(ini_get(cfg_ini, sec, "login", "none"))
            Case "sasl"       : .login = LOGIN_SASL
            Case "nickserv"   : .login = LOGIN_NICKSERV
            Case "serverpass" : .login = LOGIN_SERVERPASS
            Case Else         : .login = LOGIN_NONE
            End Select
            .login_user = ini_get(cfg_ini, sec, "login_user")
            .login_pass = ini_get(cfg_ini, sec, "login_pass")
            n = ini_get_all(cfg_ini, sec, "autojoin", a())
            For k = 0 To n - 1
                If Len(Trim(a(k))) > 0 Then net_add_autojoin(idx, Trim(a(k)))
            Next k
            n = ini_get_all(cfg_ini, sec, "perform", a())
            For k = 0 To n - 1
                If Len(Trim(a(k))) > 0 Then
                    If .pf_count > UBound(.perform) Then ReDim Preserve .perform(0 To .pf_count * 2 + 7)
                    .perform(.pf_count) = Trim(a(k))
                    .pf_count += 1
                End If
            Next k
            .autoconnect = ini_get_int(cfg_ini, sec, "autoconnect", 0)
            .accept_invalid_cert = ini_get_int(cfg_ini, sec, "accept_invalid_cert", 0)
            .charset = ini_get(cfg_ini, sec, "charset", "utf-8")
            .proxy = ini_get_int(cfg_ini, sec, "proxy", -1)
        End With
    Next s
End Sub

Sub nets_to_ini()
    ' drop all network sections, then write the current list in order
    Dim secs() As String
    Dim ns As Long = ini_sections(cfg_ini, secs())
    Dim s As Long
    For s = 0 To ns - 1
        If LCase(Left(secs(s), 8)) = "network " Then ini_del_section(cfg_ini, secs(s))
    Next s
    Dim i As Long
    Dim k As Long
    For i = 0 To net_count - 1
        Dim sec As String = "network " & nets(i).name
        With nets(i)
            For k = 0 To .srv_count - 1
                ini_add(cfg_ini, sec, "server", srv_format(.servers(k)))
            Next k
            ini_set(cfg_ini, sec, "nick", .nick)
            ini_set(cfg_ini, sec, "altnicks", .altnicks)
            ini_set(cfg_ini, sec, "username", .username)
            ini_set(cfg_ini, sec, "realname", .realname)
            Dim lg As String
            Select Case .login
            Case LOGIN_SASL       : lg = "sasl"
            Case LOGIN_NICKSERV   : lg = "nickserv"
            Case LOGIN_SERVERPASS : lg = "serverpass"
            Case Else             : lg = "none"
            End Select
            ini_set(cfg_ini, sec, "login", lg)
            ini_set(cfg_ini, sec, "login_user", .login_user)
            ini_set(cfg_ini, sec, "login_pass", .login_pass)
            For k = 0 To .aj_count - 1
                ini_add(cfg_ini, sec, "autojoin", .autojoin(k))
            Next k
            For k = 0 To .pf_count - 1
                ini_add(cfg_ini, sec, "perform", .perform(k))
            Next k
            ini_set(cfg_ini, sec, "autoconnect", int_str(.autoconnect))
            ini_set(cfg_ini, sec, "accept_invalid_cert", int_str(.accept_invalid_cert))
            ini_set(cfg_ini, sec, "charset", .charset)
            ini_set(cfg_ini, sec, "proxy", int_str(.proxy))
        End With
    Next i
End Sub

' Import a VTIRC 1.x ".vtirc" (key=value, no sections) as a network.
Function config_migrate_v1(ByRef v1path As String) As Byte
    Dim old As ini_file
    If ini_load(old, v1path) = 0 Then Return 0
    Dim srv As String = ini_get(old, "", "server")
    If Len(srv) = 0 Then Return 0
    Dim nm As String = "Migrated (" & srv & ")"
    Dim idx As Long = net_find(nm)
    If idx < 0 Then idx = net_add(nm)
    If idx < 0 Then Return 0
    nets(idx).srv_count = 0
    net_add_server(idx, srv, str_to_int(ini_get(old, "", "port", "6667"), 6667), 0, "")
    Dim nk As String = ini_get(old, "", "nick")
    If Len(nk) > 0 Then cfg.nick = nk
    cfg.altnicks = ini_get(old, "", "nick_alt", cfg.altnicks)
    Dim pw As String = ini_get(old, "", "password")
    If Len(pw) > 0 Then
        nets(idx).login = LOGIN_SERVERPASS
        nets(idx).login_pass = pw
    End If
    Dim chans() As String
    Dim nc As Long = str_split(ini_get(old, "", "channel"), ",", chans())
    Dim k As Long
    For k = 0 To nc - 1
        If Len(Trim(chans(k))) > 0 Then net_add_autojoin(idx, Trim(chans(k)))
    Next k
    nets(idx).autoconnect = 1
    cfg.theme = str_to_int(ini_get(old, "", "scheme", "0"), 0)
    cfg.log_enabled = str_to_int(ini_get(old, "", "log_enabled", "1"), 1)
    cfg.log_pm = str_to_int(ini_get(old, "", "log_pm", "1"), 1)
    cfg.reconnect = str_to_int(ini_get(old, "", "auto_reconnect", "1"), 1)
    cfg.show_time = str_to_int(ini_get(old, "", "show_timestamps", "1"), 1)
    cfg.beep = str_to_int(ini_get(old, "", "beep_notify", "1"), 1)
    cfg.font_size = str_to_int(ini_get(old, "", "font_size", "0"), 0)
    cfg.renderer_hw = str_to_int(ini_get(old, "", "renderer", "0"), 0)
    Dim sc As Long = str_to_int(ini_get(old, "", "screen_cols", "0"), 0)
    Dim sr As Long = str_to_int(ini_get(old, "", "screen_rows", "0"), 0)
    If sc >= 80 Then cfg.screen_cols = sc
    If sr >= 25 Then cfg.screen_rows = sr
    Return 1
End Function

' Load everything. Returns 1 if a config file existed (0 = first run).
Function config_load() As Byte
    settings_defaults()
    cfg_path  = path_join(path_cfg_dir, "vtirc-ng.ini")
    cert_path = path_join(path_cfg_dir, "certs.ini")
    ini_load(cert_ini, cert_path)
    If ini_load(cfg_ini, cfg_path) Then
        settings_from_ini()
        nets_from_ini()
        buf_default_hist = cfg.scrollback
        Return 1
    End If
    ini_clear(cfg_ini)
    net_count = 0
    Dim v1 As String = path_join(path_exe_dir, ".vtirc")
    If file_exists(v1) = 0 Then v1 = path_join(path_cfg_dir, ".vtirc")
    If file_exists(v1) Then config_migrate_v1(v1)
    nets_add_presets()
    buf_default_hist = cfg.scrollback
    Return 0
End Function

Function config_save() As Byte
    settings_to_ini()
    nets_to_ini()
    mkdir_p(path_cfg_dir)
    Dim ok As Byte = ini_save(cfg_ini, cfg_path)
    If ok Then file_make_private(cfg_path)
    Return ok
End Function

' TLS certificate pins (trust on first use)
Function cert_pin_get(ByRef host As String, port As Long) As String
    Return ini_get(cert_ini, "pins", LCase(host) & ":" & port, "")
End Function

Sub cert_pin_set(ByRef host As String, port As Long, ByRef fp As String)
    ini_set(cert_ini, "pins", LCase(host) & ":" & port, fp)
    ini_save(cert_ini, cert_path)
    file_make_private(cert_path)
End Sub
