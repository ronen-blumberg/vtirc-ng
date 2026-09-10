' =============================================================================
' src/core/net.bas -- connections: resolve, TCP connect, proxy, TLS, I/O
'
' Establishing a connection (DNS, TCP connect, proxy handshake, TLS handshake)
' can take seconds, so it runs on a worker thread per attempt (net_job). The
' main loop polls the job; once connected the socket is non-blocking and all
' further I/O happens on the main thread.
'
' Requires vt/vt.bi included with VT_USE_TLS (sockets + mbedTLS glue).
' =============================================================================
#Ifdef __FB_WIN32__
    #Include Once "win/ws2tcpip.bi"
#Endif

Enum NET_PROXY_KIND
    NP_NONE = 0
    NP_SOCKS5
    NP_HTTP
End Enum

Enum NET_JOB_ST_T
    NJ_RUNNING = 0
    NJ_CONNECTED
    NJ_FAILED
End Enum

Type net_job
    ' request
    host        As String
    port        As Long
    use_tls     As Byte
    proxy_kind  As Long
    proxy_host  As String
    proxy_port  As Long
    proxy_user  As String
    proxy_pass  As String
    timeout_ms  As Long
    ' result (read by the main thread only after state <> NJ_RUNNING)
    state       As Long
    sock        As Long
    tls         As Any Ptr
    fingerprint As String
    peer_addr   As String
    errmsg      As String
    ' control
    cancel      As Long
    th          As Any Ptr
End Type

Dim Shared net_mutex  As Any Ptr
Dim Shared net_inited As Byte
Dim Shared net_zombies(Any) As Any Ptr     ' cancelled jobs whose thread may still run
Dim Shared net_zombie_count As Long

#Ifndef __FB_WIN32__
    Declare Function crt_signal Cdecl Alias "signal" (ByVal sig As Long, ByVal handler As Any Ptr) As Any Ptr
#Endif

Sub net_init()
    If net_inited Then Exit Sub
    #Ifndef __FB_WIN32__
        ' writing to a socket the peer closed must return an error, not kill
        ' the program (SIGPIPE = 13, SIG_IGN = 1)
        crt_signal(13, CPtr(Any Ptr, 1))
    #Endif
    vt_net_init()
    net_mutex  = MutexCreate()
    net_inited = 1
End Sub

' -----------------------------------------------------------------------------
' Low-level helpers (safe to call from the worker thread)
' -----------------------------------------------------------------------------
Private Sub net_set_timeouts(s As Long, ms As Long)
    #Ifdef __FB_WIN32__
        Dim tv As ULong = ms
    #Else
        Dim tv As timeval
        tv.tv_sec  = ms \ 1000
        tv.tv_usec = (ms Mod 1000) * 1000
    #Endif
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, Cast(Any Ptr, @tv), SizeOf(tv))
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, Cast(Any Ptr, @tv), SizeOf(tv))
End Sub

Private Function net_addr_string(sa As UByte Ptr, family As Long) As String
    Dim r As String
    Dim i As Long
    If family = AF_INET Then
        For i = 4 To 7
            r &= IIf(i > 4, ".", "") & sa[i]
        Next i
    ElseIf family = AF_INET6 Then
        For i = 0 To 7
            r &= IIf(i > 0, ":", "") & LCase(Hex((CULng(sa[8 + i * 2]) Shl 8) Or sa[9 + i * 2]))
        Next i
    End If
    Return r
End Function

' Wait for a non-blocking connect. Windows reports a refused connection in
' the exception set (not as writable), so both sets are watched.
' Returns 1 connected, 0 timed out, -1 failed.
Private Function net_wait_connect(s As Long, timeout_ms As Long) As Long
    Dim tv As timeval
    tv.tv_sec  = timeout_ms \ 1000
    tv.tv_usec = (timeout_ms Mod 1000) * 1000
    Dim wset As fd_set
    Dim eset As fd_set
    FD_SET_(s, @wset)
    FD_SET_(s, @eset)
    Dim r As Long = select_(s + 1, 0, @wset, @eset, @tv)
    If r = 0 Then Return 0
    If r < 0 Then Return -1
    If FD_ISSET(s, @eset) Then Return -1
    Dim so_err As Long = 0
    #Ifdef __FB_WIN32__
        Dim so_len As Long = SizeOf(so_err)
        getsockopt(s, SOL_SOCKET, SO_ERROR, Cast(ZString Ptr, @so_err), @so_len)
    #Else
        Dim so_len As socklen_t = SizeOf(so_err)
        getsockopt(s, SOL_SOCKET, SO_ERROR, @so_err, @so_len)
    #Endif
    Return IIf(so_err = 0, 1, -1)
End Function

' Resolve host and connect to the first address that answers within
' timeout_ms. Returns a blocking socket, or -1 with errmsg set.
Private Function net_tcp_connect(ByRef host As String, port As Long, timeout_ms As Long, _
                                 ByRef addr_out As String, ByRef errmsg As String) As Long
    Dim hints As addrinfo
    Dim res   As addrinfo Ptr = 0
    hints.ai_family   = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    Dim svc As String = LTrim(Str(port))
    If getaddrinfo(StrPtr(host), StrPtr(svc), @hints, @res) <> 0 OrElse res = 0 Then
        errmsg = "cannot resolve " & host
        Return -1
    End If
    Dim ai As addrinfo Ptr = res
    Dim s  As Long = -1
    errmsg = "connection refused"
    While ai <> 0
        s = socket_(ai->ai_family, ai->ai_socktype, ai->ai_protocol)
        If s >= 0 Then
            vt_net_nonblocking(s, 1)
            connect(s, ai->ai_addr, ai->ai_addrlen)
            Dim wc As Long = net_wait_connect(s, timeout_ms)
            If wc = 1 Then
                vt_net_nonblocking(s, 0)
                addr_out = net_addr_string(CPtr(UByte Ptr, ai->ai_addr), ai->ai_family)
                Exit While
            End If
            errmsg = IIf(wc = 0, "connection timed out", "connection refused")
            vt_net_close(s)
            s = -1
        End If
        ai = ai->ai_next
    Wend
    freeaddrinfo(res)
    Return s
End Function

Private Function net_send_all(s As Long, ByRef d As String) As Byte
    Dim sent As Long = 0
    Dim n    As Long
    While sent < Len(d)
        n = send(s, StrPtr(d) + sent, Len(d) - sent, 0)
        If n <= 0 Then Return 0
        sent += n
    Wend
    Return 1
End Function

' Read exactly n bytes (blocking with SO_RCVTIMEO); "" on failure.
Private Function net_recv_n(s As Long, n As Long) As String
    Dim r   As String = String(n, 0)
    Dim got As Long = 0
    Dim k   As Long
    While got < n
        k = recv(s, StrPtr(r) + got, n - got, 0)
        If k <= 0 Then Return ""
        got += k
    Wend
    Return r
End Function

' SOCKS5 CONNECT with remote DNS (the proxy resolves host -- Tor friendly).
Private Function net_socks5(s As Long, ByRef host As String, port As Long, _
                            ByRef user As String, ByRef pass As String, ByRef errmsg As String) As Byte
    Dim greet As String
    If Len(user) > 0 Then greet = Chr(5, 2, 0, 2) Else greet = Chr(5, 1, 0)
    If net_send_all(s, greet) = 0 Then errmsg = "SOCKS5: send failed" : Return 0
    Dim rep As String = net_recv_n(s, 2)
    If Len(rep) < 2 OrElse rep[0] <> 5 Then errmsg = "SOCKS5: bad reply from proxy" : Return 0
    If rep[1] = 2 Then
        Dim auth As String = Chr(1, Len(user)) & user & Chr(Len(pass)) & pass
        If net_send_all(s, auth) = 0 Then errmsg = "SOCKS5: send failed" : Return 0
        rep = net_recv_n(s, 2)
        If Len(rep) < 2 OrElse rep[1] <> 0 Then errmsg = "SOCKS5: authentication failed" : Return 0
    ElseIf rep[1] <> 0 Then
        errmsg = "SOCKS5: no acceptable authentication method" : Return 0
    End If
    If Len(host) > 255 Then errmsg = "SOCKS5: host name too long" : Return 0
    Dim req As String = Chr(5, 1, 0, 3, Len(host)) & host & Chr((port Shr 8) And 255, port And 255)
    If net_send_all(s, req) = 0 Then errmsg = "SOCKS5: send failed" : Return 0
    rep = net_recv_n(s, 4)
    If Len(rep) < 4 Then errmsg = "SOCKS5: proxy closed the connection" : Return 0
    If rep[1] <> 0 Then
        Select Case rep[1]
        Case 2 : errmsg = "SOCKS5: connection not allowed by ruleset"
        Case 3 : errmsg = "SOCKS5: network unreachable"
        Case 4 : errmsg = "SOCKS5: host unreachable"
        Case 5 : errmsg = "SOCKS5: connection refused"
        Case 6 : errmsg = "SOCKS5: TTL expired"
        Case Else : errmsg = "SOCKS5: proxy error " & rep[1]
        End Select
        Return 0
    End If
    Dim skip As Long
    Select Case rep[3]
    Case 1 : skip = 4 + 2
    Case 4 : skip = 16 + 2
    Case 3
        Dim ln As String = net_recv_n(s, 1)
        If Len(ln) = 0 Then errmsg = "SOCKS5: truncated reply" : Return 0
        skip = ln[0] + 2
    Case Else : errmsg = "SOCKS5: bad address type" : Return 0
    End Select
    If Len(net_recv_n(s, skip)) <> skip Then errmsg = "SOCKS5: truncated reply" : Return 0
    Return 1
End Function

Private Function net_http_connect(s As Long, ByRef host As String, port As Long, _
                                  ByRef user As String, ByRef pass As String, ByRef errmsg As String) As Byte
    Dim hp  As String = host & ":" & port
    Dim req As String = "CONNECT " & hp & " HTTP/1.1" & Chr(13, 10) & "Host: " & hp & Chr(13, 10)
    If Len(user) > 0 Then req &= "Proxy-Authorization: Basic " & base64_encode(user & ":" & pass) & Chr(13, 10)
    req &= Chr(13, 10)
    If net_send_all(s, req) = 0 Then errmsg = "HTTP proxy: send failed" : Return 0
    Dim hdr As String
    Dim c   As String
    Do
        c = net_recv_n(s, 1)
        If Len(c) = 0 Then errmsg = "HTTP proxy: connection closed" : Return 0
        hdr &= c
        If Len(hdr) > 8192 Then errmsg = "HTTP proxy: reply too long" : Return 0
    Loop Until Right(hdr, 4) = Chr(13, 10, 13, 10)
    Dim status As String = str_word(hdr, 1)
    If Left(hdr, 5) <> "HTTP/" OrElse status <> "200" Then
        errmsg = "HTTP proxy: " & Trim(Left(hdr, InStr(hdr, Chr(13)) - 1))
        Return 0
    End If
    Return 1
End Function

' -----------------------------------------------------------------------------
' Worker thread
' -----------------------------------------------------------------------------
Private Sub net_worker(ByVal p As Any Ptr)
    Dim j       As net_job Ptr = p
    Dim errmsg  As String
    Dim addr    As String
    Dim fp      As String
    Dim tls     As Any Ptr = 0
    Dim via_prx As Byte = IIf(j->proxy_kind <> NP_NONE AndAlso Len(j->proxy_host) > 0, 1, 0)
    Dim chost   As String = IIf(via_prx, j->proxy_host, j->host)
    Dim cport   As Long   = IIf(via_prx, j->proxy_port, j->port)

    Dim s As Long = net_tcp_connect(chost, cport, j->timeout_ms, addr, errmsg)
    If s >= 0 Then
        net_set_timeouts(s, j->timeout_ms)
        Dim ok As Byte = 1
        If via_prx Then
            If j->proxy_kind = NP_SOCKS5 Then
                ok = net_socks5(s, j->host, j->port, j->proxy_user, j->proxy_pass, errmsg)
            Else
                ok = net_http_connect(s, j->host, j->port, j->proxy_user, j->proxy_pass, errmsg)
            End If
        End If
        If ok AndAlso j->use_tls Then
            If vt_tls_connect(s, j->host, tls) <> 0 OrElse tls = 0 Then
                ok = 0
                errmsg = "TLS handshake failed"
                tls = 0
            Else
                fp = vt_tls_fingerprint(tls)
            End If
        End If
        If ok = 0 Then
            If tls <> 0 Then vt_tls_disconnect(tls)
            vt_net_close(s)
            s = -1
        Else
            vt_net_nonblocking(s, 1)
        End If
    End If

    MutexLock(net_mutex)
    If j->cancel Then
        ' the owner gave up on this attempt: release the connection; the main
        ' thread reaps the finished job (net_reap_zombies)
        If tls <> 0 Then vt_tls_disconnect(tls)
        If s >= 0 Then vt_net_close(s)
        j->sock  = -1
        j->tls   = 0
        j->state = NJ_FAILED
        MutexUnlock(net_mutex)
        Exit Sub
    End If
    j->sock        = s
    j->tls         = tls
    j->fingerprint = fp
    j->peer_addr   = addr
    j->errmsg      = errmsg
    j->state       = IIf(s >= 0, NJ_CONNECTED, NJ_FAILED)
    MutexUnlock(net_mutex)
End Sub

Function net_job_start(ByRef host As String, port As Long, use_tls As Byte, _
                       proxy_kind As Long = NP_NONE, ByRef proxy_host As String = "", _
                       proxy_port As Long = 0, ByRef proxy_user As String = "", _
                       ByRef proxy_pass As String = "", timeout_ms As Long = 20000) As net_job Ptr
    net_init()
    Dim j As net_job Ptr = New net_job
    j->host       = host
    j->port       = port
    j->use_tls    = use_tls
    j->proxy_kind = proxy_kind
    j->proxy_host = proxy_host
    j->proxy_port = proxy_port
    j->proxy_user = proxy_user
    j->proxy_pass = proxy_pass
    j->timeout_ms = timeout_ms
    j->state      = NJ_RUNNING
    j->sock       = -1
    j->th         = ThreadCreate(@net_worker, j)
    If j->th = 0 Then
        j->state  = NJ_FAILED
        j->errmsg = "cannot start connection thread"
    End If
    Return j
End Function

Function net_job_state(j As net_job Ptr) As Long
    If j = 0 Then Return NJ_FAILED
    MutexLock(net_mutex)
    Dim st As Long = j->state
    MutexUnlock(net_mutex)
    Return st
End Function

' Reap a finished job (after taking sock/tls out of it) and free it.
Sub net_job_free(j As net_job Ptr)
    If j = 0 Then Exit Sub
    If j->th <> 0 Then ThreadWait(j->th)
    Delete j
End Sub

' Abandon a job. A running worker is flagged and parked in the zombie list
' (reaped by net_reap_zombies once it finishes); a finished job is closed
' and freed right away.
Sub net_job_cancel(j As net_job Ptr)
    If j = 0 Then Exit Sub
    MutexLock(net_mutex)
    If j->state = NJ_RUNNING AndAlso j->th <> 0 Then
        j->cancel = 1
        MutexUnlock(net_mutex)
        If net_zombie_count > UBound(net_zombies) Then ReDim Preserve net_zombies(0 To net_zombie_count * 2 + 3)
        net_zombies(net_zombie_count) = j
        net_zombie_count += 1
        Exit Sub
    End If
    MutexUnlock(net_mutex)
    If j->tls <> 0 Then vt_tls_disconnect(j->tls)
    If j->sock >= 0 Then vt_net_close(j->sock)
    net_job_free(j)
End Sub

' Free cancelled jobs whose worker has finished (call periodically).
Sub net_reap_zombies()
    Dim i As Long = 0
    While i < net_zombie_count
        Dim j As net_job Ptr = net_zombies(i)
        If net_job_state(j) <> NJ_RUNNING Then
            net_job_free(j)
            net_zombie_count -= 1
            net_zombies(i) = net_zombies(net_zombie_count)
        Else
            i += 1
        End If
    Wend
End Sub

' -----------------------------------------------------------------------------
' Non-blocking I/O on an established connection (main thread)
' -----------------------------------------------------------------------------

' Returns bytes read (>0), 0 = nothing available, -1 = closed, -2 = error.
Function net_io_recv(s As Long, tls As Any Ptr, buf As ZString Ptr, n As Long) As Long
    If tls <> 0 Then
        Return vt_tls_recv(tls, buf, n)
    End If
    If vt_net_ready(s, 0, 0) <= 0 Then Return 0
    Dim r As Long = recv(s, buf, n, 0)
    If r > 0 Then Return r
    If r = 0 Then Return -1
    Return -2
End Function

' Returns bytes written (>=0; 0 = socket busy, try later) or -1 on error.
Function net_io_send(s As Long, tls As Any Ptr, buf As ZString Ptr, n As Long) As Long
    If vt_net_ready(s, 1, 0) <= 0 Then Return 0
    Dim r As Long
    If tls <> 0 Then
        r = vt_tls_send(tls, buf, n)
    Else
        r = send(s, buf, n, 0)
    End If
    If r < 0 Then Return -1
    Return r
End Function

Sub net_io_close(ByRef s As Long, ByRef tls As Any Ptr)
    If tls <> 0 Then vt_tls_disconnect(tls) : tls = 0
    If s >= 0 Then vt_net_close(s) : s = -1
End Sub
