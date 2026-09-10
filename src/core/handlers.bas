' =============================================================================
' src/core/handlers.bas -- incoming IRC messages
' =============================================================================

Declare Sub dcc_on_ctcp(c As Long, ByRef m As irc_msg, ByRef arg As String)

Dim Shared who_print As String       ' " conn:target " WHO requests whose replies are shown

' ---------------------------------------------------------------- helpers
' User hasn't spoken recently -> join/part/quit/nick lines are filterable noise.
Private Function h_noise_flag(id As Long, ByRef nick As String) As Long
    Dim ui As Long = user_find(id, nick)
    If ui >= 0 AndAlso bufs(id).users(ui).last_spoke > 0 AndAlso _
       time_now() - bufs(id).users(ui).last_spoke < cfg.smart_minutes * 60 Then Return 0
    Return LF_NOISE
End Function

Private Function h_userhost(ByRef m As irc_msg) As String
    If Len(m.user) = 0 AndAlso Len(m.host) = 0 Then Return ""
    Return m.user & "@" & m.host
End Function

' Mode symbol of nick in a channel buffer ("@", "+", "").
Function h_nick_symbol(id As Long, ByRef nick As String) As String
    Dim ui As Long = user_find(id, nick)
    If ui < 0 Then Return ""
    Return Left(bufs(id).users(ui).pfx, 1)
End Function

Private Sub h_rename_query(c As Long, ByRef old_nick As String, ByRef new_nick As String)
    Dim q As Long = buf_find_kind(c, BK_QUERY, old_nick)
    If q < 0 Then Exit Sub
    If buf_find_kind(c, BK_QUERY, new_nick) >= 0 AndAlso irc_eq(old_nick, new_nick, conns(c).cm) = 0 Then Exit Sub
    buf_rename(q, new_nick)
End Sub

' ---------------------------------------------------------------- CAP / SASL
Private Sub h_cap_end(c As Long)
    If conns(c).cap_ended Then Exit Sub
    conns(c).cap_ended = 1
    conn_send_now(c, "CAP END")
End Sub

Private Function h_cap_name(ByRef tok As String) As String
    Dim eq As Long = InStr(tok, "=")
    Return IIf(eq > 0, Left(tok, eq - 1), tok)
End Function

Private Sub h_cap_request(c As Long, ByRef offered As String)
    Dim a() As String
    Dim n As Long = str_words(offered, a())
    Dim req As String = ""
    Dim i As Long
    Dim want_sasl As Byte = 0
    Dim ni As Long = conns(c).net_idx
    If ni >= 0 AndAlso nets(ni).login = LOGIN_SASL AndAlso Len(nets(ni).login_pass) > 0 Then want_sasl = 1
    For i = 0 To n - 1
        Dim nm As String = LCase(h_cap_name(a(i)))
        If InStr(CAPS_WANTED, " " & nm & " ") > 0 OrElse (nm = "sasl" AndAlso want_sasl) Then
            If InStr(conns(c).cap_on, " " & nm & " ") > 0 Then Continue For
            ' echo-message is only useful with server-side echo of our own lines
            If Len(req) + Len(nm) > 400 Then
                conn_send_now(c, "CAP REQ :" & req)
                conns(c).cap_req_pending += 1
                req = ""
            End If
            req &= IIf(Len(req) > 0, " ", "") & nm
        End If
    Next i
    If Len(req) > 0 Then
        conn_send_now(c, "CAP REQ :" & req)
        conns(c).cap_req_pending += 1
    End If
End Sub

Private Sub h_sasl_start(c As Long)
    conns(c).sasl_state = 1
    conn_send_now(c, "AUTHENTICATE PLAIN")
End Sub

Private Sub h_sasl_send_creds(c As Long)
    Dim ni As Long = conns(c).net_idx
    If ni < 0 Then conn_send_now(c, "AUTHENTICATE *") : Exit Sub
    Dim usr As String = nets(ni).login_user
    If Len(usr) = 0 Then usr = net_nick(ni)
    Dim b64 As String = base64_encode(usr & Chr(0) & usr & Chr(0) & nets(ni).login_pass)
    Dim p As Long = 1
    While p <= Len(b64)
        conn_send_now(c, "AUTHENTICATE " & Mid(b64, p, 400))
        p += 400
    Wend
    If Len(b64) Mod 400 = 0 Then conn_send_now(c, "AUTHENTICATE +")
    conns(c).sasl_state = 2
End Sub

Private Sub h_cap(c As Long, ByRef m As irc_msg)
    Dim sub_ As String = UCase(irc_param(m, 1))
    Select Case sub_
    Case "LS"
        ' CAP * LS * :caps  (continuation) / CAP * LS :caps (final)
        Dim more As Byte = IIf(m.pcount >= 4 AndAlso irc_param(m, 2) = "*", 1, 0)
        conns(c).cap_ls &= " " & irc_last(m)
        If more Then Exit Sub
        conns(c).cap_ls &= " "
        conns(c).cap_ls_done = 1
        h_cap_request(c, conns(c).cap_ls)
        If conns(c).cap_req_pending = 0 Then h_cap_end(c)
    Case "ACK"
        Dim a() As String
        Dim n As Long = str_words(irc_last(m), a())
        Dim i As Long
        Dim got_sasl As Byte = 0
        For i = 0 To n - 1
            Dim nm As String = LCase(a(i))
            If Left(nm, 1) = "-" Then
                conns(c).cap_on = str_replace(conns(c).cap_on, " " & Mid(nm, 2) & " ", " ")
            ElseIf InStr(conns(c).cap_on, " " & nm & " ") = 0 Then
                conns(c).cap_on &= nm & " "
                If nm = "sasl" Then got_sasl = 1
            End If
        Next i
        If conns(c).cap_req_pending > 0 Then conns(c).cap_req_pending -= 1
        ev_status(c, "Capabilities enabled:" & RTrim(conns(c).cap_on), LK_SERVER)
        If got_sasl AndAlso conns(c).registered = 0 Then
            h_sasl_start(c)
        ElseIf conns(c).cap_req_pending = 0 AndAlso conns(c).sasl_state <> 1 AndAlso conns(c).sasl_state <> 2 Then
            h_cap_end(c)
        End If
    Case "NAK"
        If conns(c).cap_req_pending > 0 Then conns(c).cap_req_pending -= 1
        If conns(c).cap_req_pending = 0 AndAlso conns(c).sasl_state <> 1 AndAlso conns(c).sasl_state <> 2 Then h_cap_end(c)
    Case "NEW"
        conns(c).cap_ls &= " " & irc_last(m) & " "
        h_cap_request(c, irc_last(m))
    Case "DEL"
        Dim a2() As String
        Dim n2 As Long = str_words(irc_last(m), a2())
        Dim k As Long
        For k = 0 To n2 - 1
            conns(c).cap_on = str_replace(conns(c).cap_on, " " & LCase(a2(k)) & " ", " ")
        Next k
    End Select
End Sub

' ---------------------------------------------------------------- ISUPPORT
Private Function h_isupport_unescape(ByRef v As String) As String
    If InStr(v, "\x") = 0 Then Return v
    Dim r As String
    Dim i As Long = 1
    While i <= Len(v)
        If Mid(v, i, 2) = "\x" AndAlso i + 3 <= Len(v) Then
            r &= Chr(ValInt("&h" & Mid(v, i + 2, 2)))
            i += 4
        Else
            r &= Mid(v, i, 1)
            i += 1
        End If
    Wend
    Return r
End Function

Private Sub h_isupport(c As Long, ByRef m As irc_msg)
    Dim i As Long
    For i = 1 To m.pcount - 2
        Dim tok As String = m.params(i)
        If Left(tok, 1) = "-" Then Continue For
        Dim eq As Long = InStr(tok, "=")
        Dim k As String = UCase(IIf(eq > 0, Left(tok, eq - 1), tok))
        Dim v As String = IIf(eq > 0, h_isupport_unescape(Mid(tok, eq + 1)), "")
        With conns(c)
            Select Case k
            Case "CASEMAPPING"
                Select Case LCase(v)
                Case "ascii"          : .cm = CM_ASCII
                Case "strict-rfc1459" : .cm = CM_STRICT_RFC1459
                Case Else             : .cm = CM_RFC1459
                End Select
                buf_set_casemap(c, .cm)
            Case "PREFIX"
                Dim cp As Long = InStr(v, ")")
                If Left(v, 1) = "(" AndAlso cp > 0 Then
                    .prefix_modes = Mid(v, 2, cp - 2)
                    .prefix_chars = Mid(v, cp + 1)
                End If
            Case "CHANTYPES"  : .chantypes = v
            Case "CHANMODES"
                Dim cmx() As String
                Dim nc As Long = str_split(v, ",", cmx())
                If nc >= 1 Then .chm_a = cmx(0)
                If nc >= 2 Then .chm_b = cmx(1)
                If nc >= 3 Then .chm_c = cmx(2)
                If nc >= 4 Then .chm_d = cmx(3)
            Case "MODES"      : .modes_max = IIf(Len(v) = 0, 12, str_to_int(v, 3))
            Case "NICKLEN"    : .nicklen = str_to_int(v, 30)
            Case "STATUSMSG"  : .statusmsg = v
            Case "WHOX"       : .has_whox = 1
            Case "MONITOR"    : .monitor_max = str_to_int(v, 100)
            Case "NETWORK"
                .netname = v
                If .net_idx < 0 AndAlso Len(v) > 0 Then
                    .name = v
                    buf_rename(.status_buf, v)
                    ui_on_conn_state(c)
                End If
            End Select
        End With
    Next i
End Sub

' ---------------------------------------------------------------- CTCP
Private Function h_ctcp_rate_ok(c As Long) As Byte
    Dim now As Double = clock_s()
    Dim i As Long
    Dim recent As Long = 0
    For i = 0 To 4
        If now - conns(c).ctcp_times(i) < 10 Then recent += 1
    Next i
    If recent >= 3 Then Return 0
    conns(c).ctcp_times(conns(c).ctcp_i) = now
    conns(c).ctcp_i = (conns(c).ctcp_i + 1) Mod 5
    Return 1
End Function

Private Sub h_ctcp_request(c As Long, ByRef m As irc_msg, ByRef target As String, ByRef cmd As String, ByRef arg As String)
    If ignore_match(m.src, IGN_CTCP) Then Exit Sub
    If cmd = "DCC" Then
        If ignore_match(m.src, IGN_DCC) = 0 Then dcc_on_ctcp(c, m, arg)
        Exit Sub
    End If
    Dim to_chan As String = IIf(conn_is_channel(c, target), " (to " & target & ")", "")
    ev_front(c, "CTCP " & cmd & IIf(Len(arg) > 0, " " & arg, "") & " from " & m.nick & to_chan, LK_CTCP, ">>")
    If cfg.ctcp_reply = 0 OrElse h_ctcp_rate_ok(c) = 0 Then Exit Sub
    Dim reply As String
    Select Case cmd
    Case "VERSION"
        #Ifdef __FB_WIN32__
            reply = "vtirc-ng " & VTIRC_VERSION & " (FreeBASIC, Windows)"
        #Else
            reply = "vtirc-ng " & VTIRC_VERSION & " (FreeBASIC, Linux)"
        #Endif
    Case "PING"       : reply = arg
    Case "TIME"       : reply = time_format(time_now(), "%Y-%m-%d %H:%M:%S")
    Case "CLIENTINFO" : reply = "ACTION CLIENTINFO DCC PING SOURCE TIME USERINFO VERSION"
    Case "SOURCE"     : reply = "vtirc-ng, a FreeBASIC IRC client"
    Case "USERINFO"   : reply = net_realname(conns(c).net_idx)
    Case Else         : Exit Sub
    End Select
    conn_send(c, "NOTICE " & m.nick & " :" & Chr(1) & cmd & IIf(Len(reply) > 0, " " & reply, "") & Chr(1))
End Sub

Private Sub h_ctcp_reply(c As Long, ByRef m As irc_msg, ByRef cmd As String, ByRef arg As String)
    If ignore_match(m.src, IGN_CTCP) Then Exit Sub
    Dim txt As String = arg
    If cmd = "PING" Then
        ' our /ctcp ping sends clock_s(); the reply echoes it back
        Dim sent As Double = Val(arg)
        If sent > 0 AndAlso clock_s() >= sent Then
            txt = LTrim(Str(CLng((clock_s() - sent) * 1000))) & " ms"
        End If
    End If
    ev_front(c, "CTCP " & cmd & " reply from " & m.nick & ": " & txt, LK_CTCP, "<<")
End Sub

' ---------------------------------------------------------------- PRIVMSG / NOTICE
Private Sub h_message(c As Long, ByRef m As irc_msg, is_notice As Byte, hist As Byte)
    Dim target As String = irc_param(m, 0)
    Dim text   As String = irc_last(m)
    Dim from   As String = m.nick
    Dim self   As Byte = conn_is_me(c, from)
    Dim server_src As Byte = IIf(InStr(m.src, "!") = 0 AndAlso InStr(m.src, ".") > 0, 1, 0)
    If Len(m.src) = 0 Then server_src = 1

    ' STATUSMSG targets like "@#chan"
    Dim status_to As String = ""
    While Len(target) > 1 AndAlso InStr(conns(c).statusmsg, Left(target, 1)) > 0 AndAlso _
          conn_is_channel(c, Mid(target, 2))
        status_to &= Left(target, 1)
        target = Mid(target, 2)
    Wend
    Dim is_chan As Byte = conn_is_channel(c, target)

    ' CTCP
    Dim is_action As Byte = 0
    If Left(text, 1) = Chr(1) Then
        Dim inner As String = Mid(text, 2)
        If Right(inner, 1) = Chr(1) Then inner = Left(inner, Len(inner) - 1)
        Dim sp As Long = InStr(inner, " ")
        Dim ccmd As String = UCase(IIf(sp > 0, Left(inner, sp - 1), inner))
        Dim carg As String = IIf(sp > 0, Mid(inner, sp + 1), "")
        If ccmd = "ACTION" AndAlso is_notice = 0 Then
            is_action = 1
            text = carg
        ElseIf self Then
            Exit Sub                           ' echo of our own CTCP
        ElseIf is_notice Then
            h_ctcp_reply(c, m, ccmd, carg)
            Exit Sub
        Else
            h_ctcp_request(c, m, target, ccmd, carg)
            Exit Sub
        End If
    End If

    If self = 0 Then
        Dim ign As Long
        If is_notice Then
            ign = IGN_NOTICE
        ElseIf is_chan Then
            ign = IGN_MSG
        Else
            ign = IGN_PRIV
        End If
        If ignore_match(m.src, ign) Then Exit Sub
    End If

    ' pick the buffer
    Dim id As Long = -1
    If is_chan Then
        id = buf_find_kind(c, BK_CHANNEL, target)
        If id < 0 Then id = ev_status_buf(c)
    ElseIf server_src Then
        id = ev_status_buf(c)
    Else
        Dim peer As String = IIf(self, target, from)
        id = buf_find_kind(c, BK_QUERY, peer)
        If id < 0 Then
            If is_notice OrElse self Then
                ' private notices and our own echoed /msg lines (e.g. to NickServ)
                ' go to the current window instead of opening a query
                id = ev_front_buf(c)
                If self Then
                    ev_line(id, IIf(is_notice, LK_NOTICE, IIf(is_action, LK_ACTION, LK_MSG)), LF_SELF, _
                            "->" & target & "<-", from, text, m.t)
                    Exit Sub
                End If
            Else
                id = buf_new(c, BK_QUERY, peer, 0)
                ev_replay_log(id)
            End If
        End If
    End If
    If buf_valid(id) = 0 Then Exit Sub

    Dim flags As Long = IIf(self, LF_SELF, 0) Or IIf(hist, LF_HISTORY, 0)
    If self = 0 AndAlso server_src = 0 AndAlso highlight_check(c, text) Then flags Or= LF_HIGHLIGHT
    Dim t As Double = m.t

    If is_chan AndAlso self = 0 Then
        Dim ui As Long = user_find(id, from)
        If ui >= 0 Then
            bufs(id).users(ui).last_spoke = time_now()
            ' learn user@host from message sources (used by /ban, /kb)
            If Len(m.host) > 0 Then bufs(id).users(ui).user = m.user : bufs(id).users(ui).host = m.host
        End If
    End If

    If is_action Then
        ev_line(id, LK_ACTION, flags, "*", from, from & " " & text, t)
    ElseIf is_notice Then
        Dim pf As String
        If server_src Then
            pf = "-" & IIf(Len(from) > 0, from, "server") & "-"
        ElseIf is_chan Then
            pf = "-" & from & ":" & status_to & target & "-"
        Else
            pf = "-" & from & "-"
        End If
        ev_line(id, LK_NOTICE, flags, pf, from, text, t)
    Else
        Dim sym As String = IIf(is_chan, h_nick_symbol(id, from), "")
        Dim pfx As String = "<" & sym & from & ">"
        If Len(status_to) > 0 Then pfx = "<" & sym & from & ":" & status_to & target & ">"
        ev_line(id, LK_MSG, flags, pfx, from, text, t)
    End If

    If self = 0 AndAlso hist = 0 Then
        If flags And LF_HIGHLIGHT Then
            ev_notify(id, NK_HIGHLIGHT, from & IIf(is_chan, " in " & target, ""), text)
        ElseIf is_chan = 0 AndAlso server_src = 0 AndAlso is_notice = 0 Then
            ev_notify(id, NK_QUERY, "Message from " & from, text)
        End If
    End If
End Sub

' ---------------------------------------------------------------- channel events
Private Sub h_join(c As Long, ByRef m As irc_msg, hist As Byte)
    Dim chan As String = irc_param(m, 0)
    If Len(chan) = 0 Then Exit Sub
    Dim nick As String = m.nick
    If conn_is_me(c, nick) Then
        If Len(m.user) > 0 Then conns(c).user = m.user
        If Len(m.host) > 0 Then conns(c).host = m.host
        Dim lc As String = irc_lc(chan, conns(c).cm)
        Dim want_focus As Byte = IIf(InStr(conns(c).focus_joins, " " & lc & " ") > 0, 1, 0)
        conns(c).focus_joins = str_replace(conns(c).focus_joins, " " & lc & " ", " ")
        Dim id As Long = buf_find_kind(c, BK_CHANNEL, chan)
        If id < 0 Then
            id = buf_new(c, BK_CHANNEL, chan, want_focus)
            ev_replay_log(id)
        ElseIf want_focus Then
            ui_request_focus(id)
        End If
        If id < 0 Then Exit Sub
        buf_rename(id, chan)
        bufs(id).joined = 1
        bufs(id).last_join_t = time_now()
        user_clear(id)
        bufs(id).names_pending = 1
        user_add(id, nick, "", m.user, m.host)
        ev_line(id, LK_JOIN, 0, "-->", nick, "You have joined " & chan, m.t)
        ui_on_nicklist(id)
        Exit Sub
    End If
    Dim id2 As Long = buf_find_kind(c, BK_CHANNEL, chan)
    If id2 < 0 Then Exit Sub
    Dim ui As Long = user_add(id2, nick, "", m.user, m.host)
    If ui >= 0 AndAlso conn_has_cap(c, "extended-join") AndAlso m.pcount >= 2 Then
        If irc_param(m, 1) <> "*" Then bufs(id2).users(ui).account = irc_param(m, 1)
    End If
    ui_on_nicklist(id2)
    If ignore_match(m.src, IGN_JOINS) Then Exit Sub
    Dim uh As String = h_userhost(m)
    ev_line(id2, LK_JOIN, LF_NOISE Or IIf(hist, LF_HISTORY, 0), "-->", nick, _
            nick & IIf(Len(uh) > 0, " (" & uh & ")", "") & " has joined " & chan, m.t)
End Sub

Private Sub h_part(c As Long, ByRef m As irc_msg, hist As Byte)
    Dim chan As String = irc_param(m, 0)
    Dim reason As String = IIf(m.pcount >= 2, irc_param(m, 1), "")
    Dim id As Long = buf_find_kind(c, BK_CHANNEL, chan)
    If conn_is_me(c, m.nick) Then
        If id < 0 Then Exit Sub
        bufs(id).joined = 0
        user_clear(id)
        ui_on_nicklist(id)
        Dim lc As String = irc_lc(chan, conns(c).cm)
        If InStr(conns(c).close_on_part, " " & lc & " ") > 0 Then
            conns(c).close_on_part = str_replace(conns(c).close_on_part, " " & lc & " ", " ")
            buf_close(id)
        Else
            ev_line(id, LK_PART, 0, "<--", m.nick, "You have left " & chan & IIf(Len(reason) > 0, " (" & reason & ")", ""), m.t)
        End If
        Exit Sub
    End If
    If id < 0 Then Exit Sub
    Dim fl As Long = h_noise_flag(id, m.nick) Or IIf(hist, LF_HISTORY, 0)
    user_remove(id, m.nick)
    ui_on_nicklist(id)
    If ignore_match(m.src, IGN_JOINS) Then Exit Sub
    Dim uh As String = h_userhost(m)
    ev_line(id, LK_PART, fl, "<--", m.nick, m.nick & IIf(Len(uh) > 0, " (" & uh & ")", "") & " has left " & chan & _
            IIf(Len(reason) > 0, " (" & reason & ")", ""), m.t)
End Sub

Private Sub h_kick(c As Long, ByRef m As irc_msg)
    Dim chan As String = irc_param(m, 0)
    Dim victim As String = irc_param(m, 1)
    Dim reason As String = IIf(m.pcount >= 3, irc_param(m, 2), "")
    Dim id As Long = buf_find_kind(c, BK_CHANNEL, chan)
    If id < 0 Then Exit Sub
    If conn_is_me(c, victim) Then
        bufs(id).joined = 0
        user_clear(id)
        ui_on_nicklist(id)
        ev_line(id, LK_KICK, LF_HIGHLIGHT, "<--", m.nick, "You have been kicked from " & chan & " by " & m.nick & _
                IIf(Len(reason) > 0, " (" & reason & ")", ""), m.t)
        ev_notify(id, NK_HIGHLIGHT, "Kicked from " & chan, "by " & m.nick & ": " & reason)
        If cfg.rejoin_on_kick Then
            conns(c).kick_rejoin &= chan & IIf(Len(bufs(id).chkey) > 0, " " & bufs(id).chkey, "") & "|" & (clock_s() + 3) & ";"
        End If
        Exit Sub
    End If
    user_remove(id, victim)
    ui_on_nicklist(id)
    ev_line(id, LK_KICK, 0, "<--", m.nick, m.nick & " has kicked " & victim & " from " & chan & _
            IIf(Len(reason) > 0, " (" & reason & ")", ""), m.t)
End Sub

Private Sub h_quit(c As Long, ByRef m As irc_msg, hist As Byte)
    Dim reason As String = irc_last(m)
    If m.pcount = 0 Then reason = ""
    Dim uh As String = h_userhost(m)
    Dim txt As String = m.nick & IIf(Len(uh) > 0, " (" & uh & ")", "") & " has quit" & IIf(Len(reason) > 0, " (" & reason & ")", "")
    Dim quiet As Byte = ignore_match(m.src, IGN_JOINS)
    Dim i As Long
    For i = 0 To BUF_MAX - 1
        If bufs(i).alive = 0 OrElse bufs(i).conn_id <> c Then Continue For
        If bufs(i).kind = BK_CHANNEL Then
            If user_find(i, m.nick) >= 0 Then
                Dim fl As Long = h_noise_flag(i, m.nick) Or IIf(hist, LF_HISTORY, 0)
                user_remove(i, m.nick)
                ui_on_nicklist(i)
                If quiet = 0 Then ev_line(i, LK_QUIT, fl, "<--", m.nick, txt, m.t)
            End If
        ElseIf bufs(i).kind = BK_QUERY AndAlso irc_eq(bufs(i).name, m.nick, conns(c).cm) Then
            ev_line(i, LK_QUIT, 0, "<--", m.nick, txt, m.t)
        End If
    Next i
End Sub

Private Sub h_nick(c As Long, ByRef m As irc_msg)
    Dim newn As String = irc_param(m, 0)
    Dim oldn As String = m.nick
    Dim self As Byte = conn_is_me(c, oldn)
    If self Then
        conns(c).nick = newn
        ev_status(c, "You are now known as " & newn, LK_NICK)
        ui_on_conn_state(c)
    End If
    Dim quiet As Byte = ignore_match(m.src, IGN_JOINS)
    Dim i As Long
    For i = 0 To BUF_MAX - 1
        If bufs(i).alive = 0 OrElse bufs(i).conn_id <> c Then Continue For
        If bufs(i).kind = BK_CHANNEL AndAlso user_find(i, oldn) >= 0 Then
            Dim fl As Long = IIf(self, 0, h_noise_flag(i, oldn))
            user_rename(i, oldn, newn)
            ui_on_nicklist(i)
            If quiet = 0 OrElse self Then
                ev_line(i, LK_NICK, fl, "--", newn, IIf(self, "You are", oldn & " is") & " now known as " & newn, m.t)
            End If
        ElseIf bufs(i).kind = BK_QUERY AndAlso irc_eq(bufs(i).name, oldn, conns(c).cm) Then
            ev_line(i, LK_NICK, 0, "--", newn, oldn & " is now known as " & newn, m.t)
        End If
    Next i
    h_rename_query(c, oldn, newn)
End Sub

' Apply a channel MODE change to the user list and mode letters.
Private Sub h_apply_chanmode(c As Long, id As Long, ByRef m As irc_msg, first_param As Long)
    Dim modestr As String = irc_param(m, first_param)
    Dim pi As Long = first_param + 1
    Dim adding As Byte = 1
    Dim i As Long
    With conns(c)
        For i = 0 To Len(modestr) - 1
            Dim ch As String = Chr(modestr[i])
            If ch = "+" Then adding = 1 : Continue For
            If ch = "-" Then adding = 0 : Continue For
            Dim pm As Long = InStr(.prefix_modes, ch)
            If pm > 0 Then
                Dim who As String = irc_param(m, pi) : pi += 1
                user_set_prefix(id, who, Mid(.prefix_chars, pm, 1), adding, .prefix_chars)
            ElseIf InStr(.chm_a, ch) > 0 Then
                pi += 1
            ElseIf InStr(.chm_b, ch) > 0 Then
                Dim bp As String = irc_param(m, pi) : pi += 1
                If ch = "k" Then bufs(id).chkey = IIf(adding, bp, "")
                If adding Then
                    If InStr(bufs(id).chmodes, ch) = 0 Then bufs(id).chmodes &= ch
                Else
                    bufs(id).chmodes = str_replace(bufs(id).chmodes, ch, "")
                End If
            ElseIf InStr(.chm_c, ch) > 0 Then
                If adding Then
                    Dim cpar As String = irc_param(m, pi) : pi += 1
                    If ch = "l" Then bufs(id).chlimit = cpar
                    If InStr(bufs(id).chmodes, ch) = 0 Then bufs(id).chmodes &= ch
                Else
                    If ch = "l" Then bufs(id).chlimit = ""
                    bufs(id).chmodes = str_replace(bufs(id).chmodes, ch, "")
                End If
            Else
                If adding Then
                    If InStr(bufs(id).chmodes, ch) = 0 Then bufs(id).chmodes &= ch
                Else
                    bufs(id).chmodes = str_replace(bufs(id).chmodes, ch, "")
                End If
            End If
        Next i
    End With
    ui_on_nicklist(id)
    ui_on_topic(id)
End Sub

Private Sub h_mode(c As Long, ByRef m As irc_msg)
    Dim target As String = irc_param(m, 0)
    Dim txt As String = irc_params_from(m, 1)
    If conn_is_channel(c, target) Then
        Dim id As Long = buf_find_kind(c, BK_CHANNEL, target)
        If id < 0 Then Exit Sub
        h_apply_chanmode(c, id, m, 1)
        ev_line(id, LK_MODE, 0, "--", m.nick, IIf(Len(m.nick) > 0, m.nick, m.src) & " sets mode " & txt, m.t)
    Else
        ' user mode
        Dim ms As String = irc_param(m, 1)
        Dim adding As Byte = 1
        Dim i As Long
        For i = 0 To Len(ms) - 1
            Dim ch As String = Chr(ms[i])
            If ch = "+" Then
                adding = 1
            ElseIf ch = "-" Then
                adding = 0
            ElseIf adding Then
                If InStr(conns(c).umodes, ch) = 0 Then conns(c).umodes &= ch
            Else
                conns(c).umodes = str_replace(conns(c).umodes, ch, "")
            End If
        Next i
        ev_status(c, "Your user mode is now +" & conns(c).umodes & "  (" & txt & ")", LK_MODE)
        ui_on_conn_state(c)
    End If
End Sub

Private Sub h_topic(c As Long, ByRef m As irc_msg)
    Dim chan As String = irc_param(m, 0)
    Dim id As Long = buf_find_kind(c, BK_CHANNEL, chan)
    If id < 0 Then Exit Sub
    bufs(id).topic = irc_param(m, 1)
    bufs(id).topic_by = m.nick
    bufs(id).topic_time = m.t
    ev_line(id, LK_TOPIC, 0, "--", m.nick, m.nick & " has changed the topic to: " & bufs(id).topic, m.t)
    ui_on_topic(id)
End Sub

Private Sub h_invite(c As Long, ByRef m As irc_msg)
    Dim who As String = irc_param(m, 0)
    Dim chan As String = irc_param(m, 1)
    If ignore_match(m.src, IGN_INVITE) Then Exit Sub
    If conn_is_me(c, who) Then
        Dim id As Long = ev_front_buf(c)
        ev_line(id, LK_INVITE, LF_HIGHLIGHT, "--", m.nick, m.nick & " invites you to " & chan & "  (type /join " & chan & ")", m.t)
        ev_notify(id, NK_INVITE, "Invitation", m.nick & " invites you to " & chan)
    Else
        Dim id2 As Long = buf_find_kind(c, BK_CHANNEL, chan)
        If id2 >= 0 Then ev_line(id2, LK_INVITE, 0, "--", m.nick, m.nick & " invited " & who & " to " & chan, m.t)
    End If
End Sub

' Update away / account / host of a nick in every channel of the connection.
Private Sub h_user_update(c As Long, ByRef nick As String, what As Long, ByRef v1 As String, ByRef v2 As String)
    Dim i As Long
    For i = 0 To BUF_MAX - 1
        If bufs(i).alive AndAlso bufs(i).conn_id = c AndAlso bufs(i).kind = BK_CHANNEL Then
            Dim ui As Long = user_find(i, nick)
            If ui >= 0 Then
                Select Case what
                Case 0 : bufs(i).users(ui).away = IIf(Len(v1) > 0, 1, 0)
                Case 1 : bufs(i).users(ui).account = IIf(v1 = "*", "", v1)
                Case 2 : bufs(i).users(ui).user = v1 : bufs(i).users(ui).host = v2
                End Select
                ui_on_nicklist(i)
            End If
        End If
    Next i
End Sub

' ---------------------------------------------------------------- WHOIS
Private Sub h_whois_line(c As Long, ByRef nick As String, ByRef label As String, ByRef text As String)
    Dim id As Long = conns(c).whois_buf
    If buf_valid(id) = 0 OrElse irc_eq(conns(c).whois_nick, nick, conns(c).cm) = 0 Then
        conns(c).whois_nick = nick
        id = IIf(cfg.whois_to_active, ev_front_buf(c), ev_status_buf(c))
        conns(c).whois_buf = id
    End If
    Dim lab As String = label & String(IIf(Len(label) < 9, 9 - Len(label), 0), " ")
    ev_line(id, LK_WHOIS, 0, "|", nick, lab & ": " & text)
End Sub

Private Sub h_numeric_whois(c As Long, num As Long, ByRef m As irc_msg)
    Dim nick As String = irc_param(m, 1)
    Dim txt As String = irc_last(m)
    Select Case num
    Case 311, 314
        ' new block
        conns(c).whois_nick = nick
        conns(c).whois_buf = IIf(cfg.whois_to_active, ev_front_buf(c), ev_status_buf(c))
        ev_line(conns(c).whois_buf, LK_WHOIS, 0, "--", nick, _
                IIf(num = 311, "WHOIS ", "WHOWAS ") & nick & " (" & irc_param(m, 2) & "@" & irc_param(m, 3) & ")")
        h_whois_line(c, nick, "name", txt)
    Case 319 : h_whois_line(c, nick, "channels", txt)
    Case 312 : h_whois_line(c, nick, "server", irc_param(m, 2) & " (" & txt & ")")
    Case 313 : h_whois_line(c, nick, "operator", txt)
    Case 317
        Dim idle As Double = Val(irc_param(m, 2))
        Dim signon As Double = Val(irc_param(m, 3))
        h_whois_line(c, nick, "idle", time_duration(idle) & IIf(signon > 0, ", signed on " & time_format(signon, "%Y-%m-%d %H:%M"), ""))
    Case 330 : h_whois_line(c, nick, "account", irc_param(m, 2))
    Case 301 : h_whois_line(c, nick, "away", txt)
    Case 671 : h_whois_line(c, nick, "secure", txt)
    Case 338, 378, 379 : h_whois_line(c, nick, "host", irc_params_from(m, 2))
    Case 276 : h_whois_line(c, nick, "cert", txt)
    Case 307, 320 : h_whois_line(c, nick, "info", txt)
    Case 318, 369
        Dim id As Long = conns(c).whois_buf
        If buf_valid(id) = 0 Then id = IIf(cfg.whois_to_active, ev_front_buf(c), ev_status_buf(c))
        ev_line(id, LK_WHOIS, 0, "--", nick, "End of " & IIf(num = 318, "WHOIS", "WHOWAS"))
        conns(c).whois_nick = ""
        conns(c).whois_buf = -1
    End Select
End Sub

' ---------------------------------------------------------------- numerics
Private Sub h_names(c As Long, ByRef m As irc_msg)
    Dim chan As String = irc_param(m, m.pcount - 2)
    Dim names As String = irc_last(m)
    Dim id As Long = buf_find_kind(c, BK_CHANNEL, chan)
    If id < 0 OrElse bufs(id).names_pending = 0 Then
        ev_front(c, "Users on " & chan & ": " & names, LK_SERVER, "*")
        Exit Sub
    End If
    If bufs(id).names_pending = 1 Then
        user_clear(id)
        bufs(id).names_pending = 2
    End If
    Dim a() As String
    Dim n As Long = str_words(names, a())
    Dim i As Long
    For i = 0 To n - 1
        Dim pfx As String
        Dim rest As String
        pfx_split(a(i), conns(c).prefix_chars, pfx, rest)
        Dim nk As String, us As String, hs As String
        irc_split_source(rest, nk, us, hs)
        user_add(id, nk, pfx_normalize(pfx, conns(c).prefix_chars), us, hs)
    Next i
End Sub

Private Sub h_names_end(c As Long, ByRef m As irc_msg)
    Dim chan As String = irc_param(m, 1)
    Dim id As Long = buf_find_kind(c, BK_CHANNEL, chan)
    If id < 0 OrElse bufs(id).names_pending = 0 Then Exit Sub
    If bufs(id).names_pending = 1 Then user_clear(id)
    bufs(id).names_pending = 0
    Dim ops As Long = 0
    Dim voices As Long = 0
    Dim i As Long
    For i = 0 To bufs(id).user_count - 1
        Dim p1 As String = Left(bufs(id).users(i).pfx, 1)
        If p1 = "+" Then
            voices += 1
        ElseIf Len(p1) > 0 Then
            ops += 1
        End If
    Next i
    ev_line(id, LK_SERVER, 0, "--", "", bufs(id).user_count & " users on " & chan & " (" & ops & " ops, " & voices & " voiced)")
    ui_on_nicklist(id)
    ' request modes and (with WHOX) away/account state for the new channel
    If time_now() - bufs(id).last_join_t < 30 Then conn_send(c, "MODE " & chan)
End Sub

Private Sub h_list_entry(c As Long, ByRef m As irc_msg)
    With conns(c)
        If .ls_active = 0 Then
            .ls_active = 1 : .ls_done = 0 : .ls_count = 0
        End If
        If .ls_count >= 20000 Then Exit Sub
        If .ls_count > UBound(.ls_name) Then
            Dim nw As Long = .ls_count * 2 + 256
            ReDim Preserve .ls_name(0 To nw)
            ReDim Preserve .ls_users(0 To nw)
            ReDim Preserve .ls_topic(0 To nw)
        End If
        .ls_name(.ls_count) = irc_param(m, 1)
        .ls_users(.ls_count) = str_to_int(irc_param(m, 2), 0)
        .ls_topic(.ls_count) = irc_strip_format(irc_last(m))
        .ls_count += 1
        If .ls_count Mod 500 = 0 Then ui_on_chanlist(c)
    End With
End Sub

Private Sub h_error_numeric(c As Long, num As Long, ByRef m As irc_msg)
    ' text: parameters after our nick
    Dim txt As String = irc_params_from(m, 1)
    Dim id As Long = ev_front_buf(c)
    Select Case num
    Case 471 To 477, 403, 405, 437, 442, 480, 489
        Dim ch As String = irc_param(m, 1)
        If conn_is_channel(c, ch) Then
            conns(c).focus_joins = str_replace(conns(c).focus_joins, " " & irc_lc(ch, conns(c).cm) & " ", " ")
            Dim cb As Long = buf_find_kind(c, BK_CHANNEL, ch)
            If cb >= 0 Then id = cb
        End If
    Case 401, 404, 406
        Dim q As Long = buf_find(c, irc_param(m, 1))
        If q >= 0 Then id = q
    End Select
    ev_line(id, LK_ERROR, 0, "!!", "", txt)
End Sub

Private Sub h_numeric(c As Long, num As Long, ByRef m As irc_msg)
    Select Case num
    Case 1
        With conns(c)
            .registered = 1
            .st = CS_ONLINE
            .reconnect_n = 0
            .nick = irc_param(m, 0)
            .last_ping = clock_s()
            .tok_time = 0
        End With
        h_cap_end(c)
        ev_status(c, irc_last(m), LK_SERVER)
        ui_on_conn_state(c)
    Case 2, 3, 4
        ev_status(c, irc_params_from(m, 1), LK_SERVER)
    Case 5
        h_isupport(c, m)
        ev_status(c, irc_params_from(m, 1), LK_SERVER)
    Case 375, 372
        ev_status(c, irc_last(m), LK_SERVER)
    Case 376, 422
        ev_status(c, irc_last(m), LK_SERVER)
        conn_on_ready(c)
    Case 301
        If Len(conns(c).whois_nick) > 0 Then
            h_numeric_whois(c, num, m)
        Else
            Dim q As Long = buf_find_kind(c, BK_QUERY, irc_param(m, 1))
            If q < 0 Then q = ev_front_buf(c)
            ev_line(q, LK_SERVER, 0, "--", irc_param(m, 1), irc_param(m, 1) & " is away: " & irc_last(m))
        End If
    Case 305
        conns(c).away = 0
        ev_front(c, "You are no longer marked as away")
        ui_on_conn_state(c)
    Case 306
        conns(c).away = 1
        ev_front(c, "You have been marked as away")
        ui_on_conn_state(c)
    Case 311, 312, 313, 317, 318, 319, 330, 338, 378, 379, 671, 276, 307, 320, 314, 369
        h_numeric_whois(c, num, m)
    Case 321
        With conns(c)
            .ls_active = 1 : .ls_done = 0 : .ls_count = 0
        End With
    Case 322
        h_list_entry(c, m)
    Case 323
        conns(c).ls_active = 0
        conns(c).ls_done = 1
        ev_status(c, "Channel list complete: " & conns(c).ls_count & " channels", LK_SERVER)
        ui_on_chanlist(c)
    Case 324
        Dim id As Long = buf_find_kind(c, BK_CHANNEL, irc_param(m, 1))
        If id >= 0 Then
            bufs(id).chmodes = ""
            bufs(id).chlimit = ""
            h_apply_chanmode(c, id, m, 2)
            ev_line(id, LK_MODE, 0, "--", "", "Channel modes: " & irc_params_from(m, 2))
        Else
            ev_front(c, irc_param(m, 1) & " modes: " & irc_params_from(m, 2), LK_SERVER)
        End If
    Case 329
        Dim id3 As Long = buf_find_kind(c, BK_CHANNEL, irc_param(m, 1))
        If id3 >= 0 Then
            bufs(id3).created = Val(irc_param(m, 2))
            ev_line(id3, LK_SERVER, 0, "--", "", "Channel created on " & time_format(bufs(id3).created, "%Y-%m-%d %H:%M"))
        End If
    Case 331
        Dim id4 As Long = buf_find_kind(c, BK_CHANNEL, irc_param(m, 1))
        If id4 >= 0 Then
            bufs(id4).topic = ""
            ev_line(id4, LK_TOPIC, 0, "--", "", "No topic is set")
            ui_on_topic(id4)
        End If
    Case 332
        Dim id5 As Long = buf_find_kind(c, BK_CHANNEL, irc_param(m, 1))
        If id5 >= 0 Then
            bufs(id5).topic = irc_last(m)
            ev_line(id5, LK_TOPIC, 0, "--", "", "Topic: " & bufs(id5).topic)
            ui_on_topic(id5)
        Else
            ev_front(c, "Topic for " & irc_param(m, 1) & ": " & irc_last(m), LK_TOPIC)
        End If
    Case 333
        Dim id6 As Long = buf_find_kind(c, BK_CHANNEL, irc_param(m, 1))
        Dim setter As String = irc_nick_of(irc_param(m, 2))
        Dim when As Double = Val(irc_param(m, 3))
        If id6 >= 0 Then
            bufs(id6).topic_by = setter
            bufs(id6).topic_time = when
            ev_line(id6, LK_TOPIC, 0, "--", "", "Topic set by " & setter & IIf(when > 0, " on " & time_format(when, "%Y-%m-%d %H:%M"), ""))
            ui_on_topic(id6)
        End If
    Case 341
        ev_front(c, "Inviting " & irc_param(m, 1) & " to " & irc_param(m, 2))
    Case 346, 348, 367, 728
        ' invite / exception / ban / quiet list entries
        Dim chan As String = irc_param(m, 1)
        Dim lid As Long = buf_find_kind(c, BK_CHANNEL, chan)
        If lid < 0 Then lid = ev_front_buf(c)
        Dim off As Long = IIf(num = 728, 3, 2)
        Dim kind As String
        Select Case num
        Case 346 : kind = "invite"
        Case 348 : kind = "exception"
        Case 367 : kind = "ban"
        Case Else : kind = "quiet"
        End Select
        Dim setby As String = irc_nick_of(irc_param(m, off + 1))
        Dim at As Double = Val(irc_param(m, off + 2))
        ev_line(lid, LK_SERVER, 0, "--", "", chan & " " & kind & ": " & irc_param(m, off) & _
                IIf(Len(setby) > 0, " (set by " & setby & IIf(at > 0, " on " & time_format(at, "%Y-%m-%d %H:%M"), "") & ")", ""))
    Case 347, 349, 368, 729
        Dim lid2 As Long = buf_find_kind(c, BK_CHANNEL, irc_param(m, 1))
        If lid2 < 0 Then lid2 = ev_front_buf(c)
        ev_line(lid2, LK_SERVER, 0, "--", "", irc_last(m))
    Case 352
        ' WHO reply: me chan user host server nick flags :hops realname
        Dim wn As String = irc_param(m, 5)
        Dim flg As String = irc_param(m, 6)
        h_user_update(c, wn, 2, irc_param(m, 2), irc_param(m, 3))
        h_user_update(c, wn, 0, IIf(InStr(flg, "G") > 0, "away", ""), "")
        If InStr(who_print, " " & c & " ") > 0 Then
            ev_front(c, irc_param(m, 1) & "  " & wn & "  " & flg & "  " & irc_param(m, 2) & "@" & irc_param(m, 3) & "  " & irc_last(m), LK_SERVER)
        End If
    Case 315
        If InStr(who_print, " " & c & " ") > 0 Then
            ev_front(c, "End of WHO list", LK_SERVER)
            who_print = str_replace(who_print, " " & c & " ", " ")
        End If
    Case 353
        h_names(c, m)
    Case 366
        h_names_end(c, m)
    Case 396
        conns(c).host = irc_param(m, 1)
        ev_status(c, irc_param(m, 1) & " " & irc_last(m), LK_SERVER)
    Case 432, 433, 436, 437
        If conns(c).registered = 0 AndAlso (num <> 437 OrElse conn_is_channel(c, irc_param(m, 1)) = 0) Then
            Dim nn As String = conn_next_nick(c)
            ev_status(c, "Nickname " & irc_param(m, 1) & " is unavailable, trying " & nn)
            conns(c).nick = nn
            conn_send_now(c, "NICK " & nn)
        Else
            h_error_numeric(c, num, m)
        End If
    Case 900
        ev_status(c, irc_last(m))
        If conns(c).join_pending Then conns(c).join_at = clock_s()        ' identified: join now
    Case 903
        conns(c).sasl_state = 3
        ev_status(c, "SASL authentication successful")
        h_cap_end(c)
    Case 902, 904, 905, 906, 907, 908
        conns(c).sasl_state = 3
        ev_error(c, "SASL: " & irc_last(m))
        h_cap_end(c)
    Case 730
        ev_status(c, "Online: " & irc_last(m))
    Case 731
        ev_status(c, "Offline: " & irc_last(m))
    Case 400 To 599
        h_error_numeric(c, num, m)
    Case Else
        ev_status(c, irc_params_from(m, 1), LK_SERVER)
    End Select
End Sub

' ---------------------------------------------------------------- dispatch
Sub irc_handle_line(c As Long, ByRef ln As String)
    Dim m As irc_msg
    irc_parse(ln, m)
    If Len(m.cmd) = 0 Then Exit Sub
    Dim st As String = irc_tag(m, "time")
    m.t = IIf(Len(st) > 0, time_parse_iso(st), 0)
    If m.t <= 0 Then m.t = time_now()
    Dim hist As Byte = 0
    Dim bt As String = irc_tag(m, "batch")
    If Len(bt) > 0 AndAlso InStr(conns(c).hist_batches, " " & bt & " ") > 0 Then hist = 1

    Dim num As Long = 0
    If Len(m.cmd) = 3 AndAlso m.cmd[0] >= 48 AndAlso m.cmd[0] <= 57 Then num = ValInt(m.cmd)
    If num > 0 Then
        h_numeric(c, num, m)
        Exit Sub
    End If

    Select Case m.cmd
    Case "PING"
        conn_send_now(c, "PONG :" & irc_last(m))
    Case "PONG"
        Dim tok As String = irc_last(m)
        If Left(tok, 6) = "vtirc-" Then
            conns(c).lag = clock_s() - conns(c).ping_out
            conns(c).ping_out = 0
            ui_on_conn_state(c)
        End If
    Case "CAP"          : h_cap(c, m)
    Case "AUTHENTICATE"
        If irc_param(m, 0) = "+" AndAlso conns(c).sasl_state = 1 Then h_sasl_send_creds(c)
    Case "PRIVMSG"      : h_message(c, m, 0, hist)
    Case "NOTICE"       : h_message(c, m, 1, hist)
    Case "JOIN"         : h_join(c, m, hist)
    Case "PART"         : h_part(c, m, hist)
    Case "KICK"         : h_kick(c, m)
    Case "QUIT"         : h_quit(c, m, hist)
    Case "NICK"         : h_nick(c, m)
    Case "MODE"         : h_mode(c, m)
    Case "TOPIC"        : h_topic(c, m)
    Case "INVITE"       : h_invite(c, m)
    Case "AWAY"         : h_user_update(c, m.nick, 0, irc_last(m) & IIf(m.pcount > 0, " ", ""), "")
    Case "ACCOUNT"      : h_user_update(c, m.nick, 1, irc_param(m, 0), "")
    Case "CHGHOST"      : h_user_update(c, m.nick, 2, irc_param(m, 0), irc_param(m, 1))
    Case "SETNAME"
    Case "BATCH"
        Dim ref As String = irc_param(m, 0)
        If Left(ref, 1) = "+" Then
            Dim bat_type As String = LCase(irc_param(m, 1))
            If bat_type = "chathistory" OrElse bat_type = "znc.in/playback" Then conns(c).hist_batches &= Mid(ref, 2) & " "
        ElseIf Left(ref, 1) = "-" Then
            conns(c).hist_batches = str_replace(conns(c).hist_batches, " " & Mid(ref, 2) & " ", " ")
        End If
    Case "ERROR"
        ev_error(c, "Server: " & irc_last(m))
    Case "WALLOPS"
        ev_status(c, "WALLOPS from " & m.nick & ": " & irc_last(m), LK_NOTICE)
    Case Else
        ev_status(c, m.cmd & " " & irc_params_from(m, 0), LK_SERVER)
    End Select
End Sub
