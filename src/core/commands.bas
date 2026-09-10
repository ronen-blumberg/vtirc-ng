' =============================================================================
' src/core/commands.bas -- /commands, aliases, sending text
'
' cmd_execute(buf, text) runs one input line in the context of a buffer:
'   "/cmd args"  -> command table, then user aliases, then the UI, then (if
'                   enabled) sent to the server as a raw command
'   "//text"     -> literal "/text" sent as a message
'   "text"       -> message to the buffer's channel / query
' =============================================================================

Type cmd_ctx
    buf    As Long
    c      As Long       ' connection of the buffer (-1 if none)
    target As String     ' channel / query name of the buffer ("" for server windows)
    cmd    As String     ' command name (lower case)
    args   As String
    depth  As Long       ' alias recursion depth
End Type

Type cmd_def
    nm        As String
    fn        As Sub(ByRef x As cmd_ctx)
    need      As Long    ' 0 none, 1 connection object, 2 registered (online)
    usage     As String
    help      As String
End Type

Const CMD_MAX = 200
Dim Shared cmds(0 To CMD_MAX - 1) As cmd_def
Dim Shared cmd_count As Long
Dim Shared alias_nm(Any) As String
Dim Shared alias_exp(Any) As String
Dim Shared alias_count As Long

Declare Sub cmd_run(ByRef x As cmd_ctx, ByRef text As String)

Sub cmd_reg(ByRef nm As String, fn As Sub(ByRef x As cmd_ctx), need As Long, ByRef usage As String, ByRef help As String)
    If cmd_count >= CMD_MAX Then Exit Sub
    cmds(cmd_count).nm = LCase(nm)
    cmds(cmd_count).fn = fn
    cmds(cmd_count).need = need
    cmds(cmd_count).usage = usage
    cmds(cmd_count).help = help
    cmd_count += 1
End Sub

Function cmd_find(ByRef nm As String) As Long
    Dim l As String = LCase(nm)
    Dim i As Long
    For i = 0 To cmd_count - 1
        If cmds(i).nm = l Then Return i
    Next i
    Return -1
End Function

' ---------------------------------------------------------------- aliases
Sub alias_load()
    alias_count = 0
    Erase alias_nm
    Erase alias_exp
    Dim i As Long
    For i = 0 To cfg_ini.cnt - 1
        If LCase(cfg_ini.ents(i).sec) = "alias" Then
            If alias_count > UBound(alias_nm) Then
                ReDim Preserve alias_nm(0 To alias_count * 2 + 7)
                ReDim Preserve alias_exp(0 To alias_count * 2 + 7)
            End If
            alias_nm(alias_count) = LCase(cfg_ini.ents(i).key)
            alias_exp(alias_count) = cfg_ini.ents(i).value
            alias_count += 1
        End If
    Next i
End Sub

Function alias_find(ByRef nm As String) As Long
    Dim l As String = LCase(nm)
    Dim i As Long
    For i = 0 To alias_count - 1
        If alias_nm(i) = l Then Return i
    Next i
    Return -1
End Function

' Expand $1..$9, $1- .. $9-, $chan $target $nick $me $network $server $$
Function alias_expand(ByRef x As cmd_ctx, ByRef tpl As String) As String
    Dim r As String
    Dim i As Long = 0
    Dim n As Long = Len(tpl)
    While i < n
        If tpl[i] <> Asc("$") OrElse i + 1 >= n Then
            r &= Chr(tpl[i]) : i += 1 : Continue While
        End If
        Dim nx As UByte = tpl[i + 1]
        If nx = Asc("$") Then
            r &= "$" : i += 2
        ElseIf nx >= Asc("1") AndAlso nx <= Asc("9") Then
            Dim k As Long = nx - Asc("0")
            If i + 2 < n AndAlso tpl[i + 2] = Asc("-") Then
                r &= str_rest(x.args, k - 1) : i += 3
            Else
                r &= str_word(x.args, k - 1) : i += 2
            End If
        Else
            Dim w As String
            Dim j As Long = i + 1
            While j < n AndAlso ((tpl[j] >= 97 AndAlso tpl[j] <= 122) OrElse (tpl[j] >= 65 AndAlso tpl[j] <= 90))
                j += 1
            Wend
            w = LCase(Mid(tpl, i + 2, j - i - 1))
            Select Case w
            Case "chan", "target" : r &= x.target
            Case "nick", "me"     : r &= conn_nick(x.c)
            Case "network"        : r &= IIf(conn_valid(x.c), conns(x.c).name, "")
            Case "server"         : r &= IIf(conn_valid(x.c), conns(x.c).srv.host, "")
            Case Else             : r &= "$" & Mid(tpl, i + 2, j - i - 1)
            End Select
            i = j
        End If
    Wend
    Return r
End Function

' ---------------------------------------------------------------- helpers
Sub cx_info(ByRef x As cmd_ctx, ByRef text As String)
    If buf_valid(x.buf) Then
        ev_line(x.buf, LK_INFO, 0, "--", "", text)
    Else
        ev_client(text)
    End If
End Sub

Sub cx_err(ByRef x As cmd_ctx, ByRef text As String)
    If buf_valid(x.buf) Then
        ev_line(x.buf, LK_ERROR, 0, "!!", "", text)
    Else
        ev_client(text, LK_ERROR)
    End If
End Sub

Sub cx_usage(ByRef x As cmd_ctx)
    Dim i As Long = cmd_find(x.cmd)
    If i >= 0 Then cx_err(x, "Usage: " & cmds(i).usage)
End Sub

' Channel named in the first argument, or the current channel. On success the
' first argument is consumed from x.args when it was a channel.
Function cx_chan(ByRef x As cmd_ctx, ByRef chan As String) As Byte
    Dim w As String = str_word(x.args, 0)
    If Len(w) > 0 AndAlso conn_is_channel(x.c, w) Then
        chan = w
        x.args = str_rest(x.args, 1)
        Return 1
    End If
    If buf_valid(x.buf) AndAlso bufs(x.buf).kind = BK_CHANNEL Then
        chan = bufs(x.buf).name
        Return 1
    End If
    cx_err(x, "No channel given and the current window is not a channel")
    Return 0
End Function

' Send a message / action / notice with splitting and local echo.
Sub cmd_say(ByRef x As cmd_ctx, ByRef target As String, ByRef text As String, kind As Long)
    If conn_online(x.c) = 0 Then cx_err(x, "Not connected") : Exit Sub
    If Len(target) = 0 OrElse Len(text) = 0 Then Exit Sub
    Dim c As Long = x.c
    Dim verb As String = IIf(kind = LK_NOTICE, "NOTICE", "PRIVMSG")
    Dim parts() As String
    Dim n As Long = conn_split_text(c, verb, target, text, IIf(kind = LK_ACTION, 9, 0), parts())
    Dim echo As Byte = IIf(conn_has_cap(c, "echo-message"), 0, 1)
    ' where our own line is shown
    Dim id As Long = buf_find(c, target)
    Dim i As Long
    For i = 0 To n - 1
        If kind = LK_ACTION Then
            conn_send(c, verb & " " & target & " :" & Chr(1) & "ACTION " & parts(i) & Chr(1))
        Else
            conn_send(c, verb & " " & target & " :" & parts(i))
        End If
        If echo Then
            Dim me As String = conns(c).nick
            If id >= 0 Then
                Select Case kind
                Case LK_ACTION : ev_line(id, LK_ACTION, LF_SELF, "*", me, me & " " & parts(i))
                Case LK_NOTICE : ev_line(id, LK_NOTICE, LF_SELF, "->-" & target & "-", me, parts(i))
                Case Else
                    Dim sym As String = IIf(bufs(id).kind = BK_CHANNEL, h_nick_symbol(id, me), "")
                    ev_line(id, LK_MSG, LF_SELF, "<" & sym & me & ">", me, parts(i))
                End Select
            Else
                Dim pf As String = IIf(kind = LK_NOTICE, "->-" & target & "-", "->" & target & "<-")
                ev_line(x.buf, kind, LF_SELF, pf, me, IIf(kind = LK_ACTION, me & " ", "") & parts(i))
            End If
        End If
    Next i
End Sub

' Update the network's autojoin list (when remember_chans is on) and save.
Private Sub cx_remember(ByRef x As cmd_ctx, ByRef chan As String, ByRef key As String, add As Byte)
    If cfg.remember_chans = 0 OrElse conn_valid(x.c) = 0 Then Exit Sub
    Dim ni As Long = conns(x.c).net_idx
    If ni < 0 Then Exit Sub
    If add Then
        net_add_autojoin(ni, chan & IIf(Len(key) > 0, " " & key, ""))
    Else
        net_remove_autojoin(ni, chan)
    End If
    config_save()
End Sub

' ---------------------------------------------------------------- connection
Private Function cx_parse_server(ByRef x As cmd_ctx, ByRef e As srv_entry, ByRef newconn As Byte) As Byte
    Dim a() As String
    Dim n As Long = str_words(x.args, a())
    Dim i As Long
    Dim got_port As Byte = 0
    e.host = "" : e.port = 6667 : e.tls = 0 : e.pass = ""
    newconn = 0
    For i = 0 To n - 1
        Dim t As String = a(i)
        Select Case LCase(t)
        Case "-m", "-new"            : newconn = 1
        Case "-tls", "-ssl", "--tls" : e.tls = 1
        Case Else
            If Len(e.host) = 0 Then
                e.host = t
            ElseIf got_port = 0 AndAlso (Left(t, 1) = "+" OrElse str_to_int(t, -1) > 0) Then
                If Left(t, 1) = "+" Then e.tls = 1 : t = Mid(t, 2)
                e.port = str_to_int(t, 6667)
                got_port = 1
            Else
                e.pass = t
            End If
        End Select
    Next i
    If Len(e.host) = 0 Then Return 0
    If got_port = 0 AndAlso e.tls Then e.port = 6697
    Return 1
End Function

Sub c_server(ByRef x As cmd_ctx)
    Dim e As srv_entry
    Dim nc As Byte
    If cx_parse_server(x, e, nc) = 0 Then cx_usage(x) : Exit Sub
    Dim c As Long = x.c
    If nc OrElse conn_valid(c) = 0 Then
        c = conn_new(-1, e.host)
        If c < 0 Then cx_err(x, "Too many connections") : Exit Sub
        ui_request_focus(conns(c).status_buf)
    Else
        If conns(c).st <> CS_OFFLINE Then
            conn_disconnect(c, "Changing servers")
            ' drop immediately so the new attempt can start
            net_io_close(conns(c).sock, conns(c).tls)
            conns(c).closing_at = 0
            conns(c).st = CS_OFFLINE
        End If
    End If
    conns(c).srv = e
    conns(c).use_adhoc = 1
    conn_connect(c)
End Sub

Sub c_connect(ByRef x As cmd_ctx)
    Dim nm As String = Trim(x.args)
    If Len(nm) = 0 Then
        If conn_valid(x.c) Then conn_connect(x.c) Else cx_usage(x)
        Exit Sub
    End If
    Dim ni As Long = net_find(nm)
    If ni < 0 Then
        ' not a network name: treat as a new server connection
        x.args = "-m " & x.args
        c_server(x)
        Exit Sub
    End If
    Dim c As Long = conn_find(nets(ni).name)
    If c < 0 Then c = conn_new(ni, nets(ni).name)
    If c < 0 Then cx_err(x, "Too many connections") : Exit Sub
    ui_request_focus(conns(c).status_buf)
    conn_connect(c)
End Sub

Sub c_disconnect(ByRef x As cmd_ctx)
    If conn_valid(x.c) = 0 Then cx_err(x, "No connection in this window") : Exit Sub
    conn_disconnect(x.c, x.args)
End Sub

Sub c_reconnect(ByRef x As cmd_ctx)
    If conn_valid(x.c) = 0 Then cx_err(x, "No connection in this window") : Exit Sub
    Dim c As Long = x.c
    If conns(c).st = CS_ONLINE OrElse conns(c).st = CS_REGISTERING Then
        conn_send_now(c, "QUIT :Reconnecting")
    End If
    net_io_close(conns(c).sock, conns(c).tls)
    If conns(c).job <> 0 Then net_job_cancel(conns(c).job) : conns(c).job = 0
    conns(c).closing_at = 0
    conns(c).st = CS_OFFLINE
    conns(c).reconnect_n = 0
    conn_connect(c)
End Sub

Sub c_quit(ByRef x As cmd_ctx)
    If conn_valid(x.c) Then conn_disconnect(x.c, x.args)
End Sub

Sub c_exit(ByRef x As cmd_ctx)
    Dim c As Long
    For c = 0 To CONN_MAX - 1
        If conns(c).alive Then conn_disconnect(c, x.args)
    Next c
    ui_request_exit()
End Sub

' ---------------------------------------------------------------- messages
Sub c_msg(ByRef x As cmd_ctx)
    Dim tgt As String = str_word(x.args, 0)
    Dim txt As String = str_rest(x.args, 1)
    If Len(tgt) = 0 OrElse Len(txt) = 0 Then cx_usage(x) : Exit Sub
    cmd_say(x, tgt, txt, LK_MSG)
End Sub

Sub c_notice(ByRef x As cmd_ctx)
    Dim tgt As String = str_word(x.args, 0)
    Dim txt As String = str_rest(x.args, 1)
    If Len(tgt) = 0 OrElse Len(txt) = 0 Then cx_usage(x) : Exit Sub
    cmd_say(x, tgt, txt, LK_NOTICE)
End Sub

Sub c_me(ByRef x As cmd_ctx)
    If Len(x.target) = 0 Then cx_err(x, "/me works in channel and query windows") : Exit Sub
    If Len(x.args) = 0 Then cx_usage(x) : Exit Sub
    If bufs(x.buf).kind = BK_DCC Then dcc_chat_send(x.buf, Chr(1) & "ACTION " & x.args & Chr(1)) : Exit Sub
    cmd_say(x, x.target, x.args, LK_ACTION)
End Sub

Sub c_describe(ByRef x As cmd_ctx)
    Dim tgt As String = str_word(x.args, 0)
    Dim txt As String = str_rest(x.args, 1)
    If Len(tgt) = 0 OrElse Len(txt) = 0 Then cx_usage(x) : Exit Sub
    cmd_say(x, tgt, txt, LK_ACTION)
End Sub

Sub c_say(ByRef x As cmd_ctx)
    If Len(x.target) = 0 Then cx_err(x, "Not a channel or query window (use /msg <target> <text>)") : Exit Sub
    If Len(x.args) = 0 Then Exit Sub
    If bufs(x.buf).kind = BK_CHANNEL AndAlso bufs(x.buf).joined = 0 Then cx_err(x, "You are not in " & x.target) : Exit Sub
    cmd_say(x, x.target, x.args, LK_MSG)
End Sub

Sub c_query(ByRef x As cmd_ctx)
    Dim nick As String = str_word(x.args, 0)
    Dim txt As String = str_rest(x.args, 1)
    If Len(nick) = 0 Then cx_usage(x) : Exit Sub
    If conn_valid(x.c) = 0 Then cx_err(x, "No connection in this window") : Exit Sub
    If conn_is_channel(x.c, nick) Then cx_err(x, "Use /join for channels") : Exit Sub
    Dim id As Long = buf_find_kind(x.c, BK_QUERY, nick)
    If id < 0 Then
        id = buf_new(x.c, BK_QUERY, nick, 1)
        ev_replay_log(id)
    Else
        ui_request_focus(id)
    End If
    If Len(txt) > 0 Then cmd_say(x, nick, txt, LK_MSG)
End Sub

Sub c_amsg(ByRef x As cmd_ctx)
    If Len(x.args) = 0 Then cx_usage(x) : Exit Sub
    Dim i As Long
    For i = 0 To BUF_MAX - 1
        If bufs(i).alive AndAlso bufs(i).conn_id = x.c AndAlso bufs(i).kind = BK_CHANNEL AndAlso bufs(i).joined Then
            Dim y As cmd_ctx = x
            y.buf = i
            cmd_say(y, bufs(i).name, x.args, IIf(x.cmd = "ame", LK_ACTION, LK_MSG))
        End If
    Next i
End Sub

Sub c_ctcp(ByRef x As cmd_ctx)
    Dim tgt As String = str_word(x.args, 0)
    Dim what As String = UCase(str_word(x.args, 1))
    Dim rest As String = str_rest(x.args, 2)
    If Len(tgt) = 0 OrElse Len(what) = 0 Then cx_usage(x) : Exit Sub
    If what = "PING" AndAlso Len(rest) = 0 Then rest = LTrim(Str(clock_s()))
    conn_send(x.c, "PRIVMSG " & tgt & " :" & Chr(1) & what & IIf(Len(rest) > 0, " " & rest, "") & Chr(1))
    cx_info(x, "CTCP " & what & " sent to " & tgt)
End Sub

Sub c_ping(ByRef x As cmd_ctx)
    Dim tgt As String = str_word(x.args, 0)
    If Len(tgt) = 0 Then
        cx_info(x, "Lag to " & conns(x.c).name & ": " & IIf(conns(x.c).lag > 0, _
                LTrim(Str(CLng(conns(x.c).lag * 1000))) & " ms", "not measured yet"))
        Exit Sub
    End If
    x.args = tgt & " PING"
    c_ctcp(x)
End Sub

' Services shortcuts: /ns /cs /ms /hs /os /bs and the long forms.
Sub c_service(ByRef x As cmd_ctx)
    Dim svc As String
    Select Case x.cmd
    Case "ns", "nickserv" : svc = "NickServ"
    Case "cs", "chanserv" : svc = "ChanServ"
    Case "ms", "memoserv" : svc = "MemoServ"
    Case "hs", "hostserv" : svc = "HostServ"
    Case "os", "operserv" : svc = "OperServ"
    Case "bs", "botserv"  : svc = "BotServ"
    End Select
    If Len(x.args) = 0 Then cx_usage(x) : Exit Sub
    cmd_say(x, svc, x.args, LK_MSG)
End Sub

Sub c_identify(ByRef x As cmd_ctx)
    If Len(x.args) = 0 Then
        Dim ni As Long = conns(x.c).net_idx
        If ni >= 0 AndAlso Len(nets(ni).login_pass) > 0 Then
            x.args = IIf(Len(nets(ni).login_user) > 0, nets(ni).login_user & " ", "") & nets(ni).login_pass
        Else
            cx_usage(x) : Exit Sub
        End If
    End If
    conn_send(x.c, "PRIVMSG NickServ :IDENTIFY " & x.args)
    cx_info(x, "Identification sent to NickServ")
End Sub

Sub c_ghost(ByRef x As cmd_ctx)
    If Len(x.args) = 0 Then cx_usage(x) : Exit Sub
    conn_send(x.c, "PRIVMSG NickServ :" & UCase(x.cmd) & " " & x.args)
End Sub

' ---------------------------------------------------------------- information
Sub c_whois(ByRef x As cmd_ctx)
    Dim nick As String = str_word(x.args, 0)
    If Len(nick) = 0 Then
        If buf_valid(x.buf) AndAlso bufs(x.buf).kind = BK_QUERY Then nick = bufs(x.buf).name Else cx_usage(x) : Exit Sub
    End If
    Dim second As String = str_word(x.args, 1)
    If x.cmd = "wii" Then second = nick
    conns(x.c).whois_nick = ""
    conn_send(x.c, "WHOIS " & nick & IIf(Len(second) > 0, " " & second, ""))
End Sub

Sub c_whowas(ByRef x As cmd_ctx)
    If Len(x.args) = 0 Then cx_usage(x) : Exit Sub
    conn_send(x.c, "WHOWAS " & x.args)
End Sub

Sub c_who(ByRef x As cmd_ctx)
    Dim mask As String = Trim(x.args)
    If Len(mask) = 0 Then mask = x.target
    If Len(mask) = 0 Then cx_usage(x) : Exit Sub
    If InStr(who_print, " " & x.c & " ") = 0 Then who_print &= " " & x.c & " "
    conn_send(x.c, "WHO " & mask)
End Sub

Sub c_names(ByRef x As cmd_ctx)
    Dim chan As String
    If cx_chan(x, chan) = 0 Then Exit Sub
    Dim id As Long = buf_find_kind(x.c, BK_CHANNEL, chan)
    If id >= 0 AndAlso bufs(id).joined Then bufs(id).names_pending = 1
    conn_send(x.c, "NAMES " & chan)
End Sub

Sub c_topic(ByRef x As cmd_ctx)
    Dim chan As String
    If cx_chan(x, chan) = 0 Then Exit Sub
    If Len(x.args) = 0 Then
        Dim id As Long = buf_find_kind(x.c, BK_CHANNEL, chan)
        If id >= 0 AndAlso Len(bufs(id).topic) > 0 AndAlso x.cmd = "topic" Then
            cx_info(x, "Topic of " & chan & ": " & bufs(id).topic)
            If Len(bufs(id).topic_by) > 0 Then cx_info(x, "Set by " & bufs(id).topic_by & _
                IIf(bufs(id).topic_time > 0, " on " & time_format(bufs(id).topic_time, "%Y-%m-%d %H:%M"), ""))
        Else
            conn_send(x.c, "TOPIC " & chan)
        End If
    Else
        conn_send(x.c, "TOPIC " & chan & " :" & x.args)
    End If
End Sub

Sub c_list(ByRef x As cmd_ctx)
    conns(x.c).ls_active = 1
    conns(x.c).ls_done = 0
    conns(x.c).ls_count = 0
    conn_send(x.c, "LIST" & IIf(Len(x.args) > 0, " " & x.args, ""))
    cx_info(x, "Requesting the channel list (F4 opens the channel browser)")
End Sub

' Plain server queries: /motd /lusers /version /time /stats /links /admin /info /map
Sub c_server_query(ByRef x As cmd_ctx)
    conn_send(x.c, UCase(x.cmd) & IIf(Len(x.args) > 0, " " & x.args, ""))
End Sub

Sub c_lag(ByRef x As cmd_ctx)
    x.args = ""
    c_ping(x)
End Sub

' ---------------------------------------------------------------- channels
Sub c_join(ByRef x As cmd_ctx)
    Dim chans As String = str_word(x.args, 0)
    Dim keys As String = str_word(x.args, 1)
    If Len(chans) = 0 Then
        ' rejoin the current (parted) channel
        If buf_valid(x.buf) AndAlso bufs(x.buf).kind = BK_CHANNEL Then
            chans = bufs(x.buf).name
            keys = bufs(x.buf).chkey
        Else
            cx_usage(x) : Exit Sub
        End If
    End If
    Dim a() As String
    Dim n As Long = str_split(chans, ",", a())
    Dim kk() As String
    Dim nk As Long = str_split(keys, ",", kk())
    Dim lst As String = ""
    Dim i As Long
    For i = 0 To n - 1
        Dim ch As String = Trim(a(i))
        If Len(ch) = 0 Then Continue For
        If conn_is_channel(x.c, ch) = 0 Then ch = "#" & ch
        Dim ky As String = IIf(i < nk, Trim(kk(i)), "")
        If Len(keys) = 0 Then ky = ""
        Dim lc As String = irc_lc(ch, conns(x.c).cm)
        If InStr(conns(x.c).focus_joins, " " & lc & " ") = 0 Then conns(x.c).focus_joins &= lc & " "
        Dim id As Long = buf_find_kind(x.c, BK_CHANNEL, ch)
        If id >= 0 Then
            ui_request_focus(id)
            If bufs(id).joined Then Continue For
        End If
        lst &= IIf(Len(lst) > 0, ",", "") & ch & IIf(Len(ky) > 0, " " & ky, "")
        cx_remember(x, ch, ky, 1)
    Next i
    conn_join_many(x.c, lst)
End Sub

Sub c_part(ByRef x As cmd_ctx)
    Dim chan As String
    If cx_chan(x, chan) = 0 Then Exit Sub
    Dim reason As String = IIf(Len(x.args) > 0, x.args, cfg.part_msg)
    Dim id As Long = buf_find_kind(x.c, BK_CHANNEL, chan)
    Dim lc As String = irc_lc(chan, conns(x.c).cm)
    cx_remember(x, chan, "", 0)
    If id >= 0 AndAlso bufs(id).joined = 0 Then
        buf_close(id)
        Exit Sub
    End If
    If InStr(conns(x.c).close_on_part, " " & lc & " ") = 0 Then conns(x.c).close_on_part &= lc & " "
    conn_send(x.c, "PART " & chan & IIf(Len(reason) > 0, " :" & reason, ""))
End Sub

Sub c_cycle(ByRef x As cmd_ctx)
    Dim chan As String
    If cx_chan(x, chan) = 0 Then Exit Sub
    Dim id As Long = buf_find_kind(x.c, BK_CHANNEL, chan)
    Dim ky As String = IIf(id >= 0, bufs(id).chkey, "")
    conn_send(x.c, "PART " & chan & " :Cycling")
    conn_send(x.c, "JOIN " & chan & IIf(Len(ky) > 0, " " & ky, ""))
End Sub

Sub c_invite(ByRef x As cmd_ctx)
    Dim nick As String = str_word(x.args, 0)
    If Len(nick) = 0 Then cx_usage(x) : Exit Sub
    x.args = str_rest(x.args, 1)
    Dim chan As String
    If cx_chan(x, chan) = 0 Then Exit Sub
    conn_send(x.c, "INVITE " & nick & " " & chan)
End Sub

Sub c_knock(ByRef x As cmd_ctx)
    If Len(x.args) = 0 Then cx_usage(x) : Exit Sub
    Dim chan As String = str_word(x.args, 0)
    Dim kmsg As String = str_rest(x.args, 1)
    conn_send(x.c, "KNOCK " & chan & IIf(Len(kmsg) > 0, " :" & kmsg, ""))
End Sub

Sub c_close(ByRef x As cmd_ctx)
    If buf_valid(x.buf) = 0 Then Exit Sub
    Select Case bufs(x.buf).kind
    Case BK_CHANNEL
        If bufs(x.buf).joined AndAlso conn_online(x.c) Then
            x.args = bufs(x.buf).name & IIf(Len(x.args) > 0, " " & x.args, "")
            c_part(x)
        Else
            cx_remember(x, bufs(x.buf).name, "", 0)
            buf_close(x.buf)
        End If
    Case BK_STATUS
        If conn_valid(x.c) Then
            If conns(x.c).st <> CS_OFFLINE Then conn_disconnect(x.c, x.args)
            conn_free(x.c)
        End If
    Case Else
        buf_close(x.buf)
    End Select
End Sub

' ---------------------------------------------------------------- moderation
Sub c_mode(ByRef x As cmd_ctx)
    If Len(x.args) = 0 Then
        If Len(x.target) > 0 AndAlso conn_is_channel(x.c, x.target) Then
            conn_send(x.c, "MODE " & x.target)
        Else
            cx_usage(x)
        End If
        Exit Sub
    End If
    Dim first As String = str_word(x.args, 0)
    If conn_is_channel(x.c, first) OrElse irc_eq(first, conns(x.c).nick, conns(x.c).cm) Then
        conn_send(x.c, "MODE " & x.args)
    ElseIf Len(x.target) > 0 AndAlso conn_is_channel(x.c, x.target) Then
        conn_send(x.c, "MODE " & x.target & " " & x.args)
    Else
        conn_send(x.c, "MODE " & x.args)
    End If
End Sub

Sub c_umode(ByRef x As cmd_ctx)
    If Len(x.args) = 0 Then cx_info(x, "Your user mode: +" & conns(x.c).umodes) : Exit Sub
    conn_send(x.c, "MODE " & conns(x.c).nick & " " & x.args)
End Sub

' /op /deop /voice /devoice /halfop /dehalfop nick...
Sub c_opvoice(ByRef x As cmd_ctx)
    Dim chan As String
    If cx_chan(x, chan) = 0 Then Exit Sub
    Dim a() As String
    Dim n As Long = str_words(x.args, a())
    If n = 0 Then cx_usage(x) : Exit Sub
    Dim sign As String = IIf(Left(x.cmd, 2) = "de", "-", "+")
    Dim mc As String
    Select Case x.cmd
    Case "op", "deop"         : mc = "o"
    Case "voice", "devoice"   : mc = "v"
    Case "halfop", "dehalfop" : mc = "h"
    End Select
    Dim per As Long = IIf(conns(x.c).modes_max > 0, conns(x.c).modes_max, 3)
    Dim i As Long = 0
    While i < n
        Dim cnt As Long = 0
        Dim nicks As String = ""
        While i < n AndAlso cnt < per
            nicks &= " " & a(i)
            i += 1 : cnt += 1
        Wend
        conn_send(x.c, "MODE " & chan & " " & sign & String(cnt, mc) & nicks)
    Wend
End Sub

Sub c_kick(ByRef x As cmd_ctx)
    Dim chan As String
    If cx_chan(x, chan) = 0 Then Exit Sub
    Dim nick As String = str_word(x.args, 0)
    If Len(nick) = 0 Then cx_usage(x) : Exit Sub
    Dim reason As String = str_rest(x.args, 1)
    conn_send(x.c, "KICK " & chan & " " & nick & IIf(Len(reason) > 0, " :" & reason, ""))
End Sub

' Ban mask for a nick: *!*@host when the host is known, else nick!*@*
Function cx_ban_mask(ByRef x As cmd_ctx, ByRef chan As String, ByRef who As String) As String
    If InStr(who, "!") > 0 OrElse InStr(who, "@") > 0 OrElse InStr(who, "*") > 0 Then Return who
    Dim id As Long = buf_find_kind(x.c, BK_CHANNEL, chan)
    If id >= 0 Then
        Dim ui As Long = user_find(id, who)
        If ui >= 0 AndAlso Len(bufs(id).users(ui).host) > 0 Then Return "*!*@" & bufs(id).users(ui).host
    End If
    Return who & "!*@*"
End Function

Sub c_ban(ByRef x As cmd_ctx)
    Dim chan As String
    If cx_chan(x, chan) = 0 Then Exit Sub
    Dim who As String = str_word(x.args, 0)
    Dim mc As String = IIf(x.cmd = "quiet" OrElse x.cmd = "unquiet", "q", "b")
    If Len(who) = 0 Then
        conn_send(x.c, "MODE " & chan & " +" & mc)
        Exit Sub
    End If
    Dim sign As String = IIf(Left(x.cmd, 2) = "un", "-", "+")
    conn_send(x.c, "MODE " & chan & " " & sign & mc & " " & cx_ban_mask(x, chan, who))
End Sub

Sub c_kickban(ByRef x As cmd_ctx)
    Dim chan As String
    If cx_chan(x, chan) = 0 Then Exit Sub
    Dim nick As String = str_word(x.args, 0)
    If Len(nick) = 0 Then cx_usage(x) : Exit Sub
    Dim reason As String = str_rest(x.args, 1)
    conn_send(x.c, "MODE " & chan & " +b " & cx_ban_mask(x, chan, nick))
    conn_send(x.c, "KICK " & chan & " " & nick & IIf(Len(reason) > 0, " :" & reason, ""))
End Sub

Sub c_banlist(ByRef x As cmd_ctx)
    Dim chan As String
    If cx_chan(x, chan) = 0 Then Exit Sub
    Select Case x.cmd
    Case "banlist"    : conn_send(x.c, "MODE " & chan & " +b")
    Case "exceptlist" : conn_send(x.c, "MODE " & chan & " +e")
    Case "invitelist" : conn_send(x.c, "MODE " & chan & " +I")
    End Select
End Sub

' ---------------------------------------------------------------- self
Sub c_nick(ByRef x As cmd_ctx)
    Dim nn As String = str_word(x.args, 0)
    If Len(nn) = 0 Then cx_usage(x) : Exit Sub
    If conn_valid(x.c) = 0 OrElse conns(x.c).st = CS_OFFLINE OrElse conns(x.c).st = CS_WAIT_RECONNECT Then
        ' offline: becomes the nick for the next connection of this network
        If conn_valid(x.c) AndAlso conns(x.c).net_idx >= 0 Then
            nets(conns(x.c).net_idx).nick = nn
            config_save()
        Else
            cfg.nick = nn
            config_save()
        End If
        If conn_valid(x.c) Then conns(x.c).nick = nn
        cx_info(x, "Nick for the next connection: " & nn)
        Exit Sub
    End If
    conn_send(x.c, "NICK " & nn)
End Sub

Sub c_away(ByRef x As cmd_ctx)
    Dim amsg As String = IIf(Len(x.args) > 0, x.args, cfg.away_msg)
    Dim all_ As Byte = IIf(x.cmd = "aaway", 1, 0)
    Dim c As Long
    For c = 0 To CONN_MAX - 1
        If conn_online(c) AndAlso (all_ OrElse c = x.c) Then
            conns(c).away_msg = amsg
            conn_send(c, "AWAY :" & amsg)
        End If
    Next c
End Sub

Sub c_back(ByRef x As cmd_ctx)
    Dim all_ As Byte = IIf(x.cmd = "aback", 1, 0)
    Dim c As Long
    For c = 0 To CONN_MAX - 1
        If conn_online(c) AndAlso (all_ OrElse c = x.c) Then
            conns(c).away_msg = ""
            conn_send(c, "AWAY")
        End If
    Next c
End Sub

Sub c_setname(ByRef x As cmd_ctx)
    If Len(x.args) = 0 Then cx_usage(x) : Exit Sub
    If conn_has_cap(x.c, "setname") = 0 Then cx_err(x, "This server does not support changing the real name") : Exit Sub
    conn_send(x.c, "SETNAME :" & x.args)
End Sub

' ---------------------------------------------------------------- client
Sub c_raw(ByRef x As cmd_ctx)
    If Len(x.args) = 0 Then cx_usage(x) : Exit Sub
    conn_send(x.c, x.args)
End Sub

Sub c_echo(ByRef x As cmd_ctx)
    cx_info(x, x.args)
End Sub

Sub c_clear(ByRef x As cmd_ctx)
    If LCase(Trim(x.args)) = "all" Then
        Dim i As Long
        For i = 0 To BUF_MAX - 1
            If bufs(i).alive Then buf_clear(i)
        Next i
    Else
        buf_clear(x.buf)
    End If
End Sub

Sub c_ignore(ByRef x As cmd_ctx)
    Dim mask As String = str_word(x.args, 0)
    If Len(mask) = 0 Then
        If ignore_count = 0 Then cx_info(x, "Ignore list is empty") : Exit Sub
        cx_info(x, "Ignore list:")
        Dim i As Long
        For i = 0 To ignore_count - 1
            cx_info(x, "  " & ignores(i).mask & "  [" & ignore_types_text(ignores(i).types) & "]")
        Next i
        Exit Sub
    End If
    Dim types As Long = ignore_types_from(str_rest(x.args, 1))
    Dim k As Long = ignore_add(mask, types)
    ignore_save()
    config_save()
    cx_info(x, "Ignoring " & ignores(k).mask & " [" & ignore_types_text(types) & "]")
End Sub

Sub c_unignore(ByRef x As cmd_ctx)
    Dim mask As String = str_word(x.args, 0)
    If Len(mask) = 0 Then cx_usage(x) : Exit Sub
    If ignore_remove(mask) Then
        ignore_save()
        config_save()
        cx_info(x, "No longer ignoring " & mask)
    Else
        cx_err(x, mask & " is not on the ignore list")
    End If
End Sub

Sub c_highlight(ByRef x As cmd_ctx)
    Dim op As String = LCase(str_word(x.args, 0))
    Dim w As String = utf8_lcase(str_rest(x.args, 1))
    Dim i As Long
    Select Case op
    Case "add"
        If Len(w) = 0 Then cx_usage(x) : Exit Sub
        For i = 0 To hl_count - 1
            If hl_words(i) = w Then cx_info(x, "Already highlighted: " & w) : Exit Sub
        Next i
        If hl_count > UBound(hl_words) Then ReDim Preserve hl_words(0 To hl_count * 2 + 7)
        hl_words(hl_count) = w
        hl_count += 1
        highlight_save() : config_save()
        cx_info(x, "Highlight word added: " & w)
    Case "del", "remove"
        For i = 0 To hl_count - 1
            If hl_words(i) = w Then
                Dim k As Long
                For k = i To hl_count - 2
                    hl_words(k) = hl_words(k + 1)
                Next k
                hl_count -= 1
                highlight_save() : config_save()
                cx_info(x, "Highlight word removed: " & w)
                Exit Sub
            End If
        Next i
        cx_err(x, "Not a highlight word: " & w)
    Case Else
        If hl_count = 0 Then cx_info(x, "No highlight words (your nick always highlights)") : Exit Sub
        Dim lst As String
        For i = 0 To hl_count - 1
            lst &= IIf(i > 0, ", ", "") & hl_words(i)
        Next i
        cx_info(x, "Highlight words: " & lst)
    End Select
End Sub

Sub c_alias(ByRef x As cmd_ctx)
    Dim op As String = LCase(str_word(x.args, 0))
    Dim nm As String = LCase(str_word(x.args, 1))
    Dim i As Long
    Select Case op
    Case "add", "set"
        Dim ex As String = str_rest(x.args, 2)
        If Len(nm) = 0 OrElse Len(ex) = 0 Then cx_usage(x) : Exit Sub
        If Left(nm, 1) = "/" Then nm = Mid(nm, 2)
        ini_set(cfg_ini, "alias", nm, ex)
        alias_load() : config_save()
        cx_info(x, "Alias /" & nm & " = " & ex)
    Case "del", "remove"
        If Left(nm, 1) = "/" Then nm = Mid(nm, 2)
        ini_del_key(cfg_ini, "alias", nm)
        alias_load() : config_save()
        cx_info(x, "Alias /" & nm & " removed")
    Case Else
        If alias_count = 0 Then
            cx_info(x, "No aliases. Example: /alias add ghost /ns ghost $1 $2-")
            Exit Sub
        End If
        For i = 0 To alias_count - 1
            cx_info(x, "/" & alias_nm(i) & " = " & alias_exp(i))
        Next i
    End Select
End Sub

Sub c_autojoin(ByRef x As cmd_ctx)
    If conn_valid(x.c) = 0 OrElse conns(x.c).net_idx < 0 Then cx_err(x, "This window does not belong to a saved network") : Exit Sub
    Dim ni As Long = conns(x.c).net_idx
    Dim op As String = LCase(str_word(x.args, 0))
    Dim ch As String = str_word(x.args, 1)
    Dim ky As String = str_word(x.args, 2)
    Select Case op
    Case "add"
        If Len(ch) = 0 Then
            If bufs(x.buf).kind = BK_CHANNEL Then ch = bufs(x.buf).name Else cx_usage(x) : Exit Sub
        End If
        net_add_autojoin(ni, ch & IIf(Len(ky) > 0, " " & ky, ""))
        config_save()
        cx_info(x, ch & " added to the autojoin list of " & nets(ni).name)
    Case "del", "remove"
        If Len(ch) = 0 Then
            If bufs(x.buf).kind = BK_CHANNEL Then ch = bufs(x.buf).name Else cx_usage(x) : Exit Sub
        End If
        net_remove_autojoin(ni, ch)
        config_save()
        cx_info(x, ch & " removed from the autojoin list of " & nets(ni).name)
    Case Else
        Dim lst As String
        Dim i As Long
        For i = 0 To nets(ni).aj_count - 1
            lst &= IIf(i > 0, ", ", "") & str_word(nets(ni).autojoin(i), 0)
        Next i
        cx_info(x, "Autojoin for " & nets(ni).name & ": " & IIf(Len(lst) > 0, lst, "(none)"))
    End Select
End Sub

Sub c_perform(ByRef x As cmd_ctx)
    If conn_valid(x.c) = 0 OrElse conns(x.c).net_idx < 0 Then cx_err(x, "This window does not belong to a saved network") : Exit Sub
    Dim ni As Long = conns(x.c).net_idx
    Dim op As String = LCase(str_word(x.args, 0))
    Dim i As Long
    With nets(ni)
        Select Case op
        Case "add"
            Dim cm As String = str_rest(x.args, 1)
            If Len(cm) = 0 Then cx_usage(x) : Exit Sub
            If .pf_count > UBound(.perform) Then ReDim Preserve .perform(0 To .pf_count * 2 + 7)
            .perform(.pf_count) = cm
            .pf_count += 1
            config_save()
            cx_info(x, "Perform #" & .pf_count & ": " & cm)
        Case "del", "remove"
            Dim k As Long = str_to_int(str_word(x.args, 1), 0)
            If k < 1 OrElse k > .pf_count Then cx_err(x, "No such perform entry") : Exit Sub
            For i = k - 1 To .pf_count - 2
                .perform(i) = .perform(i + 1)
            Next i
            .pf_count -= 1
            config_save()
            cx_info(x, "Perform entry " & k & " removed")
        Case Else
            If .pf_count = 0 Then cx_info(x, "No perform commands for " & .name & " (they run after connecting)") : Exit Sub
            For i = 0 To .pf_count - 1
                cx_info(x, (i + 1) & ". " & .perform(i))
            Next i
        End Select
    End With
End Sub

Sub c_set(ByRef x As cmd_ctx)
    settings_to_ini()
    Dim key As String = LCase(str_word(x.args, 0))
    Dim value As String = str_rest(x.args, 1)
    Dim i As Long
    If Len(key) = 0 OrElse InStr(key, "*") > 0 Then
        Dim pat As String = IIf(Len(key) > 0, key, "*")
        For i = 0 To cfg_ini.cnt - 1
            If LCase(cfg_ini.ents(i).sec) = "global" AndAlso wild_match(pat, cfg_ini.ents(i).key) Then
                Dim v As String = cfg_ini.ents(i).value
                If InStr(cfg_ini.ents(i).key, "pass") > 0 AndAlso Len(v) > 0 Then v = "********"
                cx_info(x, cfg_ini.ents(i).key & " = " & v)
            End If
        Next i
        Exit Sub
    End If
    If ini_has(cfg_ini, "global", key) = 0 Then cx_err(x, "Unknown setting: " & key & " (/set lists them)") : Exit Sub
    If Len(value) = 0 Then
        cx_info(x, key & " = " & ini_get(cfg_ini, "global", key))
        Exit Sub
    End If
    If value = """""" Then value = ""
    ini_set(cfg_ini, "global", key, value)
    settings_from_ini()
    buf_default_hist = cfg.scrollback
    config_save()
    cx_info(x, key & " = " & ini_get(cfg_ini, "global", key))
    ui_settings_changed()
End Sub

Sub c_cert(ByRef x As cmd_ctx)
    If conn_valid(x.c) = 0 Then cx_err(x, "No connection in this window") : Exit Sub
    Dim op As String = LCase(str_word(x.args, 0))
    With conns(x.c)
        Select Case op
        Case "accept"
            If Len(.cert_new_fp) = 0 Then cx_err(x, "No changed certificate is waiting for approval") : Exit Sub
            cert_pin_set(.srv.host, .srv.port, .cert_new_fp)
            cx_info(x, "New certificate for " & .srv.host & " accepted: " & .cert_new_fp)
            .cert_new_fp = ""
            .user_quit = 0
            conn_connect(x.c)
        Case "forget"
            ini_del_key(cert_ini, "pins", LCase(.srv.host) & ":" & .srv.port)
            ini_save(cert_ini, cert_path)
            cx_info(x, "Certificate pin for " & .srv.host & " removed")
        Case Else
            Dim p As String = cert_pin_get(.srv.host, .srv.port)
            cx_info(x, "Server  : " & .srv.host & ":" & .srv.port & IIf(.srv.tls, " (TLS)", " (plain)"))
            cx_info(x, "Current : " & IIf(Len(.tls_fp) > 0, .tls_fp, "(none)"))
            cx_info(x, "Pinned  : " & IIf(Len(p) > 0, p, "(none)"))
        End Select
    End With
End Sub

Sub c_charset(ByRef x As cmd_ctx)
    If conn_valid(x.c) = 0 Then cx_err(x, "No connection in this window") : Exit Sub
    Dim nm As String = LCase(Trim(x.args))
    If Len(nm) = 0 Then
        cx_info(x, "Charset: " & IIf(conns(x.c).send_legacy, charset_name(conns(x.c).charset), "utf-8 (fallback " & charset_name(conns(x.c).charset) & ")"))
        Exit Sub
    End If
    If nm = "utf-8" OrElse nm = "utf8" Then
        conns(x.c).send_legacy = 0
        conns(x.c).charset = CHARSET_CP1252
    Else
        conns(x.c).send_legacy = 1
        conns(x.c).charset = charset_from_name(nm)
    End If
    If conns(x.c).net_idx >= 0 Then nets(conns(x.c).net_idx).charset = nm : config_save()
    cx_info(x, "Charset set to " & nm)
End Sub

Sub c_dcc(ByRef x As cmd_ctx)
    ' no arguments: the transfers window (UI), else the text commands
    If Len(Trim(x.args)) = 0 AndAlso ui_command(x.buf, "transfers", "") Then Exit Sub
    dcc_command(x.c, x.buf, x.args)
End Sub

Sub c_help(ByRef x As cmd_ctx)
    Dim nm As String = LCase(str_word(x.args, 0))
    If Left(nm, 1) = "/" Then nm = Mid(nm, 2)
    If Len(nm) > 0 Then
        Dim i As Long = cmd_find(nm)
        If i < 0 Then
            Dim a As Long = alias_find(nm)
            If a >= 0 Then cx_info(x, "/" & nm & " is an alias for: " & alias_exp(a)) : Exit Sub
            cx_err(x, "No such command: /" & nm)
            Exit Sub
        End If
        cx_info(x, cmds(i).usage)
        cx_info(x, "  " & cmds(i).help)
        Exit Sub
    End If
    cx_info(x, "Commands (type /help <command> for details, F1 for the manual):")
    ' sorted list in rows
    Dim names() As String
    ReDim names(0 To cmd_count - 1)
    Dim i As Long
    Dim j As Long
    For i = 0 To cmd_count - 1
        names(i) = cmds(i).nm
    Next i
    For i = 1 To cmd_count - 1
        Dim t As String = names(i)
        j = i - 1
        While j >= 0 AndAlso names(j) > t
            names(j + 1) = names(j)
            j -= 1
        Wend
        names(j + 1) = t
    Next i
    Dim row As String
    For i = 0 To cmd_count - 1
        row &= "/" & names(i) & String(IIf(Len(names(i)) < 11, 11 - Len(names(i)), 1), " ")
        If (i + 1) Mod 7 = 0 Then cx_info(x, "  " & RTrim(row)) : row = ""
    Next i
    If Len(row) > 0 Then cx_info(x, "  " & RTrim(row))
End Sub

' ---------------------------------------------------------------- dispatch
Private Sub cmd_fill_ctx(ByRef x As cmd_ctx, buf_id As Long)
    x.buf = buf_id
    x.c = -1
    x.target = ""
    If buf_valid(buf_id) Then
        x.c = bufs(buf_id).conn_id
        If bufs(buf_id).kind = BK_CHANNEL OrElse bufs(buf_id).kind = BK_QUERY OrElse bufs(buf_id).kind = BK_DCC Then
            x.target = bufs(buf_id).name
        End If
    End If
End Sub

Sub cmd_run(ByRef x As cmd_ctx, ByRef text As String)
    If Len(text) = 0 Then Exit Sub
    If x.depth > 8 Then cx_err(x, "Alias recursion too deep") : Exit Sub

    If Left(text, 1) <> "/" OrElse Left(text, 2) = "//" Then
        Dim say_txt As String = IIf(Left(text, 2) = "//", Mid(text, 2), text)
        If buf_valid(x.buf) AndAlso bufs(x.buf).kind = BK_DCC Then
            dcc_chat_send(x.buf, say_txt)
            Exit Sub
        End If
        x.args = say_txt
        x.cmd = "say"
        c_say(x)
        Exit Sub
    End If

    Dim sp As Long = InStr(text, " ")
    x.cmd = LCase(Mid(text, 2, IIf(sp > 0, sp - 2, Len(text) - 1)))
    x.args = IIf(sp > 0, Mid(text, sp + 1), "")
    If Len(x.cmd) = 0 Then Exit Sub

    ' user aliases first, so they can override built-ins
    Dim ai As Long = alias_find(x.cmd)
    If ai >= 0 Then
        Dim expanded As String = alias_expand(x, alias_exp(ai))
        Dim parts() As String
        Dim np As Long = str_split(expanded, " && ", parts())
        Dim k As Long
        For k = 0 To np - 1
            Dim y As cmd_ctx
            cmd_fill_ctx(y, x.buf)
            y.depth = x.depth + 1
            Dim ln As String = Trim(parts(k))
            If Len(ln) > 0 AndAlso Left(ln, 1) <> "/" Then ln = "/say " & ln
            cmd_run(y, ln)
        Next k
        Exit Sub
    End If

    Dim ci As Long = cmd_find(x.cmd)
    If ci >= 0 Then
        If cmds(ci).need >= 1 AndAlso conn_valid(x.c) = 0 Then cx_err(x, "/" & x.cmd & ": this window has no connection") : Exit Sub
        If cmds(ci).need >= 2 AndAlso conn_online(x.c) = 0 Then cx_err(x, "/" & x.cmd & ": not connected") : Exit Sub
        cmds(ci).fn(x)
        Exit Sub
    End If

    If ui_command(x.buf, x.cmd, x.args) Then Exit Sub

    If cfg.raw_unknown AndAlso conn_online(x.c) Then
        conn_send(x.c, UCase(x.cmd) & IIf(Len(x.args) > 0, " " & x.args, ""))
        Exit Sub
    End If
    cx_err(x, "Unknown command: /" & x.cmd & "  (/help lists commands)")
End Sub

Sub cmd_execute(buf_id As Long, ByRef text As String)
    Dim x As cmd_ctx
    cmd_fill_ctx(x, buf_id)
    cmd_run(x, text)
End Sub

' Command names for tab completion (returns count; names without '/').
Function cmd_names(arr() As String) As Long
    Dim n As Long = cmd_count + alias_count
    ReDim arr(0 To IIf(n > 0, n - 1, 0))
    Dim i As Long
    For i = 0 To cmd_count - 1
        arr(i) = cmds(i).nm
    Next i
    For i = 0 To alias_count - 1
        arr(cmd_count + i) = alias_nm(i)
    Next i
    Return n
End Function

Sub cmd_init()
    cmd_count = 0
    ' connection
    cmd_reg("server",     @c_server,      0, "/server [-m] [-tls] <host> [port|+tlsport] [password]", "Connect this window's network to a server; -m opens a new connection")
    cmd_reg("connect",    @c_connect,     0, "/connect <network|host> [port]", "Connect to a saved network (see the network list, F2) or a server")
    cmd_reg("disconnect", @c_disconnect,  1, "/disconnect [message]", "Disconnect from the server of this window")
    cmd_reg("reconnect",  @c_reconnect,   1, "/reconnect", "Reconnect to the server of this window")
    cmd_reg("quit",       @c_quit,        1, "/quit [message]", "Disconnect from this window's server")
    cmd_reg("exit",       @c_exit,        0, "/exit [message]", "Disconnect from all servers and close vtirc-ng")
    ' messages
    cmd_reg("msg",        @c_msg,         2, "/msg <nick|#chan> <text>", "Send a private message")
    cmd_reg("query",      @c_query,       1, "/query <nick> [text]", "Open a private conversation window")
    cmd_reg("notice",     @c_notice,      2, "/notice <nick|#chan> <text>", "Send a notice")
    cmd_reg("me",         @c_me,          1, "/me <action>", "Send an action (* nick does something)")
    cmd_reg("describe",   @c_describe,    2, "/describe <target> <action>", "Send an action to another target")
    cmd_reg("say",        @c_say,         2, "/say <text>", "Send text to the current channel or query (even if it starts with /)")
    cmd_reg("amsg",       @c_amsg,        2, "/amsg <text>", "Send a message to all channels on this network")
    cmd_reg("ame",        @c_amsg,        2, "/ame <action>", "Send an action to all channels on this network")
    cmd_reg("ctcp",       @c_ctcp,        2, "/ctcp <nick> <command> [args]", "Send a CTCP request (VERSION, PING, TIME, ...)")
    cmd_reg("ping",       @c_ping,        2, "/ping [nick]", "CTCP PING a nick, or show the lag to the server")
    cmd_reg("lag",        @c_lag,         2, "/lag", "Show the measured lag to the server")
    ' services
    cmd_reg("ns",         @c_service,     2, "/ns <command>", "Send a command to NickServ (e.g. /ns identify pass, /ns register pass email)")
    cmd_reg("cs",         @c_service,     2, "/cs <command>", "Send a command to ChanServ (e.g. /cs op #chan, /cs info #chan)")
    cmd_reg("ms",         @c_service,     2, "/ms <command>", "Send a command to MemoServ")
    cmd_reg("hs",         @c_service,     2, "/hs <command>", "Send a command to HostServ")
    cmd_reg("os",         @c_service,     2, "/os <command>", "Send a command to OperServ")
    cmd_reg("bs",         @c_service,     2, "/bs <command>", "Send a command to BotServ")
    cmd_reg("nickserv",   @c_service,     2, "/nickserv <command>", "Same as /ns")
    cmd_reg("chanserv",   @c_service,     2, "/chanserv <command>", "Same as /cs")
    cmd_reg("memoserv",   @c_service,     2, "/memoserv <command>", "Same as /ms")
    cmd_reg("hostserv",   @c_service,     2, "/hostserv <command>", "Same as /hs")
    cmd_reg("operserv",   @c_service,     2, "/operserv <command>", "Same as /os")
    cmd_reg("botserv",    @c_service,     2, "/botserv <command>", "Same as /bs")
    cmd_reg("identify",   @c_identify,    2, "/identify [account] [password]", "Identify to NickServ (uses the network's saved password if none given)")
    cmd_reg("ghost",      @c_ghost,       2, "/ghost <nick> [password]", "Ask NickServ to disconnect a session using your nick")
    cmd_reg("regain",     @c_ghost,       2, "/regain <nick> [password]", "Ask NickServ to give you back your nick")
    ' information
    cmd_reg("whois",      @c_whois,       2, "/whois <nick> [server|nick]", "Show information about a user")
    cmd_reg("wii",        @c_whois,       2, "/wii <nick>", "WHOIS including idle time (asks the user's own server)")
    cmd_reg("whowas",     @c_whowas,      2, "/whowas <nick>", "Information about a nick that recently left")
    cmd_reg("who",        @c_who,         2, "/who <mask|#chan>", "List users matching a mask")
    cmd_reg("names",      @c_names,       2, "/names [#chan]", "List the users in a channel")
    cmd_reg("topic",      @c_topic,       2, "/topic [#chan] [new topic]", "Show or change the channel topic")
    cmd_reg("list",       @c_list,        2, "/list [>users] [*mask*]", "Request the channel list (F4 shows it)")
    cmd_reg("motd",       @c_server_query, 2, "/motd [server]", "Show the message of the day")
    cmd_reg("lusers",     @c_server_query, 2, "/lusers", "Show network user statistics")
    cmd_reg("version",    @c_server_query, 2, "/version [server]", "Show the server version")
    cmd_reg("time",       @c_server_query, 2, "/time [server]", "Show the server time")
    cmd_reg("stats",      @c_server_query, 2, "/stats <letter> [server]", "Server statistics")
    cmd_reg("links",      @c_server_query, 2, "/links", "List the servers of the network")
    cmd_reg("admin",      @c_server_query, 2, "/admin [server]", "Show server administrator info")
    cmd_reg("info",       @c_server_query, 2, "/info [server]", "Show server information")
    cmd_reg("map",        @c_server_query, 2, "/map", "Show the network map (if the server allows it)")
    ' channels
    cmd_reg("join",       @c_join,        2, "/join <#chan>[,<#chan>...] [key[,key...]]", "Join channels (opens a window for each)")
    cmd_reg("j",          @c_join,        2, "/j <#chan>", "Same as /join")
    cmd_reg("part",       @c_part,        2, "/part [#chan] [reason]", "Leave a channel and close its window")
    cmd_reg("leave",      @c_part,        2, "/leave [#chan] [reason]", "Same as /part")
    cmd_reg("cycle",      @c_cycle,       2, "/cycle [#chan]", "Leave and rejoin a channel")
    cmd_reg("hop",        @c_cycle,       2, "/hop [#chan]", "Same as /cycle")
    cmd_reg("invite",     @c_invite,      2, "/invite <nick> [#chan]", "Invite a user to a channel")
    cmd_reg("knock",      @c_knock,       2, "/knock <#chan> [message]", "Ask for an invitation to an invite-only channel")
    cmd_reg("close",      @c_close,       0, "/close [reason]", "Close the window (leaves the channel / disconnects a server window)")
    ' moderation
    cmd_reg("mode",       @c_mode,        2, "/mode [target] <modes> [params]", "Set channel or user modes")
    cmd_reg("umode",      @c_umode,       2, "/umode [modes]", "Show or change your user modes")
    cmd_reg("op",         @c_opvoice,     2, "/op <nick> [nick...]", "Give channel operator status")
    cmd_reg("deop",       @c_opvoice,     2, "/deop <nick> [nick...]", "Take channel operator status")
    cmd_reg("voice",      @c_opvoice,     2, "/voice <nick> [nick...]", "Give voice")
    cmd_reg("devoice",    @c_opvoice,     2, "/devoice <nick> [nick...]", "Take voice")
    cmd_reg("halfop",     @c_opvoice,     2, "/halfop <nick> [nick...]", "Give half-operator status")
    cmd_reg("dehalfop",   @c_opvoice,     2, "/dehalfop <nick> [nick...]", "Take half-operator status")
    cmd_reg("kick",       @c_kick,        2, "/kick [#chan] <nick> [reason]", "Kick a user from the channel")
    cmd_reg("ban",        @c_ban,         2, "/ban [#chan] <nick|mask>", "Ban a user (by host when known); no argument lists bans")
    cmd_reg("unban",      @c_ban,         2, "/unban [#chan] <mask>", "Remove a ban")
    cmd_reg("kb",         @c_kickban,     2, "/kb [#chan] <nick> [reason]", "Ban and kick a user")
    cmd_reg("kickban",    @c_kickban,     2, "/kickban [#chan] <nick> [reason]", "Same as /kb")
    cmd_reg("quiet",      @c_ban,         2, "/quiet [#chan] <nick|mask>", "Quiet a user (+q, where the server supports it)")
    cmd_reg("unquiet",    @c_ban,         2, "/unquiet [#chan] <mask>", "Remove a quiet")
    cmd_reg("banlist",    @c_banlist,     2, "/banlist [#chan]", "List the channel bans")
    cmd_reg("exceptlist", @c_banlist,     2, "/exceptlist [#chan]", "List ban exceptions (+e)")
    cmd_reg("invitelist", @c_banlist,     2, "/invitelist [#chan]", "List invite exceptions (+I)")
    ' self
    cmd_reg("nick",       @c_nick,        0, "/nick <newnick>", "Change your nick")
    cmd_reg("away",       @c_away,        2, "/away [message]", "Mark yourself as away on this network")
    cmd_reg("afk",        @c_away,        2, "/afk [message]", "Same as /away")
    cmd_reg("back",       @c_back,        2, "/back", "Remove the away status on this network")
    cmd_reg("aaway",      @c_away,        0, "/aaway [message]", "Mark yourself away on all networks")
    cmd_reg("aback",      @c_back,        0, "/aback", "Remove the away status on all networks")
    cmd_reg("setname",    @c_setname,     2, "/setname <real name>", "Change your real name (IRCv3 setname)")
    ' client
    cmd_reg("raw",        @c_raw,         1, "/raw <IRC line>", "Send a raw line to the server")
    cmd_reg("quote",      @c_raw,         1, "/quote <IRC line>", "Same as /raw")
    cmd_reg("echo",       @c_echo,        0, "/echo <text>", "Print text in the current window")
    cmd_reg("clear",      @c_clear,       0, "/clear [all]", "Clear the window's history (or all windows)")
    cmd_reg("ignore",     @c_ignore,      0, "/ignore [mask [msgs privs notices ctcps invites joins dcc all]]", "Ignore a nick or mask; no arguments lists the ignore list")
    cmd_reg("unignore",   @c_unignore,    0, "/unignore <mask>", "Remove an ignore")
    cmd_reg("highlight",  @c_highlight,   0, "/highlight [add|del] <word>", "Words that highlight a line like your nick does")
    cmd_reg("alias",      @c_alias,       0, "/alias [add <name> <command> | del <name>]", "User commands; $1 $2- $chan $nick $network expand; && separates commands")
    cmd_reg("autojoin",   @c_autojoin,    1, "/autojoin [add|del] [#chan [key]]", "Channels joined automatically on this network")
    cmd_reg("perform",    @c_perform,     1, "/perform [add <command> | del <n>]", "Commands run after connecting to this network")
    cmd_reg("set",        @c_set,         0, "/set [setting [value]]", "Show or change settings (/set lists them, wildcards allowed)")
    cmd_reg("cert",       @c_cert,        1, "/cert [accept|forget]", "Show or accept this server's TLS certificate pin")
    cmd_reg("charset",    @c_charset,     1, "/charset [utf-8|cp1255|cp1251|cp1252|...]", "Character set for this network")
    cmd_reg("dcc",        @c_dcc,         0, "/dcc [chat <nick> | send <nick> <file> | get <nick> [file] | close <nick> | list]", "Direct client-to-client chat and file transfer")
    cmd_reg("help",       @c_help,        0, "/help [command]", "List commands or show help for one")
End Sub
