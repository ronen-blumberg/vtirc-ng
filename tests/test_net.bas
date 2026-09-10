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
