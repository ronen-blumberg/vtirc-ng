' =============================================================================
' tests/test_net.bas -- integration tests against tests/fakeircd.py
'   tests/run_net.sh        (starts the fake server, builds and runs this)
' Real sockets, the connect thread, TLS, certificate pinning, SASL, SOCKS5,
' nick collisions and automatic reconnect.
' =============================================================================
#Define VT_USE_TLS
#Include Once "../vt/vt.bi"
#Include Once "../src/core/core.bas"
#Include Once "hooks_stub.bas"
#Include Once "tframe.bas"

Dim Shared base_port As Long
base_port = str_to_int(Command(1), 16667)

core_init(t_config_dir("vtirc_ng_nettest"))
cfg.flood_burst = 100
cfg.log_enabled = 0

' Poll the core until cond is true or secs pass.
#Macro WAIT_FOR(cond, secs)
    Scope
        Dim t0 As Double = clock_s()
        Do
            core_poll()
            If (cond) Then Exit Do
            Sleep 10, 1
        Loop Until clock_s() - t0 > (secs)
    End Scope
#EndMacro

Function has_line(id As Long, ByRef needle As String, kind As Long = -1, need_flags As Long = 0) As Long
    If buf_valid(id) = 0 Then Return 0
    Dim n As Long = 0
    Dim i As Long
    For i = 0 To bufs(id).hist_count - 1
        Dim p As irc_line Ptr = buf_line(id, i)
        If InStr(p->prefix & " " & p->text, needle) > 0 AndAlso (kind < 0 OrElse p->kind = kind) AndAlso _
           (p->flags And need_flags) = need_flags Then n += 1
    Next i
    Return n
End Function

Function new_adhoc(ByRef nm As String, port As Long, tls As Byte, ByRef nick As String) As Long
    Dim c As Long = conn_new(-1, nm)
    conns(c).srv.host = "127.0.0.1"
    conns(c).srv.port = port
    conns(c).srv.tls = tls
    conns(c).use_adhoc = 1
    cfg.nick = nick
    conn_connect(c)
    Return c
End Function

' ---------------------------------------------------------------- plain
t_begin("plain")
Dim Shared cp As Long
cp = new_adhoc("plain", base_port, 0, "nettest")
WAIT_FOR(conn_online(cp) AndAlso conns(cp).name = "FakeNet", 10)
check(conn_online(cp), "connects and registers over plain TCP")
check_str(conns(cp).name, "FakeNet", "network name from ISUPPORT")
check(conn_has_cap(cp, "echo-message"), "echo-message negotiated")
stub_active = conns(cp).status_buf
cmd_execute(conns(cp).status_buf, "/join #test")
Dim Shared tchan As Long
WAIT_FOR(buf_find_kind(cp, BK_CHANNEL, "#test") >= 0 AndAlso bufs(buf_find_kind(cp, BK_CHANNEL, "#test")).names_pending = 0, 10)
tchan = buf_find_kind(cp, BK_CHANNEL, "#test")
check(tchan >= 0, "joined #test")
If tchan >= 0 Then
    check_str(bufs(tchan).topic, "Welcome to #test", "topic on join")
    check(user_find(tchan, "bot") >= 0, "bot in the user list")
    cmd_execute(tchan, "!hello")
    WAIT_FOR(has_line(tchan, "hello nettest") > 0, 10)
    check(has_line(tchan, "hello nettest", LK_MSG) = 1, "bot answers in the channel")
    check_int(has_line(tchan, "!hello", LK_MSG, LF_SELF), 1, "own line shown exactly once (echo-message)")
    cmd_execute(tchan, "/whois bot")
    WAIT_FOR(has_line(tchan, "Friendly Bot", LK_WHOIS) > 0, 10)
    check(has_line(tchan, "Friendly Bot", LK_WHOIS) > 0, "WHOIS output in the active window")
    cmd_execute(tchan, "/ns hello services")
    WAIT_FOR(has_line(tchan, "You said: hello services") > 0, 10)
    check(has_line(tchan, "-NickServ- You said: hello services") > 0, "/ns reaches NickServ, notice shown in the window")
    check(buf_find_kind(cp, BK_QUERY, "NickServ") < 0, "no NickServ query window opened")
End If

' ---------------------------------------------------------------- nick collision
t_begin("collision")
Scope
    Dim c2 As Long = new_adhoc("taken", base_port, 0, "taken")
    WAIT_FOR(conn_online(c2), 10)
    check(conn_online(c2), "registers although the nick is taken")
    check_str(conns(c2).nick, "taken_", "falls back to nick_")
    conn_disconnect(c2, "bye")
    WAIT_FOR(conns(c2).st = CS_OFFLINE, 5)
    check_int(conns(c2).st, CS_OFFLINE, "disconnects cleanly")
    conn_free(c2)
End Scope

' ---------------------------------------------------------------- TLS + pinning
t_begin("tls")
Scope
    Dim ct As Long = new_adhoc("tls", base_port + 1, 1, "tlsuser")
    WAIT_FOR(conn_online(ct), 15)
    check(conn_online(ct), "connects over TLS")
    check_int(Len(conns(ct).tls_fp), 64, "certificate fingerprint (SHA-256 hex)")
    check_str(cert_pin_get("127.0.0.1", base_port + 1), conns(ct).tls_fp, "certificate pinned on first use")
    Dim fp As String = conns(ct).tls_fp
    conn_disconnect(ct, "bye")
    WAIT_FOR(conns(ct).st = CS_OFFLINE, 5)
    ' pretend the pinned certificate was different
    cert_pin_set("127.0.0.1", base_port + 1, String(64, "0"))
    conn_connect(ct)
    WAIT_FOR(conns(ct).st = CS_OFFLINE AndAlso Len(conns(ct).cert_new_fp) > 0, 15)
    check(Len(conns(ct).cert_new_fp) > 0, "changed certificate stops the connection")
    check(has_line(conns(ct).status_buf, "CERTIFICATE CHANGED") > 0, "user is warned")
    cmd_execute(conns(ct).status_buf, "/cert accept")
    WAIT_FOR(conn_online(ct), 15)
    check(conn_online(ct), "/cert accept reconnects")
    check_str(cert_pin_get("127.0.0.1", base_port + 1), fp, "new pin stored")
    conn_disconnect(ct, "bye")
    WAIT_FOR(conns(ct).st = CS_OFFLINE, 5)
    conn_free(ct)
End Scope

' ---------------------------------------------------------------- SASL
t_begin("sasl")
Scope
    Dim ni As Long = net_add("FakeSasl")
    net_add_server(ni, "127.0.0.1", base_port + 1, 1)
    nets(ni).login = LOGIN_SASL
    nets(ni).login_user = "acct"
    nets(ni).login_pass = "pw"
    nets(ni).nick = "sasluser"
    Dim cs As Long = conn_new(ni, "FakeSasl")
    conn_connect(cs)
    WAIT_FOR(conn_online(cs), 15)
    check(conn_online(cs), "connects with SASL")
    check(has_line(conns(cs).status_buf, "SASL authentication successful") > 0, "SASL succeeded")
    check_str(conns(cs).nick, "sasluser", "network nick used")
    conn_disconnect(cs, "bye")
    WAIT_FOR(conns(cs).st = CS_OFFLINE, 5)
    conn_free(cs)
End Scope

' ---------------------------------------------------------------- SOCKS5
t_begin("socks5")
Scope
    cfg.proxy_kind = NP_SOCKS5
    cfg.proxy_host = "127.0.0.1"
    cfg.proxy_port = base_port + 2
    Dim cx As Long = new_adhoc("proxied", base_port, 0, "proxyuser")
    WAIT_FOR(conn_online(cx), 15)
    check(conn_online(cx), "connects through the SOCKS5 proxy")
    check(has_line(conns(cx).status_buf, "via SOCKS5 proxy") > 0, "status shows the proxy")
    conn_disconnect(cx, "bye")
    WAIT_FOR(conns(cx).st = CS_OFFLINE, 5)
    conn_free(cx)
    cfg.proxy_kind = NP_NONE
End Scope

' ---------------------------------------------------------------- failures
t_begin("failures")
Scope
    Dim cr As Long = new_adhoc("refused", base_port + 50, 0, "nobody")
    WAIT_FOR(conns(cr).st = CS_WAIT_RECONNECT, 15)
    check_int(conns(cr).st, CS_WAIT_RECONNECT, "refused connection schedules a reconnect")
    check(has_line(conns(cr).status_buf, "Connection failed") > 0, "failure reported")
    conn_disconnect(cr)
    check_int(conns(cr).st, CS_OFFLINE, "disconnect cancels the reconnect")
    conn_free(cr)
    Dim cl As Long = conn_new(-1, "localhost")
    conns(cl).srv.host = "localhost"
    conns(cl).srv.port = base_port
    conns(cl).use_adhoc = 1
    cfg.nick = "localtest"
    conn_connect(cl)
    WAIT_FOR(conn_online(cl), 15)
    check(conn_online(cl), "host name resolution (localhost, trying each address)")
    conn_disconnect(cl, "bye")
    WAIT_FOR(conns(cl).st = CS_OFFLINE, 5)
    conn_free(cl)
End Scope

' ---------------------------------------------------------------- DCC
Function file_bytes(ByRef p As String) As String
    If file_exists(p) = 0 Then Return ""
    Dim fh As Long = FreeFile()
    Open p For Binary Access Read As #fh
    If Lof(fh) = 0 Then Close #fh : Return ""
    Dim s As String = Space(Lof(fh))
    Get #fh, 1, s
    Close #fh
    Return s
End Function

Sub write_bytes(ByRef p As String, ByRef d As String)
    Dim fh As Long = FreeFile()
    Open p For Binary Access Write As #fh
    Put #fh, 1, d
    Close #fh
End Sub

Function dcc_item_for(kind As Long, ByRef nick As String, st As Long) As Long
    Dim i As Long
    For i = DCC_MAX - 1 To 0 Step -1
        If dccs(i).alive AndAlso dccs(i).kind = kind AndAlso dccs(i).st = st AndAlso LCase(dccs(i).nick) = LCase(nick) Then Return i
    Next i
    Return -1
End Function

t_begin("dcc")
Scope
    Dim tdir As String = t_config_dir("vtirc_ng_nettest")
    Dim dl As String = tdir & "/dl"
    mkdir_p(dl)
    If file_exists(dl & "/payload.bin") Then Kill dl & "/payload.bin"
    If file_exists(dl & "/second file.bin") Then Kill dl & "/second file.bin"
    cfg.dcc_dir = dl
    cfg.dcc_auto_accept = 0
    Dim ca As Long = new_adhoc("dccA", base_port, 0, "dccsender")
    WAIT_FOR(conn_online(ca), 10)
    Dim cb As Long = new_adhoc("dccB", base_port, 0, "dccrecv")
    WAIT_FOR(conn_online(cb), 10)
    check(conn_online(ca) AndAlso conn_online(cb), "two connections for DCC")
    ' 300 KB of varied bytes (includes NULs)
    Dim payload As String = Space(300000)
    Dim k As Long
    For k = 0 To Len(payload) - 1
        payload[k] = (k * 7 + (k Shr 8)) And 255
    Next k
    Dim src As String = tdir & "/payload.bin"
    write_bytes(src, payload)

    ' ---- active send
    check(dcc_offer_send(ca, "dccrecv", src) >= 0, "offer a file")
    WAIT_FOR(dcc_item_for(DK_RECV, "dccsender", DS_OFFERED) >= 0, 10)
    check(dcc_item_for(DK_RECV, "dccsender", DS_OFFERED) >= 0, "receiver sees the offer")
    cmd_execute(conns(cb).status_buf, "/dcc get dccsender")
    WAIT_FOR(dcc_item_for(DK_RECV, "dccsender", DS_DONE) >= 0 AndAlso dcc_item_for(DK_SEND, "dccrecv", DS_DONE) >= 0, 20)
    check(dcc_item_for(DK_RECV, "dccsender", DS_DONE) >= 0, "receive completes")
    check(dcc_item_for(DK_SEND, "dccrecv", DS_DONE) >= 0, "send completes (all bytes acknowledged)")
    check(file_bytes(dl & "/payload.bin") = payload, "received file is identical")

    ' ---- passive (reverse) send of a file with a space in its name
    Dim src2 As String = tdir & "/second file.bin"
    write_bytes(src2, Left(payload, 70000))
    cfg.dcc_passive = 1
    check(dcc_offer_send(ca, "dccrecv", src2) >= 0, "passive offer")
    WAIT_FOR(dcc_item_for(DK_RECV, "dccsender", DS_OFFERED) >= 0, 10)
    cmd_execute(conns(cb).status_buf, "/dcc get dccsender")
    WAIT_FOR(file_exists(dl & "/second file.bin") AndAlso Len(file_bytes(dl & "/second file.bin")) = 70000 AndAlso _
             dcc_item_for(DK_RECV, "dccsender", DS_ACTIVE) < 0, 20)
    check(file_bytes(dl & "/second file.bin") = Left(payload, 70000), "passive DCC file identical (quoted name)")
    cfg.dcc_passive = 0

    ' ---- resume: a partial copy is completed instead of starting over
    Kill dl & "/payload.bin"
    write_bytes(dl & "/payload.bin", Left(payload, 123456))
    check(dcc_offer_send(ca, "dccrecv", src) >= 0, "offer again for resume")
    WAIT_FOR(dcc_item_for(DK_RECV, "dccsender", DS_OFFERED) >= 0, 10)
    cmd_execute(conns(cb).status_buf, "/dcc get dccsender")
    WAIT_FOR(Len(file_bytes(dl & "/payload.bin")) = 300000 AndAlso dcc_item_for(DK_RECV, "dccsender", DS_ACTIVE) < 0 _
             AndAlso dcc_item_for(DK_RECV, "dccsender", DS_CONNECTING) < 0, 20)
    check(file_bytes(dl & "/payload.bin") = payload, "resumed file identical")
    Dim resumed As Byte = 0
    For k = 0 To DCC_MAX - 1
        If dccs(k).alive AndAlso dccs(k).kind = DK_RECV AndAlso dccs(k).start_pos = 123456 Then resumed = 1
    Next k
    check(resumed, "transfer resumed at the partial size")
    If resumed = 0 Then
        For k = 0 To DCC_MAX - 1
            If dccs(k).alive Then Print "   dcc: " & dcc_status_line(k) & " start=" & dccs(k).start_pos & " msg=" & dccs(k).msg
        Next k
    End If

    ' ---- chat
    cmd_execute(conns(ca).status_buf, "/dcc chat dccrecv")
    WAIT_FOR(dcc_item_for(DK_CHAT, "dccsender", DS_OFFERED) >= 0, 10)
    cmd_execute(conns(cb).status_buf, "/dcc chat dccsender")
    WAIT_FOR(dcc_item_for(DK_CHAT, "dccrecv", DS_ACTIVE) >= 0 AndAlso dcc_item_for(DK_CHAT, "dccsender", DS_ACTIVE) >= 0, 10)
    Dim ia As Long = dcc_item_for(DK_CHAT, "dccrecv", DS_ACTIVE)
    Dim ib As Long = dcc_item_for(DK_CHAT, "dccsender", DS_ACTIVE)
    check(ia >= 0 AndAlso ib >= 0, "DCC chat connected on both sides")
    If ia >= 0 AndAlso ib >= 0 Then
        check_str(bufs(dccs(ia).buf).name, "=dccrecv", "DCC chat window name")
        cmd_execute(dccs(ia).buf, !"hello over dcc שלום")
        WAIT_FOR(has_line(dccs(ib).buf, "hello over dcc") > 0, 10)
        check(has_line(dccs(ib).buf, !"<dccsender> hello over dcc שלום") > 0, "chat line arrives (UTF-8)")
        cmd_execute(dccs(ib).buf, "/me waves back")
        WAIT_FOR(has_line(dccs(ia).buf, "dccrecv waves back") > 0, 10)
        check(has_line(dccs(ia).buf, "* dccrecv waves back", LK_ACTION) > 0, "/me over DCC chat")
    End If
    conn_disconnect(ca, "bye") : conn_disconnect(cb, "bye")
    WAIT_FOR(conn_any_closing() = 0, 5)
    conn_free(ca) : conn_free(cb)
End Scope

' ---------------------------------------------------------------- reconnect
t_begin("reconnect")
If tchan >= 0 AndAlso conn_online(cp) Then
    cmd_execute(tchan, "!drop")
    WAIT_FOR(conns(cp).st = CS_WAIT_RECONNECT, 10)
    check_int(conns(cp).st, CS_WAIT_RECONNECT, "dropped connection schedules a reconnect")
    check(bufs(tchan).joined = 0, "channel marked as not joined")
    WAIT_FOR(conn_online(cp) AndAlso bufs(tchan).joined <> 0, 20)
    check(conn_online(cp), "reconnects automatically")
    check(bufs(tchan).joined <> 0, "rejoins #test in the same window")
End If

conn_disconnect(cp, "done")
WAIT_FOR(conn_any_closing() = 0, 5)

Print "net tests: " & t_pass & " passed, " & t_fail & " failed"
End t_fail
