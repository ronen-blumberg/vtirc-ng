' tests/test_irc.bas -- protocol, state and command tests (included by test_core.bas)
' A Unix socketpair stands in for the server: the test writes server lines into
' one end and reads what the client sent from the same end.

' ---------------------------------------------------------------- parser
t_begin("parse")
Scope
    Dim m As irc_msg
    irc_parse("@time=2026-09-10T12:00:00.000Z;msgid=abc :nick!user@host PRIVMSG #chan :hello world", m)
    check_str(m.cmd, "PRIVMSG", "command")
    check_str(m.nick & "|" & m.user & "|" & m.host, "nick|user|host", "source split")
    check_int(m.pcount, 2, "param count")
    check_str(m.params(1), "hello world", "trailing param")
    check_str(irc_tag(m, "msgid"), "abc", "tag value")
    check(irc_has_tag(m, "time"), "has tag")
    irc_parse("PING :irc.example", m)
    check_str(m.cmd & " " & irc_param(m, 0), "PING irc.example", "no source")
    irc_parse(":srv 005 me CHANTYPES=# PREFIX=(ov)@+ :are supported", m)
    check_int(m.pcount, 4, "005 params")
    irc_parse(":a!b@c PRIVMSG #x ::)", m)
    check_str(irc_last(m), ":)", "trailing starting with colon")
    irc_parse(":a!b@c   PRIVMSG   #x   word", m)
    check_str(irc_param(m, 1), "word", "multiple spaces")
    irc_parse("@a=x\sy\:z\\w :s NOTICE me :t", m)
    check_str(irc_tag(m, "a"), "x y;z\w", "tag unescape")
    check_str(irc_lc("Nick[]\~", CM_RFC1459), "nick{}|^", "rfc1459 casemap")
    check_str(irc_lc("Nick[]\~", CM_ASCII), "nick[]\~", "ascii casemap")
    check_str(irc_lc("Nick[]\~", CM_STRICT_RFC1459), "nick{}|~", "strict casemap")
    check_str(irc_strip_format(Chr(3) & "04,01red" & Chr(15) & " " & Chr(2) & "b" & Chr(3) & "3x"), "red bx", "strip formatting")
    check_str(irc_strip_format(Chr(4) & "FF0000text"), "text", "strip hex colour")
End Scope

' ---------------------------------------------------------------- harness
Dim Shared sv(1) As Long

Function t_new_conn(net_idx As Long, ByRef nm As String) As Long
    socketpair(AF_UNIX, SOCK_STREAM, 0, @sv(0))
    vt_net_nonblocking(sv(0), 1)
    vt_net_nonblocking(sv(1), 1)
    Dim c As Long = conn_new(net_idx, nm)
    conns(c).sock = sv(0)
    conns(c).srv.host = "test.invalid"
    conn_on_connected(c)
    Return c
End Function

' Everything the client has sent so far (CRLF -> "|").
Function t_sent() As String
    conn_poll_all()
    Dim r As String
    Dim b As ZString * 8193
    Do
        Dim n As Long = recv(sv(1), @b, 8192, 0)
        If n <= 0 Then Exit Do
        Dim chunk As String = Space(n)
        memcpy(StrPtr(chunk), @b, n)
        r &= chunk
    Loop
    r = str_replace(r, Chr(13, 10), "|")
    Return r
End Function

Sub t_srv(ByRef ln As String)
    Dim s As String = ln & Chr(13, 10)
    send(sv(1), StrPtr(s), Len(s), 0)
    conn_poll_all()
End Sub

' Last history line of a buffer.
Function t_last(id As Long) As irc_line Ptr
    If buf_valid(id) = 0 OrElse bufs(id).hist_count = 0 Then Return 0
    Return buf_line(id, bufs(id).hist_count - 1)
End Function

Function t_last_text(id As Long) As String
    Dim p As irc_line Ptr = t_last(id)
    If p = 0 Then Return ""
    Return p->prefix & " " & p->text
End Function

' ---------------------------------------------------------------- registration
t_begin("register")
Dim Shared tc As Long
tc = t_new_conn(-1, "testnet")
conns(tc).nick = "testnick"
Scope
    Dim s As String = t_sent()
    check(InStr(s, "CAP LS 302|") > 0, "CAP LS first")
    check(InStr(s, "NICK ") > 0 AndAlso InStr(s, "USER ") > 0, "NICK and USER sent")
    t_srv(":srv CAP * LS :multi-prefix sasl server-time away-notify unknown-cap")
    s = t_sent()
    check(InStr(s, "CAP REQ :multi-prefix server-time away-notify|") > 0, "requests wanted caps only (no sasl without login)")
    t_srv(":srv CAP * ACK :multi-prefix server-time away-notify")
    s = t_sent()
    check(InStr(s, "CAP END|") > 0, "CAP END after ACK")
    check(conn_has_cap(tc, "server-time"), "cap enabled")
    t_srv(":srv 433 * testnick :Nickname is already in use")
    s = t_sent()
    check(InStr(s, "NICK ") > 0, "tries another nick on 433")
    t_srv(":srv 001 testnick :Welcome to TestNet testnick")
    check_int(conns(tc).st, CS_ONLINE, "online after 001")
    check_str(conns(tc).nick, "testnick", "nick from 001")
    t_srv(":srv 005 testnick PREFIX=(qaohv)~&@%+ CHANTYPES=# CASEMAPPING=rfc1459 NETWORK=TestNet MODES=3 :are supported")
    check_str(conns(tc).prefix_chars, "~&@%+", "PREFIX chars")
    check_str(conns(tc).prefix_modes, "qaohv", "PREFIX modes")
    check_str(conns(tc).name, "TestNet", "ad-hoc connection renamed by NETWORK")
    check_str(bufs(conns(tc).status_buf).name, "TestNet", "status window renamed")
    t_srv(":srv 376 testnick :End of /MOTD command.")
    check(conns(tc).motd_done, "ready after MOTD")
    t_srv(":srv PING :abc123")
    check(InStr(t_sent(), "PONG :abc123|") > 0, "answers PING")
End Scope

' ---------------------------------------------------------------- channel
t_begin("channel")
Dim Shared tch As Long
Scope
    stub_active = conns(tc).status_buf
    cmd_execute(conns(tc).status_buf, "/join test")
    check(InStr(t_sent(), "JOIN #test|") > 0, "/join adds # and sends JOIN")
    t_srv(":testnick!u@host.example JOIN #test")
    tch = buf_find_kind(tc, BK_CHANNEL, "#TEST")
    check(tch >= 0, "channel window created (case-insensitive lookup)")
    check_int(stub_active, tch, "joined channel gets focus")
    check(bufs(tch).joined, "joined flag")
    check_str(conns(tc).host, "host.example", "own host learned from JOIN")
    t_srv(":srv 353 testnick = #test :~owner @op +voice plain testnick")
    t_srv(":srv 366 testnick #test :End of /NAMES list.")
    check_int(bufs(tch).user_count, 5, "names parsed")
    user_sort(tch, conns(tc).prefix_chars)
    check_str(bufs(tch).users(bufs(tch).sorted(0)).nick, "owner", "sort: ~ first")
    check_str(bufs(tch).users(bufs(tch).sorted(1)).nick, "op", "sort: @ second")
    check_str(bufs(tch).users(bufs(tch).sorted(2)).nick, "voice", "sort: + third")
    check_str(bufs(tch).users(bufs(tch).sorted(3)).nick, "plain", "sort: no prefix, alphabetical")
    check(InStr(t_sent(), "MODE #test|") > 0, "asks channel modes after NAMES")
    t_srv(":op!o@h MODE #test +o-v plain voice")
    check_str(bufs(tch).users(user_find(tch, "plain")).pfx, "@", "+o applied")
    check_str(bufs(tch).users(user_find(tch, "voice")).pfx, "", "-v applied")
    t_srv(":op!o@h MODE #test +kl secret 10")
    check_str(bufs(tch).chkey, "secret", "+k key stored")
    check_str(bufs(tch).chlimit, "10", "+l limit stored")
    check(InStr(bufs(tch).chmodes, "k") > 0 AndAlso InStr(bufs(tch).chmodes, "l") > 0, "mode letters")
    t_srv(":op!o@h KICK #test plain :bye")
    check(user_find(tch, "plain") < 0, "kicked user removed")
    t_srv(":voice!v@h NICK voice2")
    check(user_find(tch, "voice2") >= 0 AndAlso user_find(tch, "voice") < 0, "nick change renames user")
    t_srv(":newbie!n@h JOIN #test")
    check(user_find(tch, "newbie") >= 0, "other user joins")
    check(t_last(tch)->flags And LF_NOISE, "join of a silent user is filterable noise")
    t_srv(":newbie!n@h QUIT :gone")
    check(user_find(tch, "newbie") < 0, "quit removes user")
    t_srv(":op!o@h TOPIC #test :New topic here")
    check_str(bufs(tch).topic, "New topic here", "TOPIC updates topic")
    Dim nb As Long = stub_notifies
    t_srv(":op!o@h PRIVMSG #test :hey testnick, look")
    check(t_last(tch)->flags And LF_HIGHLIGHT, "nick mention highlights")
    check_int(stub_notifies, nb + 1, "highlight notifies")
    t_srv(":op!o@h PRIVMSG #test :testnickname is not me")
    check((t_last(tch)->flags And LF_HIGHLIGHT) = 0, "no highlight inside a longer word")
    check_str(t_last(tch)->prefix, "<@op>", "message prefix shows mode symbol")
    t_srv("@time=2026-01-01T00:00:00.000Z :op!o@h PRIVMSG #test :from the past")
    check_int(CLngInt(t_last(tch)->t), 1767225600, "server-time tag used for the line time")
    t_srv(":op!o@h PRIVMSG #test :" & Chr(1) & "ACTION waves" & Chr(1))
    check_str(t_last_text(tch), "* op waves", "CTCP ACTION")
End Scope

' ---------------------------------------------------------------- messages, CTCP, WHOIS
t_begin("messages")
Scope
    t_srv(":bob!b@bobhost PRIVMSG testnick :hi there")
    Dim q As Long = buf_find_kind(tc, BK_QUERY, "bob")
    check(q >= 0, "query window opened for a private message")
    check_str(t_last_text(q), "<bob> hi there", "query line")
    t_sent()
    t_srv(":bob!b@bobhost PRIVMSG testnick :" & Chr(1) & "VERSION" & Chr(1))
    check(InStr(t_sent(), "NOTICE bob :" & Chr(1) & "VERSION vtirc-ng " & VTIRC_VERSION) > 0, "CTCP VERSION reply")
    t_srv(":bob!b@bobhost PRIVMSG testnick :" & Chr(1) & "PING 12345" & Chr(1))
    check(InStr(t_sent(), "NOTICE bob :" & Chr(1) & "PING 12345" & Chr(1)) > 0, "CTCP PING echoed")
    stub_active = tch
    t_srv(":srv 311 testnick bob b bobhost * :Bob Real")
    t_srv(":srv 319 testnick bob :@#test #other")
    t_srv(":srv 312 testnick bob irc.test :Test server")
    t_srv(":srv 330 testnick bob bobacct :is logged in as")
    t_srv(":srv 317 testnick bob 252 1767225600 :seconds idle, signon time")
    t_srv(":srv 318 testnick bob :End of /WHOIS list.")
    Dim found As Long = 0
    Dim i As Long
    For i = 0 To bufs(tch).hist_count - 1
        Dim p As irc_line Ptr = buf_line(tch, i)
        If p->kind = LK_WHOIS Then
            If InStr(p->text, "Bob Real") > 0 Then found Or= 1
            If InStr(p->text, "@#test #other") > 0 Then found Or= 2
            If InStr(p->text, "bobacct") > 0 Then found Or= 4
            If InStr(p->text, "4m12s") > 0 Then found Or= 8
        End If
    Next i
    check_int(found, 15, "WHOIS block in the active window (name, channels, account, idle)")
    t_srv(":NickServ!NickServ@services. NOTICE testnick :This nickname is registered.")
    check(InStr(t_last_text(tch), "-NickServ- This nickname is registered.") > 0, "private notice in the active window")
End Scope

' ---------------------------------------------------------------- commands
t_begin("commands")
Scope
    ' generous flood limits so each command's output is sent immediately
    cfg.flood_burst = 1000
    conns(tc).tokens = 1000
    conns(tc).tok_time = clock_s()
    t_sent()
    cmd_execute(tch, "/ns identify secretpw")
    check(InStr(t_sent(), "PRIVMSG NickServ :identify secretpw|") > 0, "/ns")
    cmd_execute(tch, "/cs op #test")
    check(InStr(t_sent(), "PRIVMSG ChanServ :op #test|") > 0, "/cs")
    cmd_execute(tch, "/whois bob")
    check(InStr(t_sent(), "WHOIS bob|") > 0, "/whois")
    cmd_execute(tch, "/op a b c d")
    Dim s As String = t_sent()
    check(InStr(s, "MODE #test +ooo a b c|") > 0 AndAlso InStr(s, "MODE #test +o d|") > 0, "/op batches by MODES")
    cmd_execute(tch, "/kb op flooding")
    s = t_sent()
    check(InStr(s, "MODE #test +b *!*@h|") > 0 AndAlso InStr(s, "KICK #test op :flooding|") > 0, "/kb bans by host then kicks")
    cmd_execute(tch, "/topic Brand new")
    check(InStr(t_sent(), "TOPIC #test :Brand new|") > 0, "/topic sets current channel topic")
    cmd_execute(tch, "/foo bar baz")
    check(InStr(t_sent(), "FOO bar baz|") > 0, "unknown command sent raw")
    cmd_execute(tch, "/alias add hi /msg $1 hello $2-")
    cmd_execute(tch, "/hi bob out there")
    check(InStr(t_sent(), "PRIVMSG bob :hello out there|") > 0, "alias expansion")
    cmd_execute(tch, "/me dances")
    check(InStr(t_sent(), "PRIVMSG #test :" & Chr(1) & "ACTION dances" & Chr(1)) > 0, "/me")
    check_str(t_last_text(tch), "* testnick dances", "local echo of /me")
    cmd_execute(tch, "plain text line")
    check(InStr(t_sent(), "PRIVMSG #test :plain text line|") > 0, "text goes to the channel")
    check_str(t_last_text(tch), "<testnick> plain text line", "local echo of text")
    ' long message splitting
    Dim longtxt As String
    For i As Long = 1 To 120
        longtxt &= "word" & i & " "
    Next i
    longtxt = RTrim(longtxt)
    cmd_execute(tch, longtxt)
    s = t_sent()
    Dim a() As String
    Dim n As Long = str_split(s, "|", a())
    Dim joined As String
    Dim ok_len As Byte = 1
    Dim parts As Long = 0
    For i As Long = 0 To n - 1
        If Left(a(i), 15) = "PRIVMSG #test :" Then
            parts += 1
            If Len(a(i)) + conn_prefix_len(tc) > 510 Then ok_len = 0
            joined &= IIf(Len(joined) > 0, " ", "") & Mid(a(i), 16)
        End If
    Next i
    check(parts >= 2, "long text split into several lines")
    check(ok_len, "every piece fits in 512 bytes with the relay prefix")
    check_str(joined, longtxt, "pieces reassemble to the original")
    ' flood control: 10 lines, burst of 5
    cfg.flood_burst = 5
    conns(tc).tokens = 5
    conns(tc).tok_time = clock_s()
    For i As Long = 1 To 10
        cmd_execute(tch, "/msg bob line" & i)
    Next i
    s = t_sent()
    check(InStr(s, "line5|") > 0 AndAlso InStr(s, "line6|") = 0, "flood control sends a burst of 5")
    check_int(conns(tc).sq_count, 5, "rest stays queued")
    conn_clear_queue(tc)
    cfg.flood_burst = 1000
    conns(tc).tokens = 1000
    cmd_execute(tch, "/part")
    check(InStr(t_sent(), "PART #test") > 0, "/part")
    t_srv(":testnick!u@host.example PART #test")
    check(buf_valid(tch) = 0, "window closed when our PART comes back")
End Scope

' ---------------------------------------------------------------- SASL
t_begin("sasl")
Scope
    Dim keep0 As Long = sv(0), keep1 As Long = sv(1)   ' the main test connection's pair
    Dim ni As Long = net_add("SaslNet")
    nets(ni).login = LOGIN_SASL
    nets(ni).login_user = "acct"
    nets(ni).login_pass = "pw"
    nets(ni).nick = "saslnick"
    Dim c As Long = t_new_conn(ni, "SaslNet")
    Dim s As String = t_sent()
    check(InStr(s, "NICK saslnick|") > 0, "network nick used")
    t_srv(":srv CAP * LS * :multi-prefix sasl=PLAIN,EXTERNAL")
    t_srv(":srv CAP * LS :server-time")
    s = t_sent()
    check(InStr(s, "CAP REQ :multi-prefix sasl server-time|") > 0, "multi-line LS, sasl requested")
    t_srv(":srv CAP * ACK :multi-prefix sasl server-time")
    check(InStr(t_sent(), "AUTHENTICATE PLAIN|") > 0, "SASL PLAIN started")
    t_srv("AUTHENTICATE +")
    check(InStr(t_sent(), "AUTHENTICATE " & base64_encode("acct" & Chr(0) & "acct" & Chr(0) & "pw") & "|") > 0, "SASL credentials")
    t_srv(":srv 903 saslnick :SASL authentication successful")
    check(InStr(t_sent(), "CAP END|") > 0, "CAP END after SASL success")
    conn_free(c)
    vt_net_close(sv(1))
    sv(0) = keep0 : sv(1) = keep1
End Scope

' ---------------------------------------------------------------- config
t_begin("config")
Scope
    Dim e As srv_entry
    check(srv_parse("irc.libera.chat/6697/tls", e), "parse server entry")
    check(e.tls = 1 AndAlso e.port = 6697, "tls + port")
    check(srv_parse("host/6667/plain/pa/ss", e), "password with slash")
    check_str(e.pass, "pa/ss", "password kept whole")
    check_str(srv_format(e), "host/6667/plain/pa/ss", "format round trip")
    Dim ni As Long = net_add("RoundTrip")
    net_add_server(ni, "a.example", 6697, 1)
    net_add_autojoin(ni, "#one key")
    net_add_autojoin(ni, "#two")
    check(config_save(), "config saved")
    Dim before As Long = net_count
    net_count = 0
    ini_load(cfg_ini, cfg_path)
    nets_from_ini()
    check_int(net_count, before, "networks reloaded")
    Dim nj As Long = net_find("roundtrip")
    check(nj >= 0, "network found by name")
    check_int(nets(nj).aj_count, 2, "autojoin reloaded")
    check_str(nets(nj).autojoin(0), "#one key", "autojoin key kept")
End Scope

' ---------------------------------------------------------------- extras
t_begin("extras")
Scope
    cfg.flood_burst = 1000
    conns(tc).tokens = 1000
    t_srv(":testnick!u@host.example JOIN #trig")
    Dim tb As Long = buf_find_kind(tc, BK_CHANNEL, "#trig")
    check(tb >= 0, "joined #trig")
    t_sent()
    cmd_execute(tb, "/trigger add text|*ping me*|#trig|/say pong $nick ($1)")
    check_int(trig_count, 1, "trigger stored")
    t_srv(":alice!a@h PRIVMSG #trig :please ping me now")
    check(InStr(t_sent(), "PRIVMSG #trig :pong alice (please)|") > 0, "trigger fires with expansions")
    t_srv(":testnick!u@host.example PRIVMSG #trig :ping me too")
    check(InStr(t_sent(), "pong") = 0, "own lines never fire triggers")
    ' highlights window
    t_srv(":alice!a@h PRIVMSG #trig :testnick: look here")
    check(buf_valid(hl_buf), "(highlights) window created")
    If buf_valid(hl_buf) Then check(InStr(t_last_text(hl_buf), "TestNet/#trig: testnick: look here") > 0, "highlight copied with its origin")
    ' URL log
    t_srv(":alice!a@h PRIVMSG #trig :see https://example.org/x. and www.test.org")
    check(url_log_n >= 2, "links logged")
    check(InStr(url_log((url_log_head + url_log_n - 2) Mod URL_LOG_MAX), "|https://example.org/x") > 0, "trailing dot stripped")
    ' notify list via ISON
    cmd_execute(tb, "/notify add friend1")
    friends_poll()
    check(InStr(t_sent(), "ISON friend1|") > 0, "ISON poll when MONITOR is not available")
    t_srv(":srv 303 testnick :friend1")
    check(InStr(t_last_text(conns(tc).status_buf), "friend1 is online") > 0, "friend online reported")
    t_srv(":srv 303 testnick :")
    ison_next(tc) = 0
    check(InStr(t_last_text(conns(tc).status_buf), "friend1 went offline") > 0, "friend offline reported")
    cmd_execute(tb, "/notify del friend1")
    ' per-window notification level
    cmd_execute(tb, "/chanset notify none")
    check_int(bufs(tb).notify_mode, 3, "chanset notify none")
    check_str(ini_get(cfg_ini, "chanset", "testnet/#trig"), "notify=none", "chanset persisted")
    Dim before As Long = stub_notifies
    t_srv(":alice!a@h PRIVMSG #trig :testnick are you there")
    check_int(stub_notifies, before, "no notification in a silenced window")
    cmd_execute(tb, "/trigger del 1")
    check_int(trig_count, 0, "trigger removed")
End Scope

' ---------------------------------------------------------------- robustness
t_begin("fuzz")
Scope
    ' random and malformed lines must never crash the handlers (-exx build)
    Dim cmdsl(0 To 29) As String = { "PRIVMSG", "NOTICE", "JOIN", "PART", "KICK", "MODE", "TOPIC", "NICK", "QUIT", "INVITE", _
        "001", "005", "301", "311", "319", "324", "332", "333", "353", "366", "367", "322", "433", "474", "900", "904", _
        "CAP", "BATCH", "AWAY", "730" }
    Dim frag(0 To 11) As String = { "#trig", "testnick", "", ":", "::", "*", "+o-v", "@#trig", Chr(1) & "ACTION", _
        Chr(1) & "DCC SEND x 1 2", "=", !"שלום" }
    Randomize 42
    Dim i As Long
    For i = 1 To 20000
        Dim ln As String
        If Rnd < 0.3 Then ln = "@time=" & IIf(Rnd < 0.5, "garbage", "2026-01-01T00:00:00Z") & ";a=b "
        If Rnd < 0.9 Then ln &= ":" & frag(Int(Rnd * 12)) & IIf(Rnd < 0.5, "!u@h", "") & " "
        ln &= cmdsl(Int(Rnd * 30))
        Dim np As Long = Int(Rnd * 8)
        Dim k As Long
        For k = 1 To np
            ln &= " " & frag(Int(Rnd * 12))
        Next k
        If Rnd < 0.5 Then ln &= " :" & frag(Int(Rnd * 12)) & " " & frag(Int(Rnd * 12))
        If Rnd < 0.05 Then ln = String(Int(Rnd * 20), Chr(Int(Rnd * 256)))
        irc_handle_line(tc, ln)
    Next i
    check(conn_valid(tc), "20000 random lines handled")
    ' fuzzing renamed us and changed server settings: restore them
    conns(tc).nick = "testnick"
    conns(tc).chantypes = "#"
    conns(tc).prefix_modes = "qaohv" : conns(tc).prefix_chars = "~&@%+"
End Scope

t_begin("scale")
Scope
    t_srv(":testnick!u@host.example JOIN #big")
    Dim bb As Long = buf_find_kind(tc, BK_CHANNEL, "#big")
    Dim t0 As Double = clock_s()
    Dim i As Long
    Dim ln As String
    For i = 1 To 5000
        ln &= IIf(i Mod 10 = 0, "@", "") & "user" & i & " "
        If i Mod 100 = 0 Then
            irc_handle_line(tc, ":srv 353 testnick = #big :" & ln)
            ln = ""
        End If
    Next i
    irc_handle_line(tc, ":srv 366 testnick #big :End of /NAMES list.")
    Dim t1 As Double = clock_s()
    check_int(bufs(bb).user_count, 5000, "5000-user channel loaded")
    For i = 1 To 1000
        irc_handle_line(tc, ":user" & i & "!u@h QUIT :bye")
    Next i
    Dim t2 As Double = clock_s()
    check_int(bufs(bb).user_count, 4000, "1000 quits processed")
    check(user_find(bb, "user1001") >= 0 AndAlso user_find(bb, "user999") < 0 AndAlso user_find(bb, "USER5000") >= 0, "index consistent after removals")
    Print "     scale: names 5000 users " & CLng((t1 - t0) * 1000) & " ms, 1000 quits " & CLng((t2 - t1) * 1000) & " ms"
    check(t1 - t0 < 2, "big NAMES list loads quickly")
    check(t2 - t1 < 2, "quits in a big channel are fast")
End Scope

' ---------------------------------------------------------------- migration / logs
t_begin("migrate")
Scope
    Dim d As String = t_config_dir("vtirc_ng_migrate")
    Dim fh As Long = FreeFile()
    Open d & "/.vtirc" For Output As #fh
    Print #fh, "server=127.0.0.1"
    Print #fh, "port=6668"
    Print #fh, "channel=#i2p-chat,#chat"
    Print #fh, "nick=solo88"
    Print #fh, "password=secret"
    Print #fh, "scheme=1"
    Print #fh, "nick_alt=solo88_"
    Close #fh
    Dim before As Long = net_count
    check(config_migrate_v1(d & "/.vtirc"), "1.x config imported")
    Dim ni As Long = net_find("Migrated (127.0.0.1)")
    check(ni >= 0, "network created from the old server")
    If ni >= 0 Then
        check_int(nets(ni).servers(0).port, 6668, "port kept")
        check_int(nets(ni).aj_count, 2, "channels become autojoin")
        check_str(nets(ni).autojoin(0), "#i2p-chat", "first channel")
        check_int(nets(ni).login, LOGIN_SERVERPASS, "password becomes a server password")
        check(nets(ni).autoconnect, "migrated network connects at startup")
    End If
    check_str(cfg.nick, "solo88", "nick kept")
    check_str(cfg.altnicks, "solo88_", "alt nick kept")
    check_int(cfg.theme, 1, "colour scheme kept")
    If ni >= 0 Then net_remove(ni)
End Scope

t_begin("logs")
Scope
    cfg.log_enabled = 1
    Dim lb As Long = buf_find_kind(tc, BK_CHANNEL, "#trig")
    If lb < 0 Then
        t_srv(":testnick!u@host.example JOIN #trig")
        lb = buf_find_kind(tc, BK_CHANNEL, "#trig")
    End If
    Dim lp As String = log_path_for(lb)
    If file_exists(lp) Then Kill lp
    Dim i As Long
    For i = 1 To 30
        ev_line(lb, LK_MSG, 0, "<alice>", "alice", !"line " & i & !" שלום")
    Next i
    check(file_exists(lp), "log file written")
    Dim tl() As String
    check_int(log_tail(lb, 10, tl()), 10, "log tail returns the last lines")
    check(InStr(tl(9), !"<alice> line 30 שלום") > 0, "newest line last, UTF-8 kept")
    check(InStr(tl(0), "<alice> line 21 ") > 0, "oldest of the tail first")
End Scope
