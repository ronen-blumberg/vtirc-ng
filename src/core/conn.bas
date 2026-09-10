' =============================================================================
' src/core/conn.bas -- connection lifecycle, output queue, timers
'
'   OFFLINE --connect--> CONNECTING --job ok--> REGISTERING --001--> ONLINE
'       ^                    | job failed            |                 |
'       |                    v                       v                 v
'       +------------ WAIT_RECONNECT <------- connection lost ---------+
' =============================================================================

Declare Sub irc_handle_line(c As Long, ByRef ln As String)
Declare Sub cmd_execute(buf_id As Long, ByRef text As String)
Declare Sub friends_on_ready(c As Long)

' IRCv3 capabilities we request when offered
Const CAPS_WANTED = " multi-prefix away-notify account-notify extended-join chghost server-time " & _
                    "message-tags echo-message batch cap-notify userhost-in-names invite-notify " & _
                    "setname znc.in/server-time-iso znc.in/self-message "

Const RECONNECT_BASE_S = 5

' ---------------------------------------------------------------- output
' Queue a line for sending. Before registration and for urgent lines
' (PONG, QUIT) use conn_send_now instead.
Sub conn_send_now(c As Long, ByRef ln As String)
    If conn_valid(c) = 0 OrElse conns(c).sock < 0 Then Exit Sub
    Dim s As String = ln
    If conns(c).send_legacy Then s = utf8_to_charset(s, conns(c).charset)
    If Len(s) > 510 Then s = Left(s, utf8_safe_cut(s, 510))
    conns(c).pend &= s & Chr(13, 10)
End Sub

Sub conn_send(c As Long, ByRef ln As String)
    If conn_valid(c) = 0 OrElse conns(c).sock < 0 Then Exit Sub
    If conns(c).registered = 0 Then conn_send_now(c, ln) : Exit Sub
    With conns(c)
        If .sq_count >= 4000 Then Exit Sub                ' runaway paste guard
        If .sq_count > UBound(.sq) Then
            ' grow the ring, unrolling it to start at 0
            Dim n As Long = .sq_count
            If n = 0 Then
                ReDim .sq(0 To 15)
            Else
                Dim tmp() As String
                ReDim tmp(0 To n - 1)
                Dim i As Long
                For i = 0 To n - 1
                    tmp(i) = .sq((.sq_head + i) Mod (UBound(.sq) + 1))
                Next i
                ReDim .sq(0 To n * 2 + 15)
                For i = 0 To n - 1
                    .sq(i) = tmp(i)
                Next i
            End If
            .sq_head = 0
        End If
        .sq((.sq_head + .sq_count) Mod (UBound(.sq) + 1)) = ln
        .sq_count += 1
    End With
End Sub

' Bytes the server adds in front of a relayed message (":nick!user@host ").
Function conn_prefix_len(c As Long) As Long
    If conn_valid(c) = 0 Then Return 80
    Dim u As Long = IIf(Len(conns(c).user) > 0, Len(conns(c).user), 10)
    Dim h As Long = IIf(Len(conns(c).host) > 0, Len(conns(c).host), 63)
    Return 1 + Len(conns(c).nick) + 1 + u + 1 + h + 1
End Function

' Split text into chunks that fit one PRIVMSG/NOTICE line. `extra` = bytes of
' wrapping around the text (e.g. CTCP ACTION framing).
Function conn_split_text(c As Long, ByRef cmd As String, ByRef target As String, _
                         ByRef text As String, extra As Long, parts() As String) As Long
    Dim budget As Long = 510 - conn_prefix_len(c) - Len(cmd) - 1 - Len(target) - 2 - extra
    If budget < 60 Then budget = 60
    Dim n As Long = 0
    Dim rest As String = text
    ReDim parts(0 To 3)
    Do
        If Len(rest) <= budget Then
            If n > UBound(parts) Then ReDim Preserve parts(0 To n * 2 + 1)
            parts(n) = rest : n += 1
            Exit Do
        End If
        Dim cut As Long = utf8_safe_cut(rest, budget)
        ' prefer a space in the last quarter of the chunk
        Dim sp As Long = InStrRev(Left(rest, cut), " ")
        If sp > (cut * 3) \ 4 Then cut = sp
        If n > UBound(parts) Then ReDim Preserve parts(0 To n * 2 + 1)
        parts(n) = RTrim(Left(rest, cut)) : n += 1
        rest = LTrim(Mid(rest, cut + 1))
        If Len(rest) = 0 Then Exit Do
    Loop
    ReDim Preserve parts(0 To n - 1)
    Return n
End Function

Private Sub conn_flush(c As Long)
    With conns(c)
        While Len(.pend) > 0 AndAlso .sock >= 0
            Dim w As Long = net_io_send(.sock, .tls, StrPtr(.pend), IIf(Len(.pend) > 4096, 4096, Len(.pend)))
            If w > 0 Then
                .pend = Mid(.pend, w + 1)
            ElseIf w = 0 Then
                Exit While
            Else
                .pend = ""
                Exit While
            End If
        Wend
    End With
End Sub

Private Sub conn_tick_send(c As Long)
    With conns(c)
        Dim now As Double = clock_s()
        If .tok_time = 0 Then .tok_time = now : .tokens = cfg.flood_burst
        Dim dt As Double = now - .tok_time
        If dt < 0 Then dt = 0
        .tokens += dt * 1000 / cfg.flood_rate_ms
        If .tokens > cfg.flood_burst Then .tokens = cfg.flood_burst
        .tok_time = now
        While .sq_count > 0 AndAlso .tokens >= 1
            Dim ln As String = .sq(.sq_head)
            .sq(.sq_head) = ""
            .sq_head = (.sq_head + 1) Mod (UBound(.sq) + 1)
            .sq_count -= 1
            .tokens -= 1
            conn_send_now(c, ln)
        Wend
    End With
    conn_flush(c)
End Sub

Sub conn_clear_queue(c As Long)
    Erase conns(c).sq
    conns(c).sq_head = 0
    conns(c).sq_count = 0
End Sub

' ---------------------------------------------------------------- lifecycle
Private Sub conn_reset_session(c As Long)
    With conns(c)
        .rbuf = "" : .pend = ""
        .registered = 0 : .motd_done = 0
        .cap_ls = "" : .cap_on = " " : .cap_ls_done = 0 : .cap_req_pending = 0 : .cap_ended = 0
        .sasl_state = 0
        .nick_tries = 0
        .user = "" : .host = "" : .umodes = ""
        .cm = CM_RFC1459 : .netname = ""
        .prefix_modes = "ov" : .prefix_chars = "@+"
        .chantypes = "#&"
        .chm_a = "beI" : .chm_b = "k" : .chm_c = "l" : .chm_d = "imnpst"
        .modes_max = 3 : .nicklen = 30 : .statusmsg = "@+"
        .has_whox = 0 : .monitor_max = 0
        .ping_out = 0 : .last_ping = 0 : .lag = 0
        .whois_nick = "" : .whois_buf = -1
        .ls_active = 0 : .ls_done = 0
        .hist_batches = " "
        .join_pending = 0
        .away = 0
        .tok_time = 0
    End With
    conn_clear_queue(c)
End Sub

Function conn_new(net_idx As Long, ByRef nm As String) As Long
    Dim i As Long
    For i = 0 To CONN_MAX - 1
        If conns(i).alive = 0 Then Exit For
    Next i
    If i >= CONN_MAX Then Return -1
    With conns(i)
        .alive = 1
        .net_idx = net_idx
        .name = nm
        .srv_idx = 0
        .use_adhoc = 0
        .st = CS_OFFLINE
        .job = 0
        .sock = -1
        .tls = 0
        .closing_at = 0
        .reconnect_n = 0
        .user_quit = 0
        .cert_new_fp = ""
        .rejoin_list = ""
        .focus_joins = " "
        .close_on_part = " "
        .kick_rejoin = ""
        .charset = CHARSET_CP1252
        .send_legacy = 0
        If net_idx >= 0 Then
            Dim csn As String = LCase(nets(net_idx).charset)
            If Len(csn) > 0 AndAlso csn <> "utf-8" AndAlso csn <> "utf8" Then
                .charset = charset_from_name(csn)
                .send_legacy = 1
            End If
        End If
        .nick = net_nick(net_idx)
    End With
    conn_reset_session(i)
    conns(i).status_buf = buf_new(i, BK_STATUS, nm, 0)
    Return i
End Function

' Pick the server for this attempt (rotating through the network's list).
Private Sub conn_pick_server(c As Long)
    With conns(c)
        If .use_adhoc Then Exit Sub
        If .net_idx >= 0 AndAlso nets(.net_idx).srv_count > 0 Then
            .srv_idx = .srv_idx Mod nets(.net_idx).srv_count
            .srv = nets(.net_idx).servers(.srv_idx)
        End If
    End With
End Sub

Sub conn_connect(c As Long)
    If conn_valid(c) = 0 Then Exit Sub
    With conns(c)
        If .st = CS_CONNECTING OrElse .st = CS_REGISTERING OrElse .st = CS_ONLINE Then Exit Sub
        conn_pick_server(c)
        If Len(.srv.host) = 0 Then
            ev_error(c, "No server configured for " & .name & ". Use /server <host> [port] or the network list (F2).")
            .st = CS_OFFLINE
            Exit Sub
        End If
        .user_quit = 0
        .nick = net_nick(.net_idx)
        conn_reset_session(c)
        Dim pk As Long = cfg.proxy_kind
        If .net_idx >= 0 AndAlso nets(.net_idx).proxy >= 0 Then pk = nets(.net_idx).proxy
        Dim via As String = ""
        If pk <> NP_NONE AndAlso Len(cfg.proxy_host) > 0 Then
            via = " via " & IIf(pk = NP_SOCKS5, "SOCKS5", "HTTP") & " proxy " & cfg.proxy_host & ":" & cfg.proxy_port
        Else
            pk = NP_NONE
        End If
        ev_status(c, "Connecting to " & .srv.host & ":" & .srv.port & IIf(.srv.tls, " (TLS)", "") & via & " ...")
        .job = net_job_start(.srv.host, .srv.port, .srv.tls, pk, cfg.proxy_host, cfg.proxy_port, _
                             cfg.proxy_user, cfg.proxy_pass, 20000)
        .st = CS_CONNECTING
    End With
    ui_on_conn_state(c)
End Sub

' Channels to join after registration: open joined channels + autojoin list.
Private Function conn_join_list(c As Long) As String
    Dim lst As String = ""
    Dim seen As String = " "
    Dim i As Long
    Dim cm As Long = conns(c).cm
    ' channels that were open (and joined) when the connection went away
    If Len(conns(c).rejoin_list) > 0 Then
        Dim a() As String
        Dim n As Long = str_split(conns(c).rejoin_list, ",", a())
        For i = 0 To n - 1
            If Len(a(i)) > 0 AndAlso InStr(seen, " " & irc_lc(str_word(a(i), 0), cm) & " ") = 0 Then
                lst &= IIf(Len(lst) > 0, ",", "") & a(i)
                seen &= irc_lc(str_word(a(i), 0), cm) & " "
            End If
        Next i
    End If
    If conns(c).net_idx >= 0 Then
        With nets(conns(c).net_idx)
            For i = 0 To .aj_count - 1
                If InStr(seen, " " & irc_lc(str_word(.autojoin(i), 0), cm) & " ") = 0 Then
                    lst &= IIf(Len(lst) > 0, ",", "") & .autojoin(i)
                    seen &= irc_lc(str_word(.autojoin(i), 0), cm) & " "
                End If
            Next i
        End With
    End If
    Return lst
End Function

' Send JOINs for "#a key,#b,#c key" packed into lines of at most ~400 bytes.
Sub conn_join_many(c As Long, ByRef lst As String)
    If Len(lst) = 0 Then Exit Sub
    Dim a() As String
    Dim n As Long = str_split(lst, ",", a())
    Dim chans As String
    Dim keys As String
    Dim i As Long
    ' keyed channels first so the key list lines up
    Dim pass As Long
    For pass = 0 To 1
        For i = 0 To n - 1
            Dim ch As String = str_word(a(i), 0)
            Dim ky As String = str_word(a(i), 1)
            If Len(ch) = 0 Then Continue For
            If (pass = 0 AndAlso Len(ky) = 0) OrElse (pass = 1 AndAlso Len(ky) > 0) Then Continue For
            If Len(chans) + Len(keys) + Len(ch) + Len(ky) > 400 Then
                conn_send(c, "JOIN " & chans & IIf(Len(keys) > 0, " " & keys, ""))
                chans = "" : keys = ""
            End If
            chans &= IIf(Len(chans) > 0, ",", "") & ch
            If Len(ky) > 0 Then keys &= IIf(Len(keys) > 0, ",", "") & ky
        Next i
    Next pass
    If Len(chans) > 0 Then conn_send(c, "JOIN " & chans & IIf(Len(keys) > 0, " " & keys, ""))
End Sub

' Called on end of MOTD: identify, perform, autojoin.
Sub conn_on_ready(c As Long)
    If conns(c).motd_done Then Exit Sub
    conns(c).motd_done = 1
    friends_on_ready(c)
    Dim ni As Long = conns(c).net_idx
    Dim waited As Byte = 0
    If ni >= 0 Then
        If nets(ni).login = LOGIN_NICKSERV AndAlso Len(nets(ni).login_pass) > 0 Then
            Dim idn As String = "IDENTIFY "
            If Len(nets(ni).login_user) > 0 Then idn &= nets(ni).login_user & " "
            conn_send(c, "PRIVMSG NickServ :" & idn & nets(ni).login_pass)
            waited = 1
        End If
        Dim k As Long
        For k = 0 To nets(ni).pf_count - 1
            cmd_execute(conns(c).status_buf, nets(ni).perform(k))
        Next k
    End If
    If waited Then
        ' give services a moment so channels that require identification work
        conns(c).join_pending = 1
        conns(c).join_at = clock_s() + 4
    Else
        conn_join_many(c, conn_join_list(c))
        conns(c).rejoin_list = ""
    End If
End Sub

' Close the socket and mark channels as parted; keeps buffers open.
Private Sub conn_drop(c As Long)
    With conns(c)
        If .job <> 0 Then net_job_cancel(.job) : .job = 0
        net_io_close(.sock, .tls)
        ' remember joined channels for the next connection
        Dim lst As String = ""
        Dim i As Long
        For i = 0 To BUF_MAX - 1
            If bufs(i).alive AndAlso bufs(i).conn_id = c AndAlso bufs(i).kind = BK_CHANNEL Then
                If bufs(i).joined Then
                    lst &= IIf(Len(lst) > 0, ",", "") & bufs(i).name & IIf(Len(bufs(i).chkey) > 0, " " & bufs(i).chkey, "")
                End If
                bufs(i).joined = 0
                user_clear(i)
                ui_on_nicklist(i)
            End If
        Next i
        If Len(lst) > 0 Then .rejoin_list = lst
        .registered = 0
        .closing_at = 0
        conn_clear_queue(c)
        .pend = ""
    End With
End Sub

Private Sub conn_schedule_reconnect(c As Long, ByRef why As String)
    With conns(c)
        If cfg.reconnect = 0 OrElse .user_quit Then
            .st = CS_OFFLINE
            Exit Sub
        End If
        Dim d As Double = RECONNECT_BASE_S * (2 ^ IIf(.reconnect_n > 6, 6, .reconnect_n))
        If d > cfg.reconnect_max_s Then d = cfg.reconnect_max_s
        d = d * (0.8 + Rnd * 0.4)
        .reconnect_n += 1
        .srv_idx += 1
        .reconnect_at = clock_s() + d
        .st = CS_WAIT_RECONNECT
        ev_status(c, "Reconnecting in " & CLng(d) & "s (attempt " & .reconnect_n & ")")
    End With
End Sub

' The connection went away (error, EOF, timeout, failed attempt).
Sub conn_lost(c As Long, ByRef why As String)
    If conn_valid(c) = 0 Then Exit Sub
    Dim was As Long = conns(c).st
    conn_drop(c)
    If was = CS_CONNECTING Then
        ev_error(c, "Connection failed: " & why)
    Else
        ev_error(c, "Disconnected: " & why)
    End If
    If was <> CS_CONNECTING Then
        Dim i As Long
        For i = 0 To BUF_MAX - 1
            If bufs(i).alive AndAlso bufs(i).conn_id = c AndAlso i <> conns(c).status_buf Then
                ev_line(i, LK_ERROR, 0, "!!", "", "Disconnected (" & why & ")")
            End If
        Next i
    End If
    conns(c).st = CS_OFFLINE
    conn_schedule_reconnect(c, why)
    ui_on_conn_state(c)
End Sub

' User-requested disconnect.
Sub conn_disconnect(c As Long, ByRef quit_msg As String = "")
    If conn_valid(c) = 0 Then Exit Sub
    With conns(c)
        .user_quit = 1
        If .st = CS_WAIT_RECONNECT OrElse .st = CS_CONNECTING Then
            conn_drop(c)
            .st = CS_OFFLINE
            ev_status(c, "Connection attempt cancelled")
            ui_on_conn_state(c)
            Exit Sub
        End If
        If .st = CS_OFFLINE Then Exit Sub
        Dim qm As String = IIf(Len(quit_msg) > 0, quit_msg, cfg.quit_msg)
        conn_send_now(c, "QUIT :" & qm)
        conn_flush(c)
        .closing_at = clock_s() + 1.5      ' give QUIT a moment to reach the server
    End With
End Sub

' Remove a connection and all of its buffers.
Sub conn_free(c As Long)
    If conn_valid(c) = 0 Then Exit Sub
    conn_drop(c)
    Dim i As Long
    For i = 0 To BUF_MAX - 1
        If bufs(i).alive AndAlso bufs(i).conn_id = c Then buf_close(i)
    Next i
    With conns(c)
        .alive = 0
        .name = ""
        .st = CS_OFFLINE
        Erase .ls_name : Erase .ls_users : Erase .ls_topic
        .ls_count = 0
    End With
    ui_on_conn_state(c)
End Sub

' ---------------------------------------------------------------- registration
Sub conn_on_connected(c As Long)
    With conns(c)
        .st = CS_REGISTERING
        .last_rx = clock_s()
        .connected_at = time_now()
        ev_status(c, "Connected to " & .srv.host & " (" & .peer & ")" & _
                  IIf(.tls <> 0, ", TLS certificate " & Left(.tls_fp, 16) & "...", ""))
        conn_send_now(c, "CAP LS 302")
        Dim pass As String = .srv.pass
        If .net_idx >= 0 Then
            If nets(.net_idx).login = LOGIN_SERVERPASS AndAlso Len(nets(.net_idx).login_pass) > 0 Then
                pass = nets(.net_idx).login_pass
                If Len(nets(.net_idx).login_user) > 0 Then pass = nets(.net_idx).login_user & ":" & pass
            End If
        End If
        If Len(pass) > 0 Then conn_send_now(c, "PASS " & pass)
        conn_send_now(c, "NICK " & .nick)
        conn_send_now(c, "USER " & net_username(.net_idx) & " 0 * :" & net_realname(.net_idx))
        conn_flush(c)
    End With
    ui_on_conn_state(c)
End Sub

' TLS trust-on-first-use check. Returns 1 when the connection may proceed.
Private Function conn_check_cert(c As Long) As Byte
    With conns(c)
        If .tls = 0 Then Return 1
        If .net_idx >= 0 AndAlso nets(.net_idx).accept_invalid_cert Then Return 1
        Dim pinned As String = cert_pin_get(.srv.host, .srv.port)
        If Len(pinned) = 0 Then
            cert_pin_set(.srv.host, .srv.port, .tls_fp)
            ev_status(c, "New TLS certificate for " & .srv.host & " pinned (SHA-256 " & .tls_fp & ")")
            Return 1
        End If
        If pinned = .tls_fp Then Return 1
        .cert_new_fp = .tls_fp
        ev_error(c, "TLS CERTIFICATE CHANGED for " & .srv.host & ":" & .srv.port & " -- connection aborted.")
        ev_error(c, "  pinned: " & pinned)
        ev_error(c, "  now   : " & .tls_fp)
        ev_error(c, "If the server really changed its certificate, type /cert accept and reconnect.")
        Return 0
    End With
End Function

' Next nick to try when ours is taken during registration.
Function conn_next_nick(c As Long) As String
    With conns(c)
        .nick_tries += 1
        Dim alts() As String
        Dim na As Long = str_split(net_altnicks(.net_idx), ",", alts())
        Dim k As Long = .nick_tries - 1
        Dim i As Long
        Dim cnt As Long = 0
        For i = 0 To na - 1
            If Len(Trim(alts(i))) > 0 Then
                If cnt = k Then Return Trim(alts(i))
                cnt += 1
            End If
        Next i
        Dim base_nick As String = net_nick(.net_idx)
        Dim extra As Long = k - cnt
        If extra < 2 Then Return base_nick & String(extra + 1, "_")
        Dim nl As Long = IIf(.nicklen > 4, .nicklen, 9)
        Return Left(base_nick, nl - 3) & (Int(Rnd * 900) + 100)
    End With
End Function

' ---------------------------------------------------------------- polling
Private Sub conn_poll_one(c As Long)
    With conns(c)
        Dim now As Double = clock_s()
        Select Case .st
        Case CS_CONNECTING
            Dim js As Long = net_job_state(.job)
            If js = NJ_CONNECTED Then
                .sock = .job->sock
                .tls = .job->tls
                .peer = .job->peer_addr
                .tls_fp = .job->fingerprint
                net_job_free(.job)
                .job = 0
                If conn_check_cert(c) = 0 Then
                    net_io_close(.sock, .tls)
                    .st = CS_OFFLINE
                    .user_quit = 1
                    ui_on_conn_state(c)
                    Exit Sub
                End If
                conn_on_connected(c)
            ElseIf js = NJ_FAILED Then
                Dim em As String = .job->errmsg
                net_job_free(.job)
                .job = 0
                conn_lost(c, em)
            End If
            Exit Sub
        Case CS_WAIT_RECONNECT
            If now >= .reconnect_at Then
                .st = CS_OFFLINE
                conn_connect(c)
            End If
            Exit Sub
        Case CS_OFFLINE
            Exit Sub
        End Select

        ' ---- REGISTERING / ONLINE: read everything available
        Dim buf As ZString * 16385
        Dim total As Long = 0
        Do
            Dim r As Long = net_io_recv(.sock, .tls, @buf, 16384)
            If r > 0 Then
                ' byte-exact copy (a ZString conversion would stop at NUL bytes)
                Dim chunk As String = Space(r)
                memcpy(StrPtr(chunk), @buf, r)
                .rbuf &= chunk
                .last_rx = now
                total += r
                If total > 262144 Then Exit Do          ' let the UI breathe
            ElseIf r = 0 Then
                Exit Do
            Else
                ' process what we already have, then report the loss
                Dim lost_why As String = IIf(r = -1, "connection closed by server", "connection error")
                Dim lp As Long
                Do
                    lp = InStr(.rbuf, Chr(10))
                    If lp = 0 Then Exit Do
                    Dim l1 As String = Left(.rbuf, lp - 1)
                    .rbuf = Mid(.rbuf, lp + 1)
                    If Right(l1, 1) = Chr(13) Then l1 = Left(l1, Len(l1) - 1)
                    If Len(l1) > 0 Then irc_handle_line(c, utf8_from_wire(l1, .charset))
                    If conns(c).sock < 0 Then Exit Do
                Loop
                If .closing_at > 0 OrElse .user_quit Then
                    conn_drop(c)
                    .st = CS_OFFLINE
                    ev_status(c, "Disconnected")
                    ui_on_conn_state(c)
                Else
                    conn_lost(c, lost_why)
                End If
                Exit Sub
            End If
        Loop

        Dim p As Long
        Do
            p = InStr(.rbuf, Chr(10))
            If p = 0 Then Exit Do
            Dim ln As String = Left(.rbuf, p - 1)
            .rbuf = Mid(.rbuf, p + 1)
            If Right(ln, 1) = Chr(13) Then ln = Left(ln, Len(ln) - 1)
            If Len(ln) > 0 Then irc_handle_line(c, utf8_from_wire(ln, .charset))
            If .sock < 0 OrElse .alive = 0 Then Exit Sub
        Loop
        If Len(.rbuf) > 65536 Then .rbuf = ""            ' garbage without newlines

        ' ---- timers
        If .closing_at > 0 AndAlso (Len(.pend) = 0 OrElse now >= .closing_at) Then
            conn_drop(c)
            .st = CS_OFFLINE
            ev_status(c, "Disconnected")
            ui_on_conn_state(c)
            Exit Sub
        End If
        If .st = CS_REGISTERING AndAlso now - .last_rx > 60 Then
            conn_lost(c, "registration timed out")
            Exit Sub
        End If
        If .st = CS_ONLINE Then
            If .ping_out = 0 AndAlso now - .last_ping >= 60 Then
                .last_ping = now
                .ping_out = now
                conn_send_now(c, "PING :vtirc-" & CLngInt(now * 1000))
            ElseIf .ping_out > 0 AndAlso now - .ping_out > cfg.ping_timeout_s AndAlso _
                   now - .last_rx > cfg.ping_timeout_s Then
                conn_lost(c, "ping timeout (" & cfg.ping_timeout_s & "s)")
                Exit Sub
            End If
            If .join_pending AndAlso now >= .join_at Then
                .join_pending = 0
                conn_join_many(c, conn_join_list(c))
                .rejoin_list = ""
            End If
            If Len(.kick_rejoin) > 0 Then
                Dim kr() As String
                Dim nk As Long = str_split(.kick_rejoin, ";", kr())
                Dim keep As String = ""
                Dim i As Long
                For i = 0 To nk - 1
                    If Len(kr(i)) = 0 Then Continue For
                    Dim bar As Long = InStr(kr(i), "|")
                    If now >= Val(Mid(kr(i), bar + 1)) Then
                        conn_send(c, "JOIN " & Left(kr(i), bar - 1))
                    Else
                        keep &= kr(i) & ";"
                    End If
                Next i
                .kick_rejoin = keep
            End If
        End If
    End With
    conn_tick_send(c)
End Sub

Sub conn_poll_all()
    Dim c As Long
    For c = 0 To CONN_MAX - 1
        If conns(c).alive Then conn_poll_one(c)
    Next c
End Sub

' True while any connection still has a QUIT to flush (shutdown waits on it).
Function conn_any_closing() As Byte
    Dim c As Long
    For c = 0 To CONN_MAX - 1
        If conns(c).alive AndAlso conns(c).closing_at > 0 Then Return 1
    Next c
    Return 0
End Function
