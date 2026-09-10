' =============================================================================
' src/core/dcc.bas -- DCC CHAT, DCC SEND / RECEIVE (active, passive, resume)
'
'   CTCP offers:  DCC CHAT chat <ip> <port> [token]
'                 DCC SEND <file> <ip> <port> <size> [token]
'                 DCC RESUME <file> <port|0> <position> [token]
'                 DCC ACCEPT <file> <port|0> <position> [token]
'   <ip> is a 32-bit decimal number (IPv4) or an IPv6 literal. Port 0 with a
'   token is a passive (reverse) offer: the receiver listens instead.
'   Receivers acknowledge the byte count as a 32-bit big-endian number.
'
' Nothing is accepted automatically unless dcc_auto_accept is on; incoming
' file names are reduced to a safe name inside the download folder.
' =============================================================================

Const DCC_MAX = 64

Enum DCC_KIND_T
    DK_CHAT = 1
    DK_SEND
    DK_RECV
End Enum

Enum DCC_STATE_T
    DS_OFFERED = 1     ' incoming offer waiting for the user
    DS_LISTEN          ' we listen for the peer
    DS_CONNECTING      ' we connect to the peer (worker thread)
    DS_ACTIVE
    DS_DONE
    DS_FAILED
End Enum

Type dcc_item
    alive      As Byte
    kind       As Byte
    st         As Byte
    c          As Long        ' IRC connection it came from
    nick       As String
    fname      As String      ' name as offered / sent
    path       As String      ' local file
    size       As LongInt
    pos        As LongInt     ' bytes transferred (file position)
    start_pos  As LongInt
    acked      As LongInt
    ip         As String      ' peer address
    port       As Long
    token      As String
    passive    As Byte
    lsock      As Long        ' listening socket
    sock       As Long
    job        As net_job Ptr
    fh         As Long
    buf        As Long        ' DCC CHAT window
    rbuf       As String
    t_start    As Double
    t_last     As Double
    msg        As String      ' last status / error
End Type

Dim Shared dccs(0 To DCC_MAX - 1) As dcc_item
Dim Shared dcc_token_seq As Long

Private Function dcc_new(kind As Long, c As Long, ByRef nick As String) As Long
    Dim i As Long
    ' reuse finished slots
    For i = 0 To DCC_MAX - 1
        If dccs(i).alive = 0 Then Exit For
    Next i
    If i >= DCC_MAX Then
        For i = 0 To DCC_MAX - 1
            If dccs(i).st = DS_DONE OrElse dccs(i).st = DS_FAILED Then Exit For
        Next i
        If i >= DCC_MAX Then Return -1
    End If
    Dim blank As dcc_item
    dccs(i) = blank
    With dccs(i)
        .alive = 1 : .kind = kind : .c = c : .nick = nick
        .lsock = -1 : .sock = -1 : .fh = 0 : .buf = -1
        .t_start = clock_s() : .t_last = clock_s()
    End With
    Return i
End Function

Private Sub dcc_close_io(i As Long)
    With dccs(i)
        If .job <> 0 Then net_job_cancel(.job) : .job = 0
        If .lsock >= 0 Then vt_net_close(.lsock) : .lsock = -1
        If .sock >= 0 Then vt_net_close(.sock) : .sock = -1
        If .fh <> 0 Then Close #.fh : .fh = 0
    End With
End Sub

Private Sub dcc_report(i As Long, ByRef txt As String, is_err As Byte = 0)
    dccs(i).msg = txt
    Dim id As Long = IIf(buf_valid(dccs(i).buf), dccs(i).buf, ev_front_buf(dccs(i).c))
    If buf_valid(id) = 0 Then id = ui_active_buffer()
    ev_line(id, IIf(is_err, LK_ERROR, LK_CTCP), 0, IIf(is_err, "!!", "DCC"), dccs(i).nick, txt)
    ui_on_dcc()
End Sub

Private Sub dcc_fail(i As Long, ByRef why As String)
    dcc_close_io(i)
    dccs(i).st = DS_FAILED
    dcc_report(i, IIf(dccs(i).kind = DK_CHAT, "DCC CHAT with ", IIf(dccs(i).kind = DK_SEND, "DCC SEND of " & dccs(i).fname & " to ", "DCC RECV of " & dccs(i).fname & " from ")) & dccs(i).nick & " failed: " & why, 1)
End Sub

Function dcc_size_text(n As LongInt) As String
    If n < 1024 Then Return n & " B"
    If n < 1048576 Then Return LTrim(Str(CLng(n / 102.4) / 10)) & " KB"
    If n < 1073741824 Then Return LTrim(Str(CLng(n / 104857.6) / 10)) & " MB"
    Return LTrim(Str(CLng(n / 107374182.4) / 10)) & " GB"
End Function

' ---------------------------------------------------------------- addresses
' Decimal / dotted / IPv6 offer address -> connectable string.
Function dcc_ip_from_offer(ByRef s As String) As String
    If InStr(s, ":") > 0 OrElse InStr(s, ".") > 0 Then Return s
    Dim v As ULongInt = ValULng(s)
    Return ((v Shr 24) And 255) & "." & ((v Shr 16) And 255) & "." & ((v Shr 8) And 255) & "." & (v And 255)
End Function

' Dotted IPv4 -> decimal for offers (IPv6 literals pass through).
Function dcc_ip_to_offer(ByRef s As String) As String
    If InStr(s, ":") > 0 Then Return s
    Dim a() As String
    If str_split(s, ".", a()) <> 4 Then Return s
    Dim v As ULongInt = (CULngInt(Val(a(0))) Shl 24) Or (CULngInt(Val(a(1))) Shl 16) Or (CULngInt(Val(a(2))) Shl 8) Or CULngInt(Val(a(3)))
    Return LTrim(Str(v))
End Function

' Our address as announced in offers.
Private Function dcc_local_ip(c As Long) As String
    If Len(cfg.dcc_ip) > 0 Then Return cfg.dcc_ip
    If conn_valid(c) AndAlso conns(c).sock >= 0 AndAlso InStr(conns(c).peer, ":") = 0 Then
        Dim ip As Long, port As Long
        If vt_net_local_addr(conns(c).sock, ip, port) Then
            Dim b As UByte Ptr = CPtr(UByte Ptr, @ip)
            Return b[0] & "." & b[1] & "." & b[2] & "." & b[3]
        End If
    End If
    Return "127.0.0.1"
End Function

' Open a non-blocking listening socket; returns the port or 0.
Private Function dcc_listen(ByRef lsock As Long) As Long
    lsock = vt_net_open()
    If lsock < 0 Then lsock = -1 : Return 0
    Dim lo As Long = cfg.dcc_port_lo
    Dim hi As Long = cfg.dcc_port_hi
    Dim ok As Byte = 0
    If lo > 0 AndAlso hi >= lo Then
        Dim p As Long
        For p = lo To hi
            If vt_net_bind(lsock, p) Then ok = 1 : Exit For
        Next p
    Else
        ok = vt_net_bind(lsock, 0)
    End If
    If ok = 0 OrElse vt_net_listen(lsock, 1) = 0 Then vt_net_close(lsock) : lsock = -1 : Return 0
    vt_net_nonblocking(lsock, 1)
    Dim ip As Long, port As Long
    vt_net_local_addr(lsock, ip, port)
    Return port
End Function

Private Function dcc_quote_name(ByRef nm As String) As String
    If InStr(nm, " ") > 0 Then Return """" & nm & """"
    Return nm
End Function

' Unique download path for an offered name (no directories, no overwrite).
Private Function dcc_target_path(ByRef offered As String) As String
    Dim nm As String = offered
    ' strip any directory part the sender tried to smuggle in
    Dim k As Long
    For k = Len(nm) To 1 Step -1
        If Mid(nm, k, 1) = "/" OrElse Mid(nm, k, 1) = "\" Then nm = Mid(nm, k + 1) : Exit For
    Next k
    nm = path_sanitize(nm)
    Dim d As String = IIf(Len(cfg.dcc_dir) > 0, cfg.dcc_dir, path_dl_dir)
    mkdir_p(d)
    Dim p As String = path_join(d, nm)
    Return p
End Function

' ---------------------------------------------------------------- offers in
Private Function dcc_find(kind As Long, ByRef nick As String, st As Long, ByRef fname As String = "") As Long
    Dim i As Long
    For i = DCC_MAX - 1 To 0 Step -1
        If dccs(i).alive AndAlso dccs(i).kind = kind AndAlso dccs(i).st = st AndAlso LCase(dccs(i).nick) = LCase(nick) Then
            If Len(fname) = 0 OrElse LCase(dccs(i).fname) = LCase(fname) Then Return i
        End If
    Next i
    Return -1
End Function

Private Function dcc_find_token(ByRef tok As String) As Long
    If Len(tok) = 0 Then Return -1
    Dim i As Long
    For i = 0 To DCC_MAX - 1
        If dccs(i).alive AndAlso dccs(i).token = tok AndAlso dccs(i).st <> DS_DONE AndAlso dccs(i).st <> DS_FAILED Then Return i
    Next i
    Return -1
End Function

' Split a DCC argument string honouring "quoted file names".
Private Function dcc_args(ByRef s As String, a() As String) As Long
    Dim n As Long = 0
    Dim i As Long = 0
    ReDim a(0 To 7)
    While i < Len(s)
        While i < Len(s) AndAlso s[i] = 32
            i += 1
        Wend
        If i >= Len(s) Then Exit While
        Dim t As String
        If s[i] = 34 Then
            Dim e As Long = InStr(i + 2, s, """")
            If e = 0 Then e = Len(s) + 1
            t = Mid(s, i + 2, e - i - 2)
            i = e
        Else
            Dim st As Long = i
            While i < Len(s) AndAlso s[i] <> 32
                i += 1
            Wend
            t = Mid(s, st + 1, i - st)
        End If
        If n > UBound(a) Then ReDim Preserve a(0 To n * 2 + 1)
        a(n) = t
        n += 1
    Wend
    Return n
End Function

Declare Sub dcc_accept_idx(i As Long)

Sub dcc_on_ctcp(c As Long, ByRef m As irc_msg, ByRef arg As String)
    Dim a() As String
    Dim n As Long = dcc_args(arg, a())
    If n < 1 Then Exit Sub
    Dim what As String = UCase(a(0))
    Select Case what
    Case "CHAT"
        If n < 4 Then Exit Sub
        Dim tok As String = IIf(n >= 5, a(4), "")
        ' reply to our passive chat offer?
        Dim j As Long = dcc_find_token(tok)
        If j >= 0 AndAlso dccs(j).st = DS_LISTEN Then Exit Sub
        Dim i As Long = dcc_new(DK_CHAT, c, m.nick)
        If i < 0 Then Exit Sub
        dccs(i).ip = dcc_ip_from_offer(a(2))
        dccs(i).port = str_to_int(a(3), 0)
        dccs(i).token = tok
        dccs(i).passive = IIf(dccs(i).port = 0, 1, 0)
        dccs(i).st = DS_OFFERED
        dcc_report(i, m.nick & " offers a DCC CHAT -- type /dcc chat " & m.nick & " to accept")
        ev_notify(ev_front_buf(c), NK_DCC, "DCC chat offer", m.nick & " wants to chat")
    Case "SEND"
        If n < 5 Then Exit Sub
        Dim fn As String = a(1)
        Dim port As Long = str_to_int(a(3), 0)
        Dim tok As String = IIf(n >= 6, a(5), "")
        ' the answer to one of our passive sends: connect and push the file
        Dim j As Long = dcc_find_token(tok)
        If j >= 0 AndAlso dccs(j).kind = DK_SEND AndAlso port > 0 Then
            dccs(j).ip = dcc_ip_from_offer(a(2))
            dccs(j).port = port
            dccs(j).job = net_job_start(dccs(j).ip, port, 0)
            dccs(j).st = DS_CONNECTING
            Exit Sub
        End If
        Dim i As Long = dcc_new(DK_RECV, c, m.nick)
        If i < 0 Then Exit Sub
        dccs(i).fname = fn
        dccs(i).ip = dcc_ip_from_offer(a(2))
        dccs(i).port = port
        dccs(i).size = ValLng(a(4))
        dccs(i).token = tok
        dccs(i).passive = IIf(port = 0, 1, 0)
        dccs(i).st = DS_OFFERED
        dcc_report(i, m.nick & " offers the file " & fn & " (" & dcc_size_text(dccs(i).size) & ") -- type /dcc get " & m.nick & " to accept")
        ev_notify(ev_front_buf(c), NK_DCC, "DCC file offer", m.nick & ": " & fn)
        If cfg.dcc_auto_accept Then dcc_accept_idx(i)
    Case "RESUME"
        ' peer wants our file from a position: DCC RESUME file port pos [token]
        If n < 4 Then Exit Sub
        Dim port As Long = str_to_int(a(2), 0)
        Dim tok As String = IIf(n >= 5, a(4), "")
        Dim i As Long
        For i = 0 To DCC_MAX - 1
            If dccs(i).alive AndAlso dccs(i).kind = DK_SEND AndAlso dccs(i).st = DS_LISTEN AndAlso _
               LCase(dccs(i).nick) = LCase(m.nick) AndAlso (dccs(i).port = port OrElse (Len(tok) > 0 AndAlso dccs(i).token = tok)) Then
                Dim p As LongInt = ValLng(a(3))
                If p > 0 AndAlso p < dccs(i).size Then
                    dccs(i).pos = p : dccs(i).start_pos = p
                    conn_send(c, "PRIVMSG " & m.nick & " :" & Chr(1) & "DCC ACCEPT " & dcc_quote_name(dccs(i).fname) & " " & a(2) & " " & p & IIf(Len(tok) > 0, " " & tok, "") & Chr(1))
                    dcc_report(i, m.nick & " resumes " & dccs(i).fname & " at " & dcc_size_text(p))
                End If
                Exit For
            End If
        Next i
    Case "ACCEPT"
        ' our resume request was accepted: connect now
        If n < 4 Then Exit Sub
        Dim i As Long
        For i = 0 To DCC_MAX - 1
            If dccs(i).alive AndAlso dccs(i).kind = DK_RECV AndAlso dccs(i).st = DS_OFFERED AndAlso _
               LCase(dccs(i).nick) = LCase(m.nick) AndAlso dccs(i).start_pos > 0 Then
                dccs(i).pos = dccs(i).start_pos
                dccs(i).job = net_job_start(dccs(i).ip, dccs(i).port, 0)
                dccs(i).st = DS_CONNECTING
                Exit For
            End If
        Next i
    Case Else
        ev_front(c, "Unsupported DCC " & what & " from " & m.nick, LK_CTCP, ">>")
    End Select
End Sub

' ---------------------------------------------------------------- accepting / offering
Private Sub dcc_open_chat_window(i As Long)
    Dim nm As String = "=" & dccs(i).nick
    Dim id As Long = buf_find_kind(dccs(i).c, BK_DCC, nm)
    If id < 0 Then id = buf_new(dccs(i).c, BK_DCC, nm, 1)
    dccs(i).buf = id
End Sub

Sub dcc_accept_idx(i As Long)
    With dccs(i)
        If .st <> DS_OFFERED Then Exit Sub
        If .kind = DK_RECV Then
            .path = dcc_target_path(.fname)
            ' resume a partial download of the same name
            If file_exists(.path) AndAlso FileLen(.path) > 0 AndAlso FileLen(.path) < .size AndAlso .passive = 0 Then
                .start_pos = FileLen(.path)
                conn_send(.c, "PRIVMSG " & .nick & " :" & Chr(1) & "DCC RESUME " & dcc_quote_name(.fname) & " " & .port & " " & .start_pos & IIf(Len(.token) > 0, " " & .token, "") & Chr(1))
                dcc_report(i, "Asking " & .nick & " to resume " & .fname & " at " & dcc_size_text(.start_pos))
                Exit Sub
            End If
            ' never overwrite: pick name.1, name.2 ...
            If file_exists(.path) Then
                Dim k As Long = 1
                While file_exists(.path & "." & k)
                    k += 1
                Wend
                .path = .path & "." & k
            End If
        End If
        If .passive Then
            Dim port As Long = dcc_listen(.lsock)
            If port = 0 Then dcc_fail(i, "cannot open a listening port") : Exit Sub
            Dim ip As String = dcc_ip_to_offer(dcc_local_ip(.c))
            If .kind = DK_CHAT Then
                conn_send(.c, "PRIVMSG " & .nick & " :" & Chr(1) & "DCC CHAT chat " & ip & " " & port & " " & .token & Chr(1))
            Else
                conn_send(.c, "PRIVMSG " & .nick & " :" & Chr(1) & "DCC SEND " & dcc_quote_name(.fname) & " " & ip & " " & port & " " & .size & " " & .token & Chr(1))
            End If
            .port = port
            .st = DS_LISTEN
        Else
            .job = net_job_start(.ip, .port, 0)
            .st = DS_CONNECTING
        End If
        .t_last = clock_s()
        dcc_report(i, "Accepted " & IIf(.kind = DK_CHAT, "DCC CHAT with " & .nick, .fname & " from " & .nick & " -> " & .path))
    End With
End Sub

Function dcc_offer_chat(c As Long, ByRef nick As String) As Long
    Dim i As Long = dcc_new(DK_CHAT, c, nick)
    If i < 0 Then Return -1
    Dim port As Long = dcc_listen(dccs(i).lsock)
    If port = 0 Then dcc_fail(i, "cannot open a listening port") : Return -1
    dccs(i).port = port
    dccs(i).st = DS_LISTEN
    conn_send(c, "PRIVMSG " & nick & " :" & Chr(1) & "DCC CHAT chat " & dcc_ip_to_offer(dcc_local_ip(c)) & " " & port & Chr(1))
    dcc_report(i, "DCC CHAT offered to " & nick)
    Return i
End Function

Function dcc_offer_send(c As Long, ByRef nick As String, ByRef path As String) As Long
    If file_exists(path) = 0 Then Return -1
    Dim i As Long = dcc_new(DK_SEND, c, nick)
    If i < 0 Then Return -1
    With dccs(i)
        .path = path
        .fname = path
        Dim k As Long
        For k = Len(path) To 1 Step -1
            If Mid(path, k, 1) = "/" OrElse Mid(path, k, 1) = "\" Then .fname = Mid(path, k + 1) : Exit For
        Next k
        .size = FileLen(path)
        If cfg.dcc_passive Then
            dcc_token_seq += 1
            .token = LTrim(Str(dcc_token_seq + Int(Rnd * 100000)))
            .passive = 1
            .st = DS_LISTEN     ' waiting for the receiver's address
            .port = 0
            conn_send(c, "PRIVMSG " & nick & " :" & Chr(1) & "DCC SEND " & dcc_quote_name(.fname) & " " & dcc_ip_to_offer(dcc_local_ip(c)) & " 0 " & .size & " " & .token & Chr(1))
        Else
            Dim port As Long = dcc_listen(.lsock)
            If port = 0 Then dcc_fail(i, "cannot open a listening port") : Return -1
            .port = port
            .st = DS_LISTEN
            conn_send(c, "PRIVMSG " & nick & " :" & Chr(1) & "DCC SEND " & dcc_quote_name(.fname) & " " & dcc_ip_to_offer(dcc_local_ip(c)) & " " & port & " " & .size & Chr(1))
        End If
    End With
    dcc_report(i, "Offering " & dccs(i).fname & " (" & dcc_size_text(dccs(i).size) & ") to " & nick)
    Return i
End Function

Sub dcc_chat_send(buf_id As Long, ByRef text As String)
    Dim i As Long
    For i = 0 To DCC_MAX - 1
        If dccs(i).alive AndAlso dccs(i).kind = DK_CHAT AndAlso dccs(i).buf = buf_id Then
            If dccs(i).st <> DS_ACTIVE Then Exit For
            Dim ln As String = text & Chr(10)
            Dim sent As Long = 0
            While sent < Len(ln)
                Dim w As Long = net_io_send(dccs(i).sock, 0, StrPtr(ln) + sent, Len(ln) - sent)
                If w < 0 Then dcc_fail(i, "connection lost") : Exit Sub
                If w = 0 Then Sleep 1, 1 Else sent += w
            Wend
            Dim me As String = conn_nick(dccs(i).c)
            If Left(text, 8) = Chr(1) & "ACTION " Then
                ev_line(buf_id, LK_ACTION, LF_SELF, "*", me, me & " " & Mid(text, 9, Len(text) - 9))
            Else
                ev_line(buf_id, LK_MSG, LF_SELF, "<" & me & ">", me, text)
            End If
            Exit Sub
        End If
    Next i
    ev_line(buf_id, LK_ERROR, 0, "!!", "", "DCC chat is not connected")
End Sub

' ---------------------------------------------------------------- transfer loop
Private Sub dcc_activate(i As Long)
    With dccs(i)
        .st = DS_ACTIVE
        .t_start = clock_s()
        .t_last = clock_s()
        Select Case .kind
        Case DK_CHAT
            dcc_open_chat_window(i)
            dcc_report(i, "DCC CHAT connected with " & .nick)
        Case DK_RECV
            .fh = FreeFile()
            ' read/write access: "Access Write" alone would truncate a file being resumed
            If Open(.path For Binary As #.fh) <> 0 Then .fh = 0 : dcc_fail(i, "cannot write " & .path) : Exit Sub
            If .start_pos > 0 Then Seek #.fh, .start_pos + 1
            .pos = .start_pos
            dcc_report(i, "Receiving " & .fname & " from " & .nick)
        Case DK_SEND
            .fh = FreeFile()
            If Open(.path For Binary Access Read As #.fh) <> 0 Then .fh = 0 : dcc_fail(i, "cannot read " & .path) : Exit Sub
            dcc_report(i, "Sending " & .fname & " to " & .nick)
        End Select
    End With
End Sub

Private Sub dcc_finish(i As Long)
    dcc_close_io(i)
    dccs(i).st = DS_DONE
    Dim secs As Double = clock_s() - dccs(i).t_start
    If secs < 0.001 Then secs = 0.001
    Select Case dccs(i).kind
    Case DK_CHAT : dcc_report(i, "DCC CHAT with " & dccs(i).nick & " closed")
    Case DK_RECV : dcc_report(i, "Received " & dccs(i).fname & " (" & dcc_size_text(dccs(i).pos) & ", " & dcc_size_text((dccs(i).pos - dccs(i).start_pos) / secs) & "/s) -> " & dccs(i).path)
    Case DK_SEND : dcc_report(i, "Sent " & dccs(i).fname & " to " & dccs(i).nick & " (" & dcc_size_text(dccs(i).pos) & ", " & dcc_size_text((dccs(i).pos - dccs(i).start_pos) / secs) & "/s)")
    End Select
End Sub

Private Sub dcc_poll_one(i As Long)
    Dim now As Double = clock_s()
    With dccs(i)
        Select Case .st
        Case DS_LISTEN
            If .lsock >= 0 AndAlso vt_net_ready(.lsock, 0, 0) > 0 Then
                Dim s As Long = vt_net_accept(.lsock)
                If s >= 0 Then
                    vt_net_close(.lsock) : .lsock = -1
                    vt_net_nonblocking(s, 1)
                    .sock = s
                    dcc_activate(i)
                End If
            ElseIf now - .t_last > 180 Then
                dcc_fail(i, "no answer within 3 minutes")
            End If
        Case DS_CONNECTING
            Dim js As Long = net_job_state(.job)
            If js = NJ_CONNECTED Then
                .sock = .job->sock
                net_job_free(.job) : .job = 0
                dcc_activate(i)
            ElseIf js = NJ_FAILED Then
                Dim em As String = .job->errmsg
                net_job_free(.job) : .job = 0
                dcc_fail(i, em)
            End If
        Case DS_ACTIVE
            Dim buf As ZString * 16385
            Select Case .kind
            Case DK_CHAT
                Do
                    Dim r As Long = net_io_recv(.sock, 0, @buf, 16384)
                    If r > 0 Then
                        Dim chunk As String = Space(r)
                        memcpy(StrPtr(chunk), @buf, r)
                        .rbuf &= chunk
                        .t_last = now
                    ElseIf r = 0 Then
                        Exit Do
                    Else
                        dcc_finish(i)
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
                    ln = utf8_from_wire(ln, CHARSET_CP1252)
                    If Left(ln, 8) = Chr(1) & "ACTION " Then
                        ev_line(.buf, LK_ACTION, 0, "*", .nick, .nick & " " & Mid(ln, 9, Len(ln) - 9))
                    Else
                        ev_line(.buf, LK_MSG, 0, "<" & .nick & ">", .nick, ln)
                    End If
                Loop
            Case DK_RECV
                Dim got As Long = 0
                Do
                    Dim r As Long = net_io_recv(.sock, 0, @buf, 16384)
                    If r > 0 Then
                        Put #.fh, , *CPtr(UByte Ptr, @buf), r
                        .pos += r
                        got += r
                        .t_last = now
                        If got > 1048576 Then Exit Do
                    ElseIf r = 0 Then
                        Exit Do
                    Else
                        If .pos >= .size Then dcc_finish(i) Else dcc_fail(i, "connection closed at " & dcc_size_text(.pos))
                        Exit Sub
                    End If
                Loop
                If got > 0 Then
                    ' acknowledge the byte count (32-bit big-endian)
                    Dim ack As ULong = CULng(.pos And &hFFFFFFFFULL)
                    Dim ab As String = Chr((ack Shr 24) And 255, (ack Shr 16) And 255, (ack Shr 8) And 255, ack And 255)
                    net_io_send(.sock, 0, StrPtr(ab), 4)
                    ui_on_dcc()
                End If
                If .pos >= .size AndAlso .size > 0 Then dcc_finish(i) : Exit Sub
            Case DK_SEND
                ' read acknowledgements
                Do
                    Dim r As Long = net_io_recv(.sock, 0, @buf, 16384)
                    If r > 0 Then
                        Dim ackc As String = Space(r)
                        memcpy(StrPtr(ackc), @buf, r)
                        .rbuf &= ackc
                        .t_last = now
                    ElseIf r = 0 Then
                        Exit Do
                    Else
                        If .pos >= .size Then dcc_finish(i) Else dcc_fail(i, "receiver closed the connection at " & dcc_size_text(.pos))
                        Exit Sub
                    End If
                Loop
                While Len(.rbuf) >= 4
                    .acked = (CULng(.rbuf[0]) Shl 24) Or (CULng(.rbuf[1]) Shl 16) Or (CULng(.rbuf[2]) Shl 8) Or .rbuf[3]
                    .rbuf = Mid(.rbuf, 5)
                Wend
                ' send more (bounded per tick)
                Dim budget As Long = 1048576
                While .pos < .size AndAlso budget > 0
                    Dim want As Long = IIf(.size - .pos > 16384, 16384, CLng(.size - .pos))
                    Dim chunk As String = Space(want)
                    Get #.fh, .pos + 1, chunk
                    Dim w As Long = net_io_send(.sock, 0, StrPtr(chunk), want)
                    If w < 0 Then dcc_fail(i, "connection lost") : Exit Sub
                    If w = 0 Then Exit While
                    .pos += w
                    budget -= w
                    .t_last = now
                Wend
                If .pos >= .size AndAlso (.acked = (.size And &hFFFFFFFFULL) OrElse now - .t_last > 30) Then dcc_finish(i) : Exit Sub
                ui_on_dcc()
            End Select
            If .st = DS_ACTIVE AndAlso now - .t_last > 300 Then dcc_fail(i, "stalled for 5 minutes")
        End Select
    End With
End Sub

Sub dcc_poll()
    Dim i As Long
    For i = 0 To DCC_MAX - 1
        If dccs(i).alive AndAlso (dccs(i).st = DS_LISTEN OrElse dccs(i).st = DS_CONNECTING OrElse dccs(i).st = DS_ACTIVE) Then
            dcc_poll_one(i)
        End If
    Next i
End Sub

Function dcc_status_line(i As Long) As String
    With dccs(i)
        Dim kind As String = IIf(.kind = DK_CHAT, "CHAT", IIf(.kind = DK_SEND, "SEND", "RECV"))
        Dim st As String
        Select Case .st
        Case DS_OFFERED    : st = "offered"
        Case DS_LISTEN     : st = "waiting"
        Case DS_CONNECTING : st = "connecting"
        Case DS_ACTIVE     : st = "active"
        Case DS_DONE       : st = "done"
        Case DS_FAILED     : st = "failed"
        End Select
        Dim prog As String = ""
        If .kind <> DK_CHAT AndAlso .size > 0 Then
            prog = " " & CLng(.pos * 100 / .size) & "% of " & dcc_size_text(.size)
            If .st = DS_ACTIVE Then
                Dim secs As Double = clock_s() - .t_start
                If secs > 0.5 Then prog &= " " & dcc_size_text((.pos - .start_pos) / secs) & "/s"
            End If
        End If
        Return "#" & (i + 1) & " " & kind & " " & .nick & " " & IIf(.kind <> DK_CHAT, .fname & " ", "") & "[" & st & "]" & prog
    End With
End Function

' /dcc chat|send|get|close|list
Sub dcc_command(c As Long, buf As Long, ByRef args As String)
    Dim a() As String
    Dim n As Long = dcc_args(args, a())
    Dim op As String = IIf(n > 0, LCase(a(0)), "list")
    Dim i As Long
    Select Case op
    Case "chat"
        If n < 2 Then ev_client("Usage: /dcc chat <nick>") : Exit Sub
        i = dcc_find(DK_CHAT, a(1), DS_OFFERED)
        If i >= 0 Then dcc_accept_idx(i) : Exit Sub
        If conn_online(c) = 0 Then ev_client("Not connected") : Exit Sub
        dcc_offer_chat(c, a(1))
    Case "send"
        If n < 3 Then ev_client("Usage: /dcc send <nick> <file>") : Exit Sub
        If conn_online(c) = 0 Then ev_client("Not connected") : Exit Sub
        Dim path As String = a(2)
        Dim k As Long
        For k = 3 To n - 1
            path &= " " & a(k)
        Next k
        If dcc_offer_send(c, a(1), path) < 0 Then ev_client("Cannot send " & path & " (file not found?)", LK_ERROR)
    Case "get", "accept"
        If n < 2 Then ev_client("Usage: /dcc get <nick> [file]") : Exit Sub
        i = dcc_find(DK_RECV, a(1), DS_OFFERED, IIf(n >= 3, a(2), ""))
        If i < 0 Then i = dcc_find(DK_CHAT, a(1), DS_OFFERED)
        If i < 0 Then ev_client("No DCC offer from " & a(1), LK_ERROR) : Exit Sub
        dcc_accept_idx(i)
    Case "close", "cancel", "reject"
        If n < 2 Then ev_client("Usage: /dcc close <nick|#number>") : Exit Sub
        For i = 0 To DCC_MAX - 1
            If dccs(i).alive AndAlso dccs(i).st <> DS_DONE AndAlso dccs(i).st <> DS_FAILED Then
                If LCase(dccs(i).nick) = LCase(a(1)) OrElse "#" & (i + 1) = a(1) Then
                    dcc_close_io(i)
                    dccs(i).st = DS_FAILED
                    dcc_report(i, "DCC with " & dccs(i).nick & " closed by you")
                End If
            End If
        Next i
    Case Else
        Dim any_ As Byte = 0
        For i = 0 To DCC_MAX - 1
            If dccs(i).alive Then ev_client(dcc_status_line(i)) : any_ = 1
        Next i
        If any_ = 0 Then ev_client("No DCC transfers. /dcc send <nick> <file>, /dcc chat <nick>, /dcc get <nick>")
    End Select
End Sub
