' =============================================================================
' src/core/extras.bas -- triggers, highlights window, URL log, notify list,
' per-channel settings
'
'   [trigger]  item=<event>|<mask>|<channel mask>|<command>
'              event: text action notice join part kick nick quit invite
'              mask : wildcard on the text (text/action/notice) or on
'                     nick!user@host (other events)
'              command may use $nick $chan $network $me $text $1 .. $9 $2-
'   [friends]  nick=<nick>          notify list (MONITOR / ISON)
'   [chanset]  <network>/<target>=notify=all|highlights|none
' =============================================================================

' ---------------------------------------------------------------- triggers
Type trig_entry
    ev    As String
    mask  As String
    chan  As String
    cmd   As String
    last  As Double
End Type
Dim Shared trigs(Any) As trig_entry
Dim Shared trig_count As Long
Dim Shared trig_depth As Long

Sub trig_load()
    trig_count = 0
    Erase trigs
    Dim i As Long
    For i = 0 To cfg_ini.cnt - 1
        If LCase(cfg_ini.ents(i).sec) = "trigger" Then
            Dim a() As String
            Dim n As Long = str_split(cfg_ini.ents(i).value, "|", a())
            If n >= 4 Then
                If trig_count > UBound(trigs) Then ReDim Preserve trigs(0 To trig_count * 2 + 7)
                With trigs(trig_count)
                    .ev = LCase(Trim(a(0)))
                    .mask = Trim(a(1))
                    .chan = Trim(a(2))
                    .cmd = Trim(a(3))
                    Dim k As Long
                    For k = 4 To n - 1
                        .cmd &= "|" & a(k)            ' commands may contain '|'
                    Next k
                End With
                trig_count += 1
            End If
        End If
    Next i
End Sub

Sub trig_save()
    ini_del_section(cfg_ini, "trigger")
    Dim i As Long
    For i = 0 To trig_count - 1
        ini_add(cfg_ini, "trigger", "item", trigs(i).ev & "|" & trigs(i).mask & "|" & trigs(i).chan & "|" & trigs(i).cmd)
    Next i
End Sub

Private Function trig_expand(ByRef tpl As String, c As Long, ByRef nick As String, ByRef chan As String, ByRef text As String) As String
    Dim r As String
    Dim i As Long = 0
    Dim n As Long = Len(tpl)
    While i < n
        If tpl[i] = Asc("$") AndAlso i + 1 < n Then
            Dim nx As UByte = tpl[i + 1]
            If nx >= Asc("1") AndAlso nx <= Asc("9") Then
                Dim k As Long = nx - Asc("1")
                If i + 2 < n AndAlso tpl[i + 2] = Asc("-") Then
                    r &= str_rest(text, k) : i += 3
                Else
                    r &= str_word(text, k) : i += 2
                End If
                Continue While
            End If
            Dim j As Long = i + 1
            While j < n AndAlso ((tpl[j] >= 97 AndAlso tpl[j] <= 122) OrElse (tpl[j] >= 65 AndAlso tpl[j] <= 90))
                j += 1
            Wend
            Select Case LCase(Mid(tpl, i + 2, j - i - 1))
            Case "nick"    : r &= nick : i = j
            Case "chan"    : r &= chan : i = j
            Case "text"    : r &= text : i = j
            Case "me"      : r &= conn_nick(c) : i = j
            Case "network" : r &= IIf(conn_valid(c), conns(c).name, "") : i = j
            Case Else      : r &= "$" : i += 1
            End Select
        Else
            r &= Chr(tpl[i]) : i += 1
        End If
    Wend
    Return r
End Function

' Run matching triggers. id = buffer of the event (commands run there).
Sub trig_fire(c As Long, id As Long, ByRef ev As String, ByRef src As String, ByRef chan As String, ByRef text As String)
    If trig_count = 0 OrElse trig_depth > 0 OrElse buf_valid(id) = 0 Then Exit Sub
    Dim nick As String = irc_nick_of(src)
    If conn_is_me(c, nick) Then Exit Sub                   ' never react to ourselves
    Dim i As Long
    Dim plain As String = irc_strip_format(text)
    For i = 0 To trig_count - 1
        With trigs(i)
            If .ev <> ev Then Continue For
            If Len(.chan) > 0 AndAlso .chan <> "*" AndAlso wild_match(.chan, chan) = 0 Then Continue For
            Dim subject As String = IIf(ev = "text" OrElse ev = "action" OrElse ev = "notice", plain, src)
            If Len(.mask) > 0 AndAlso wild_match(.mask, subject) = 0 Then Continue For
            If clock_s() - .last < 2 Then Continue For         ' flood / loop guard
            .last = clock_s()
            Dim cmdline As String = trig_expand(.cmd, c, nick, chan, plain)
            trig_depth += 1
            Dim parts() As String
            Dim np As Long = str_split(cmdline, " && ", parts())
            Dim k As Long
            For k = 0 To np - 1
                If Len(Trim(parts(k))) > 0 Then cmd_execute(id, Trim(parts(k)))
            Next k
            trig_depth -= 1
        End With
    Next i
End Sub

' ---------------------------------------------------------------- highlights window
Dim Shared hl_buf As Long = -1

Sub extras_on_highlight(c As Long, id As Long, ByRef nick As String, ByRef text As String, t As Double)
    If cfg.hl_window = 0 Then Exit Sub
    If buf_valid(id) = 0 OrElse id = hl_buf Then Exit Sub
    If buf_valid(hl_buf) = 0 Then hl_buf = buf_new(-1, BK_SPECIAL, "(highlights)", 0)
    Dim where As String = IIf(conn_valid(c), conns(c).name & "/", "") & bufs(id).name
    ev_line(hl_buf, LK_MSG, LF_HIGHLIGHT, "<" & nick & ">", nick, where & ": " & text, t)
End Sub

' ---------------------------------------------------------------- URL log
Const URL_LOG_MAX = 200
Dim Shared url_log(0 To URL_LOG_MAX - 1) As String      ' "time|network/target|nick|url"
Dim Shared url_log_n As Long
Dim Shared url_log_head As Long

Sub url_log_scan(c As Long, ByRef where As String, ByRef nick As String, ByRef text As String)
    Dim plain As String = irc_strip_format(text)
    Dim w() As String
    Dim n As Long = str_words(plain, w())
    Dim i As Long
    For i = 0 To n - 1
        Dim l As String = LCase(w(i))
        If Left(l, 7) = "http://" OrElse Left(l, 8) = "https://" OrElse Left(l, 4) = "www." OrElse Left(l, 6) = "ftp://" Then
            Dim u As String = w(i)
            While Len(u) > 0 AndAlso InStr(".,;:!?)'""", Right(u, 1)) > 0
                u = Left(u, Len(u) - 1)
            Wend
            Dim slot As Long = (url_log_head + url_log_n) Mod URL_LOG_MAX
            If url_log_n = URL_LOG_MAX Then
                slot = url_log_head
                url_log_head = (url_log_head + 1) Mod URL_LOG_MAX
            Else
                url_log_n += 1
            End If
            url_log(slot) = time_format(time_now(), "%H:%M") & "|" & where & "|" & nick & "|" & u
        End If
    Next i
End Sub

' ---------------------------------------------------------------- notify list
Dim Shared friends(Any) As String
Dim Shared friend_count As Long
Dim Shared friends_on(0 To CONN_MAX - 1) As String      ' " nick nick " online per connection
Dim Shared ison_next(0 To CONN_MAX - 1) As Double

Sub friends_load()
    friend_count = 0
    Erase friends
    Dim i As Long
    For i = 0 To cfg_ini.cnt - 1
        If LCase(cfg_ini.ents(i).sec) = "friends" AndAlso Len(cfg_ini.ents(i).value) > 0 Then
            If friend_count > UBound(friends) Then ReDim Preserve friends(0 To friend_count * 2 + 7)
            friends(friend_count) = cfg_ini.ents(i).value
            friend_count += 1
        End If
    Next i
End Sub

Sub friends_save()
    ini_del_section(cfg_ini, "friends")
    Dim i As Long
    For i = 0 To friend_count - 1
        ini_add(cfg_ini, "friends", "nick", friends(i))
    Next i
End Sub

Private Sub friends_mark(c As Long, ByRef nick As String, online As Byte)
    Dim ln As String = " " & irc_lc(nick, conn_casemap(c)) & " "
    Dim was As Byte = IIf(InStr(friends_on(c), ln) > 0, 1, 0)
    If online = was Then Exit Sub
    If online Then
        If Len(friends_on(c)) = 0 Then friends_on(c) = " "
        friends_on(c) &= Mid(ln, 2)
        ev_status(c, nick & " is online")
        ev_notify(ev_status_buf(c), NK_CONNECT, "Friend online", nick & " on " & conns(c).name)
    Else
        friends_on(c) = str_replace(friends_on(c), ln, " ")
        ev_status(c, nick & " went offline")
    End If
    ui_on_conn_state(c)
End Sub

' Start watching after registration (MONITOR when available, else ISON polling).
Sub friends_on_ready(c As Long)
    friends_on(c) = " "
    If friend_count = 0 Then Exit Sub
    If conns(c).monitor_max > 0 Then
        Dim lst As String
        Dim i As Long
        For i = 0 To friend_count - 1
            If Len(lst) + Len(friends(i)) > 400 Then conn_send(c, "MONITOR + " & lst) : lst = ""
            lst &= IIf(Len(lst) > 0, ",", "") & friends(i)
        Next i
        If Len(lst) > 0 Then conn_send(c, "MONITOR + " & lst)
    Else
        ison_next(c) = clock_s() + 5
    End If
End Sub

Sub friends_numeric(c As Long, num As Long, ByRef m As irc_msg)
    Dim a() As String
    Dim n As Long
    Dim i As Long
    Select Case num
    Case 730, 731
        n = str_split(irc_last(m), ",", a())
        For i = 0 To n - 1
            If Len(a(i)) > 0 Then friends_mark(c, irc_nick_of(a(i)), IIf(num = 730, 1, 0))
        Next i
    Case 303
        ' ISON reply: the online subset
        Dim online As String = " " & irc_lc(irc_last(m), conn_casemap(c)) & " "
        For i = 0 To friend_count - 1
            friends_mark(c, friends(i), IIf(InStr(online, " " & irc_lc(friends(i), conn_casemap(c)) & " ") > 0, 1, 0))
        Next i
    End Select
End Sub

Sub friends_poll()
    If friend_count = 0 Then Exit Sub
    Dim c As Long
    For c = 0 To CONN_MAX - 1
        If conn_online(c) AndAlso conns(c).monitor_max = 0 AndAlso ison_next(c) > 0 AndAlso clock_s() >= ison_next(c) Then
            ison_next(c) = clock_s() + 60
            Dim lst As String
            Dim i As Long
            For i = 0 To friend_count - 1
                lst &= " " & friends(i)
            Next i
            conn_send(c, "ISON" & Left(lst, 480))
        End If
    Next c
End Sub

' ---------------------------------------------------------------- per-channel settings
Function chanset_key(id As Long) As String
    If buf_valid(id) = 0 OrElse conn_valid(bufs(id).conn_id) = 0 Then Return ""
    Return LCase(conns(bufs(id).conn_id).name & "/" & bufs(id).name)
End Function

' Load the stored notify mode of a window (called when it opens).
Sub chanset_apply(id As Long)
    Dim k As String = chanset_key(id)
    If Len(k) = 0 Then Exit Sub
    Select Case LCase(ini_get(cfg_ini, "chanset", k))
    Case "notify=all"        : bufs(id).notify_mode = 1
    Case "notify=highlights" : bufs(id).notify_mode = 2
    Case "notify=none"       : bufs(id).notify_mode = 3
    End Select
End Sub

' ---------------------------------------------------------------- commands
Sub extras_cmd_trigger(buf As Long, ByRef args As String)
    Dim op As String = LCase(str_word(args, 0))
    Dim i As Long
    Select Case op
    Case "add"
        Dim spec As String = str_rest(args, 1)
        Dim a() As String
        If str_split(spec, "|", a()) < 4 Then
            ev_client("Usage: /trigger add <event>|<mask>|<channel>|<command>   e.g. /trigger add text|*hello*|#help|/say hi $nick")
            Exit Sub
        End If
        ini_add(cfg_ini, "trigger", "item", spec)
        trig_load() : config_save()
        ev_client("Trigger added: " & spec)
    Case "del", "remove"
        Dim k As Long = str_to_int(str_word(args, 1), 0)
        If k < 1 OrElse k > trig_count Then ev_client("No such trigger (see /trigger)", LK_ERROR) : Exit Sub
        For i = k - 1 To trig_count - 2
            trigs(i) = trigs(i + 1)
        Next i
        trig_count -= 1
        trig_save() : config_save()
        ev_client("Trigger " & k & " removed")
    Case Else
        If trig_count = 0 Then
            ev_client("No triggers. /trigger add <event>|<mask>|<channel>|<command>  (events: text action notice join part kick nick quit invite)")
            Exit Sub
        End If
        For i = 0 To trig_count - 1
            ev_client((i + 1) & ". on " & trigs(i).ev & " [" & trigs(i).mask & "] in " & IIf(Len(trigs(i).chan) > 0, trigs(i).chan, "*") & " -> " & trigs(i).cmd)
        Next i
    End Select
End Sub

Sub extras_cmd_urls(buf As Long, ByRef args As String)
    If url_log_n = 0 Then ev_client("No links seen yet") : Exit Sub
    Dim want As Long = str_to_int(Trim(args), 20)
    If want < 1 Then want = 20
    If want > url_log_n Then want = url_log_n
    ev_client("Last " & want & " links (click to open):")
    Dim i As Long
    For i = url_log_n - want To url_log_n - 1
        Dim a() As String
        Dim n As Long = str_split(url_log((url_log_head + i) Mod URL_LOG_MAX), "|", a())
        If n >= 4 Then ev_client("  " & a(0) & " " & a(1) & " <" & a(2) & "> " & a(3))
    Next i
End Sub

Sub extras_cmd_notify(c As Long, ByRef args As String)
    Dim op As String = LCase(str_word(args, 0))
    Dim nk As String = str_word(args, 1)
    Dim i As Long
    Select Case op
    Case "add"
        If Len(nk) = 0 Then ev_client("Usage: /notify add <nick>") : Exit Sub
        For i = 0 To friend_count - 1
            If LCase(friends(i)) = LCase(nk) Then ev_client(nk & " is already on the notify list") : Exit Sub
        Next i
        If friend_count > UBound(friends) Then ReDim Preserve friends(0 To friend_count * 2 + 7)
        friends(friend_count) = nk
        friend_count += 1
        friends_save() : config_save()
        Dim cc As Long
        For cc = 0 To CONN_MAX - 1
            If conn_online(cc) Then
                If conns(cc).monitor_max > 0 Then conn_send(cc, "MONITOR + " & nk) Else ison_next(cc) = clock_s()
            End If
        Next cc
        ev_client(nk & " added to the notify list")
    Case "del", "remove"
        For i = 0 To friend_count - 1
            If LCase(friends(i)) = LCase(nk) Then
                Dim k As Long
                For k = i To friend_count - 2
                    friends(k) = friends(k + 1)
                Next k
                friend_count -= 1
                friends_save() : config_save()
                Dim cc2 As Long
                For cc2 = 0 To CONN_MAX - 1
                    If conn_online(cc2) AndAlso conns(cc2).monitor_max > 0 Then conn_send(cc2, "MONITOR - " & nk)
                    friends_on(cc2) = str_replace(friends_on(cc2), " " & LCase(nk) & " ", " ")
                Next cc2
                ev_client(nk & " removed from the notify list")
                Exit Sub
            End If
        Next i
        ev_client(nk & " is not on the notify list", LK_ERROR)
    Case Else
        If friend_count = 0 Then ev_client("Notify list is empty. /notify add <nick>") : Exit Sub
        For i = 0 To friend_count - 1
            Dim where As String = ""
            Dim cc3 As Long
            For cc3 = 0 To CONN_MAX - 1
                If conn_online(cc3) AndAlso InStr(friends_on(cc3), " " & irc_lc(friends(i), conn_casemap(cc3)) & " ") > 0 Then
                    where &= IIf(Len(where) > 0, ", ", "") & conns(cc3).name
                End If
            Next cc3
            ev_client("  " & friends(i) & IIf(Len(where) > 0, "  online on " & where, "  offline"))
        Next i
    End Select
End Sub

Sub extras_cmd_chanset(buf As Long, ByRef args As String)
    Dim k As String = chanset_key(buf)
    If Len(k) = 0 OrElse (bufs(buf).kind <> BK_CHANNEL AndAlso bufs(buf).kind <> BK_QUERY) Then
        ev_client("/chanset works in channel and query windows", LK_ERROR) : Exit Sub
    End If
    Dim what As String = LCase(str_word(args, 0))
    Dim v As String = LCase(str_word(args, 1))
    If what <> "notify" Then
        ev_client("Usage: /chanset notify <all|highlights|none>   (now: " & _
                  IIf(bufs(buf).notify_mode = 1, "all", IIf(bufs(buf).notify_mode = 3, "none", "highlights")) & ")")
        Exit Sub
    End If
    Select Case v
    Case "all"        : bufs(buf).notify_mode = 1
    Case "highlights" : bufs(buf).notify_mode = 2
    Case "none"       : bufs(buf).notify_mode = 3
    Case Else         : ev_client("Usage: /chanset notify <all|highlights|none>") : Exit Sub
    End Select
    ini_set(cfg_ini, "chanset", k, "notify=" & v)
    config_save()
    ev_client("Notifications for " & bufs(buf).name & ": " & v)
End Sub
