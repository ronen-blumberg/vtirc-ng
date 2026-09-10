' =============================================================================
' src/core/events.bas -- printing into buffers: activity, highlights,
' notifications, logging, ignore list
' =============================================================================

' ---------------------------------------------------------------- ignore list
Const IGN_MSG     = 1      ' channel messages / actions
Const IGN_PRIV    = 2      ' private messages
Const IGN_NOTICE  = 4
Const IGN_CTCP    = 8
Const IGN_INVITE  = 16
Const IGN_JOINS   = 32     ' join / part / quit / nick noise
Const IGN_DCC     = 64
Const IGN_ALL     = 127

Type ignore_entry
    mask  As String        ' nick!user@host wildcard
    types As Long
End Type

Dim Shared ignores(Any) As ignore_entry
Dim Shared ignore_count As Long
Dim Shared hl_words(Any) As String      ' extra highlight words (lower case)
Dim Shared hl_count As Long

Function ignore_types_from(ByRef s As String) As Long
    Dim a() As String
    Dim n As Long = str_words(str_replace(s, ",", " "), a())
    Dim t As Long = 0
    Dim i As Long
    For i = 0 To n - 1
        Select Case LCase(a(i))
        Case "msg", "msgs", "chan"   : t Or= IGN_MSG
        Case "priv", "privs", "query": t Or= IGN_PRIV
        Case "notice", "notices"     : t Or= IGN_NOTICE
        Case "ctcp", "ctcps"         : t Or= IGN_CTCP
        Case "invite", "invites"     : t Or= IGN_INVITE
        Case "joins", "join"         : t Or= IGN_JOINS
        Case "dcc"                   : t Or= IGN_DCC
        Case "all"                   : t Or= IGN_ALL
        End Select
    Next i
    If t = 0 Then t = IGN_ALL
    Return t
End Function

Function ignore_types_text(t As Long) As String
    If t = IGN_ALL Then Return "all"
    Dim r As String
    If t And IGN_MSG    Then r &= " msgs"
    If t And IGN_PRIV   Then r &= " privs"
    If t And IGN_NOTICE Then r &= " notices"
    If t And IGN_CTCP   Then r &= " ctcps"
    If t And IGN_INVITE Then r &= " invites"
    If t And IGN_JOINS  Then r &= " joins"
    If t And IGN_DCC    Then r &= " dcc"
    Return LTrim(r)
End Function

' Normalise "nick" -> "nick!*@*", "user@host" -> "*!user@host".
Function ignore_norm_mask(ByRef m As String) As String
    If InStr(m, "!") = 0 AndAlso InStr(m, "@") = 0 Then Return m & "!*@*"
    If InStr(m, "!") = 0 Then Return "*!" & m
    If InStr(m, "@") = 0 Then Return m & "@*"
    Return m
End Function

Sub ignore_load()
    ignore_count = 0
    Erase ignores
    Dim n As Long
    Dim i As Long
    For i = 0 To cfg_ini.cnt - 1
        If LCase(cfg_ini.ents(i).sec) = "ignore" Then
            n = ignore_count
            If n > UBound(ignores) Then ReDim Preserve ignores(0 To n * 2 + 7)
            ignores(n).mask  = cfg_ini.ents(i).key
            ignores(n).types = ignore_types_from(cfg_ini.ents(i).value)
            ignore_count += 1
        End If
    Next i
End Sub

Sub ignore_save()
    ini_del_section(cfg_ini, "ignore")
    Dim i As Long
    For i = 0 To ignore_count - 1
        ini_add(cfg_ini, "ignore", ignores(i).mask, ignore_types_text(ignores(i).types))
    Next i
End Sub

Function ignore_add(ByRef mask As String, types As Long) As Long
    Dim m As String = ignore_norm_mask(mask)
    Dim i As Long
    For i = 0 To ignore_count - 1
        If LCase(ignores(i).mask) = LCase(m) Then ignores(i).types = types : Return i
    Next i
    If ignore_count > UBound(ignores) Then ReDim Preserve ignores(0 To ignore_count * 2 + 7)
    ignores(ignore_count).mask = m
    ignores(ignore_count).types = types
    ignore_count += 1
    Return ignore_count - 1
End Function

Function ignore_remove(ByRef mask As String) As Byte
    Dim m As String = ignore_norm_mask(mask)
    Dim i As Long
    For i = 0 To ignore_count - 1
        If LCase(ignores(i).mask) = LCase(m) OrElse LCase(ignores(i).mask) = LCase(mask) Then
            Dim k As Long
            For k = i To ignore_count - 2
                ignores(k) = ignores(k + 1)
            Next k
            ignore_count -= 1
            Return 1
        End If
    Next i
    Return 0
End Function

Function ignore_match(ByRef src As String, types As Long) As Byte
    If ignore_count = 0 OrElse Len(src) = 0 Then Return 0
    Dim full As String = src
    If InStr(full, "!") = 0 Then full &= "!*@*"
    Dim i As Long
    For i = 0 To ignore_count - 1
        If (ignores(i).types And types) <> 0 AndAlso wild_match(ignores(i).mask, full) Then Return 1
    Next i
    Return 0
End Function

' ---------------------------------------------------------------- highlights
Sub highlight_load()
    hl_count = 0
    Erase hl_words
    Dim i As Long
    For i = 0 To cfg_ini.cnt - 1
        If LCase(cfg_ini.ents(i).sec) = "highlight" AndAlso Len(cfg_ini.ents(i).value) > 0 Then
            If hl_count > UBound(hl_words) Then ReDim Preserve hl_words(0 To hl_count * 2 + 7)
            hl_words(hl_count) = utf8_lcase(cfg_ini.ents(i).value)
            hl_count += 1
        End If
    Next i
End Sub

Sub highlight_save()
    ini_del_section(cfg_ini, "highlight")
    Dim i As Long
    For i = 0 To hl_count - 1
        ini_add(cfg_ini, "highlight", "word", hl_words(i))
    Next i
End Sub

Private Function hl_is_word_char(c As UByte) As Byte
    Return IIf((c >= 48 AndAlso c <= 57) OrElse (c >= 65 AndAlso c <= 90) OrElse _
               (c >= 97 AndAlso c <= 122) OrElse c = 95 OrElse c >= 128, 1, 0)
End Function

' Case-insensitive whole-word search of needle (already lower case) in hay.
Function hl_word_in(ByRef hay As String, ByRef needle As String) As Byte
    If Len(needle) = 0 Then Return 0
    Dim p As Long = 1
    Do
        p = InStr(p, hay, needle)
        If p = 0 Then Return 0
        Dim ok As Byte = 1
        If p > 1 AndAlso hl_is_word_char(hay[p - 2]) AndAlso hl_is_word_char(needle[0]) Then ok = 0
        Dim e As Long = p + Len(needle) - 1
        If e < Len(hay) AndAlso hl_is_word_char(hay[e]) AndAlso hl_is_word_char(needle[Len(needle) - 1]) Then ok = 0
        If ok Then Return 1
        p += 1
    Loop
End Function

Function highlight_check(c As Long, ByRef text As String) As Byte
    Dim plain As String = utf8_lcase(irc_strip_format(text))
    If conn_valid(c) AndAlso hl_word_in(plain, utf8_lcase(conns(c).nick)) Then Return 1
    Dim i As Long
    For i = 0 To hl_count - 1
        If hl_word_in(plain, hl_words(i)) Then Return 1
    Next i
    Return 0
End Function

' ---------------------------------------------------------------- printing
' Core printing primitive: history + log + activity + unread counters.
Sub ev_line(id As Long, kind As Long, flags As Long, ByRef prefix As String, _
            ByRef nick As String, ByRef text As String, t As Double = 0)
    If buf_valid(id) = 0 Then Exit Sub
    If t <= 0 Then t = time_now()
    buf_add_line(id, kind, flags, prefix, nick, text, t)
    If (flags And LF_HISTORY) = 0 Then log_line(id, prefix, text, t)
    If id <> ui_active_buffer() AndAlso (flags And LF_HISTORY) = 0 Then
        Dim lvl As Long = ACT_EVENT
        Select Case kind
        Case LK_MSG, LK_ACTION, LK_NOTICE, LK_CTCP
            lvl = ACT_MSG
            bufs(id).unread += 1
        End Select
        If (flags And LF_HIGHLIGHT) <> 0 OrElse _
           (bufs(id).kind = BK_QUERY AndAlso (kind = LK_MSG OrElse kind = LK_ACTION)) Then
            lvl = ACT_HIGHLIGHT
            bufs(id).highlights += 1
        End If
        If (flags And LF_NOISE) <> 0 AndAlso cfg.hide_joinpart <> 0 Then lvl = ACT_NONE
        If lvl > bufs(id).activity Then bufs(id).activity = lvl
    End If
End Sub

' Server window of a connection.
Function ev_status_buf(c As Long) As Long
    If conn_valid(c) = 0 Then Return -1
    Return conns(c).status_buf
End Function

' Active buffer when it belongs to c, else c's server window.
Function ev_front_buf(c As Long) As Long
    Dim a As Long = ui_active_buffer()
    If buf_valid(a) AndAlso bufs(a).conn_id = c Then Return a
    Return ev_status_buf(c)
End Function

Sub ev_status(c As Long, ByRef text As String, kind As Long = LK_INFO, t As Double = 0)
    ev_line(ev_status_buf(c), kind, 0, "--", "", text, t)
End Sub

Sub ev_error(c As Long, ByRef text As String)
    ev_line(ev_front_buf(c), LK_ERROR, 0, "!!", "", text)
End Sub

Sub ev_front(c As Long, ByRef text As String, kind As Long = LK_INFO, ByRef prefix As String = "--")
    ev_line(ev_front_buf(c), kind, 0, prefix, "", text)
End Sub

' Client-level message (no connection): active buffer.
Sub ev_client(ByRef text As String, kind As Long = LK_INFO)
    Dim a As Long = ui_active_buffer()
    If buf_valid(a) = 0 Then
        Dim i As Long
        For i = 0 To BUF_MAX - 1
            If bufs(i).alive Then a = i : Exit For
        Next i
    End If
    ev_line(a, kind, 0, IIf(kind = LK_ERROR, "!!", "--"), "", text)
End Sub

' Replay the tail of the log file into a freshly opened buffer.
Sub ev_replay_log(id As Long)
    If cfg.log_replay <= 0 OrElse buf_valid(id) = 0 Then Exit Sub
    Dim lines() As String
    Dim n As Long = log_tail(id, cfg.log_replay, lines())
    If n = 0 Then Exit Sub
    ev_line(id, LK_INFO, LF_HISTORY, "--", "", "Replaying " & n & " lines from the log")
    Dim i As Long
    For i = 0 To n - 1
        Dim t As Double = 0
        Dim txt As String = lines(i)
        If Left(txt, 1) = "[" AndAlso Mid(txt, 21, 1) = "]" Then
            t = time_parse_iso(Mid(txt, 2, 10) & "T" & Mid(txt, 13, 8) & "Z")
            If t > 0 Then t -= time_utc_offset()          ' log times are local
            txt = Mid(txt, 23)
        End If
        ev_line(id, LK_INFO, LF_HISTORY, "", "", txt, t)
    Next i
    ev_line(id, LK_INFO, LF_HISTORY, "--", "", "End of replay")
End Sub

' Notify the front end about a highlight / private message, honouring the
' buffer's notify mode.
Sub ev_notify(id As Long, kind As Long, ByRef title As String, ByRef text As String)
    If buf_valid(id) = 0 Then Exit Sub
    If bufs(id).notify_mode = 3 Then Exit Sub
    ui_on_notify(id, kind, title, irc_strip_format(text))
End Sub
