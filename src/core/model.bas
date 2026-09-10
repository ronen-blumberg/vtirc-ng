' =============================================================================
' src/core/model.bas -- buffers ("windows"), history lines and channel users
'
' Buffers live in a fixed pool; a buffer id is its slot index and stays valid
' until the buffer is closed (the UI drops ids in ui_on_buffer_closed). Each
' buffer keeps a ring of history lines. Channel buffers also keep their user
' list with mode prefixes.
' =============================================================================

Const BUF_MAX = 512

Enum BUF_KIND
    BK_NONE = 0
    BK_STATUS            ' server / network window
    BK_CHANNEL
    BK_QUERY             ' private conversation
    BK_DCC               ' DCC CHAT
    BK_SPECIAL           ' client windows: highlights, URLs, raw log, ...
End Enum

Enum LINE_KIND
    LK_INFO = 0          ' client / generic information
    LK_MSG
    LK_ACTION
    LK_NOTICE
    LK_JOIN
    LK_PART
    LK_QUIT
    LK_KICK
    LK_NICK
    LK_MODE
    LK_TOPIC
    LK_INVITE
    LK_CTCP
    LK_ERROR
    LK_SERVER            ' numerics, MOTD
    LK_WHOIS
    LK_RAW
End Enum

Const LF_SELF      = 1   ' our own message
Const LF_HIGHLIGHT = 2   ' mentions us
Const LF_HISTORY   = 4   ' log replay / server playback
Const LF_NOISE     = 8   ' join/part/quit/nick -- may be hidden by filters

Enum ACTIVITY_LEVEL
    ACT_NONE = 0
    ACT_EVENT            ' joins, parts, modes ...
    ACT_MSG              ' ordinary messages
    ACT_HIGHLIGHT        ' mention or private message
End Enum

Type irc_line
    t      As Double      ' Unix time (UTC)
    kind   As UByte
    flags  As UByte
    nick   As String      ' originating nick (colouring, clicks)
    prefix As String      ' left column: "<nick>", "*", "-->", "--", "-nick-"
    text   As String      ' UTF-8 with mIRC formatting codes
    serial As LongInt     ' increasing per buffer (identifies lines across wrap)
End Type

Type irc_user
    nick       As String
    lnick      As String  ' case-folded nick (lookup key)
    pfx        As String  ' status prefixes, highest rank first ("@+")
    user       As String
    host       As String
    account    As String
    away       As Byte
    last_spoke As Double
End Type

Type irc_buffer
    alive       As Byte
    kind        As Byte
    conn_id     As Long           ' -1 for client-wide buffers
    name        As String         ' "#chan", "nick", network name for status
    lname       As String         ' case-folded name
    cm          As Byte           ' case mapping used for lname / lnick
    ' history ring
    hist(Any)   As irc_line
    hist_max    As Long
    hist_head   As Long           ' slot of the oldest line
    hist_count  As Long
    next_serial As LongInt
    ' channel state
    users(Any)  As irc_user
    user_count  As Long
    sorted(Any) As Long           ' display order (indices into users)
    sort_ok     As Byte
    names_pending As Byte         ' 353 replies replace the list on the next reply
    topic       As String
    topic_by    As String
    topic_time  As Double
    chmodes     As String         ' channel mode letters without parameters ("ntk")
    chkey       As String         ' channel key (+k, used for rejoin)
    chlimit     As String         ' user limit (+l)
    created     As Double
    joined      As Byte           ' we are currently in the channel
    ' per-buffer UI / notification state
    activity    As Byte
    unread      As Long
    highlights  As Long
    marker      As LongInt        ' serial of the last line seen
    scroll      As Long           ' display rows scrolled up from the bottom
    draft       As String         ' unsent input line
    notify_mode As Byte           ' 0 default, 1 all messages, 2 highlights only, 3 none
    last_join_t As Double
End Type

Dim Shared bufs(0 To BUF_MAX - 1) As irc_buffer
Dim Shared buf_default_hist As Long = 2000

Declare Function conn_casemap(conn_id As Long) As Long

' -----------------------------------------------------------------------------
' Buffers
' -----------------------------------------------------------------------------
Function buf_valid(id As Long) As Byte
    Return IIf(id >= 0 AndAlso id < BUF_MAX AndAlso bufs(id).alive <> 0, 1, 0)
End Function

Function buf_find(conn_id As Long, ByRef nm As String) As Long
    Dim cm As Long = conn_casemap(conn_id)
    Dim ln As String = irc_lc(nm, cm)
    Dim i  As Long
    For i = 0 To BUF_MAX - 1
        If bufs(i).alive AndAlso bufs(i).conn_id = conn_id AndAlso bufs(i).kind <> BK_STATUS Then
            If bufs(i).lname = ln Then Return i
        End If
    Next i
    Return -1
End Function

Function buf_find_kind(conn_id As Long, kind As Long, ByRef nm As String) As Long
    Dim cm As Long = conn_casemap(conn_id)
    Dim ln As String = irc_lc(nm, cm)
    Dim i  As Long
    For i = 0 To BUF_MAX - 1
        If bufs(i).alive AndAlso bufs(i).conn_id = conn_id AndAlso bufs(i).kind = kind Then
            If bufs(i).lname = ln Then Return i
        End If
    Next i
    Return -1
End Function

Function buf_new(conn_id As Long, kind As Long, ByRef nm As String, focus As Byte = 0) As Long
    Dim i As Long
    For i = 0 To BUF_MAX - 1
        If bufs(i).alive = 0 Then Exit For
    Next i
    If i >= BUF_MAX Then Return -1
    With bufs(i)
        .alive = 1
        .kind = kind
        .conn_id = conn_id
        .name = nm
        .cm = conn_casemap(conn_id)
        .lname = irc_lc(nm, .cm)
        .hist_max = IIf(buf_default_hist < 50, 50, buf_default_hist)
        ReDim .hist(0 To .hist_max - 1)
        .hist_head = 0
        .hist_count = 0
        .next_serial = 1
        Erase .users
        Erase .sorted
        .user_count = 0
        .sort_ok = 0
        .names_pending = 0
        .topic = "" : .topic_by = "" : .topic_time = 0
        .chmodes = "" : .chkey = "" : .chlimit = "" : .created = 0
        .joined = 0
        .activity = 0 : .unread = 0 : .highlights = 0
        .marker = 0 : .scroll = 0 : .draft = ""
        .notify_mode = 0
        .last_join_t = 0
    End With
    ui_on_buffer_new(i, focus)
    Return i
End Function

Sub buf_close(id As Long)
    If buf_valid(id) = 0 Then Exit Sub
    ui_on_buffer_closed(id)
    With bufs(id)
        .alive = 0
        Erase .hist
        Erase .users
        Erase .sorted
        .user_count = 0
        .hist_count = 0
        .name = ""
        .lname = ""
        .topic = ""
        .draft = ""
    End With
End Sub

Sub buf_rename(id As Long, ByRef nm As String)
    If buf_valid(id) = 0 Then Exit Sub
    bufs(id).name  = nm
    bufs(id).lname = irc_lc(nm, bufs(id).cm)
End Sub

' Re-fold names after the server announced a different CASEMAPPING.
Sub buf_set_casemap(conn_id As Long, cm As Long)
    Dim i As Long
    Dim u As Long
    For i = 0 To BUF_MAX - 1
        If bufs(i).alive AndAlso bufs(i).conn_id = conn_id Then
            bufs(i).cm = cm
            bufs(i).lname = irc_lc(bufs(i).name, cm)
            For u = 0 To bufs(i).user_count - 1
                bufs(i).users(u).lnick = irc_lc(bufs(i).users(u).nick, cm)
            Next u
        End If
    Next i
End Sub

' -----------------------------------------------------------------------------
' History
' -----------------------------------------------------------------------------
Function buf_add_line(id As Long, kind As Long, flags As Long, ByRef prefix As String, _
                      ByRef nick As String, ByRef text As String, t As Double = 0) As LongInt
    If buf_valid(id) = 0 Then Return 0
    Dim slot As Long
    With bufs(id)
        If .hist_count < .hist_max Then
            slot = (.hist_head + .hist_count) Mod .hist_max
            .hist_count += 1
        Else
            slot = .hist_head
            .hist_head = (.hist_head + 1) Mod .hist_max
        End If
        .hist(slot).t      = IIf(t > 0, t, time_now())
        .hist(slot).kind   = kind
        .hist(slot).flags  = flags
        .hist(slot).nick   = nick
        .hist(slot).prefix = prefix
        .hist(slot).text   = text
        .hist(slot).serial = .next_serial
        .next_serial += 1
        Function = .hist(slot).serial
    End With
    ui_on_buffer_line(id)
End Function

' i-th line counted from the oldest (0 .. hist_count-1).
Function buf_line(id As Long, i As Long) As irc_line Ptr
    If buf_valid(id) = 0 OrElse i < 0 OrElse i >= bufs(id).hist_count Then Return 0
    Return @bufs(id).hist((bufs(id).hist_head + i) Mod bufs(id).hist_max)
End Function

Sub buf_clear(id As Long)
    If buf_valid(id) = 0 Then Exit Sub
    Dim i As Long
    For i = 0 To bufs(id).hist_max - 1
        bufs(id).hist(i).text = "" : bufs(id).hist(i).prefix = "" : bufs(id).hist(i).nick = ""
    Next i
    bufs(id).hist_head = 0
    bufs(id).hist_count = 0
    bufs(id).scroll = 0
    ui_on_buffer_line(id)
End Sub

' -----------------------------------------------------------------------------
' Channel users
' -----------------------------------------------------------------------------
Function user_find(id As Long, ByRef nick As String) As Long
    If buf_valid(id) = 0 Then Return -1
    Dim ln As String = irc_lc(nick, bufs(id).cm)
    Dim i As Long
    For i = 0 To bufs(id).user_count - 1
        If bufs(id).users(i).lnick = ln Then Return i
    Next i
    Return -1
End Function

' Order the characters of pfx by their rank in prefix_chars ("~&@%+").
Function pfx_normalize(ByRef pfx As String, ByRef prefix_chars As String) As String
    Dim r As String
    Dim i As Long
    For i = 0 To Len(prefix_chars) - 1
        If InStr(pfx, Chr(prefix_chars[i])) > 0 Then r &= Chr(prefix_chars[i])
    Next i
    Return r
End Function

' Split "@+nick" into prefixes and nick using the server's prefix characters.
Sub pfx_split(ByRef s As String, ByRef prefix_chars As String, ByRef pfx As String, ByRef nick As String)
    Dim i As Long = 0
    While i < Len(s) AndAlso InStr(prefix_chars, Chr(s[i])) > 0
        i += 1
    Wend
    pfx  = Left(s, i)
    nick = Mid(s, i + 1)
End Sub

Function user_add(id As Long, ByRef nick As String, ByRef pfx As String = "", _
                  ByRef usr As String = "", ByRef host As String = "") As Long
    If buf_valid(id) = 0 OrElse Len(nick) = 0 Then Return -1
    Dim i As Long = user_find(id, nick)
    With bufs(id)
        If i < 0 Then
            If .user_count > UBound(.users) Then ReDim Preserve .users(0 To .user_count * 2 + 31)
            i = .user_count
            .user_count += 1
            .users(i).nick = nick
            .users(i).lnick = irc_lc(nick, .cm)
            .users(i).pfx = pfx
            .users(i).user = usr
            .users(i).host = host
            .users(i).account = ""
            .users(i).away = 0
            .users(i).last_spoke = 0
        Else
            .users(i).nick = nick
            If Len(pfx) > 0 Then .users(i).pfx = pfx
            If Len(usr) > 0 Then .users(i).user = usr
            If Len(host) > 0 Then .users(i).host = host
        End If
        .sort_ok = 0
    End With
    Return i
End Function

Function user_remove(id As Long, ByRef nick As String) As Byte
    Dim i As Long = user_find(id, nick)
    If i < 0 Then Return 0
    With bufs(id)
        Dim k As Long
        For k = i To .user_count - 2
            .users(k) = .users(k + 1)
        Next k
        .user_count -= 1
        .users(.user_count).nick = "" : .users(.user_count).lnick = "" : .users(.user_count).pfx = ""
        .users(.user_count).user = "" : .users(.user_count).host = "" : .users(.user_count).account = ""
        .sort_ok = 0
    End With
    Return 1
End Function

Sub user_clear(id As Long)
    If buf_valid(id) = 0 Then Exit Sub
    Erase bufs(id).users
    Erase bufs(id).sorted
    bufs(id).user_count = 0
    bufs(id).sort_ok = 0
End Sub

Function user_rename(id As Long, ByRef old_nick As String, ByRef new_nick As String) As Byte
    Dim i As Long = user_find(id, old_nick)
    If i < 0 Then Return 0
    bufs(id).users(i).nick  = new_nick
    bufs(id).users(i).lnick = irc_lc(new_nick, bufs(id).cm)
    bufs(id).sort_ok = 0
    Return 1
End Function

' Add or remove one status prefix character (e.g. '@' for +o).
Sub user_set_prefix(id As Long, ByRef nick As String, pch As String, add As Byte, ByRef prefix_chars As String)
    Dim i As Long = user_find(id, nick)
    If i < 0 Then Exit Sub
    Dim p As String = bufs(id).users(i).pfx
    If add Then
        If InStr(p, pch) = 0 Then p &= pch
    Else
        p = str_replace(p, pch, "")
    End If
    bufs(id).users(i).pfx = pfx_normalize(p, prefix_chars)
    bufs(id).sort_ok = 0
End Sub

' Rank of a user's highest prefix (0 = highest; Len(prefix_chars) = none).
Private Function user_rank(ByRef u As irc_user, ByRef prefix_chars As String) As Long
    If Len(u.pfx) = 0 Then Return Len(prefix_chars)
    Dim r As Long = InStr(prefix_chars, Left(u.pfx, 1))
    If r = 0 Then Return Len(prefix_chars)
    Return r - 1
End Function

' Rebuild bufs(id).sorted: by rank, then case-folded nick.
Sub user_sort(id As Long, ByRef prefix_chars As String)
    If buf_valid(id) = 0 Then Exit Sub
    With bufs(id)
        If .sort_ok Then Exit Sub
        Dim n As Long = .user_count
        If n = 0 Then Erase .sorted : .sort_ok = 1 : Exit Sub
        ReDim .sorted(0 To n - 1)
        Dim keys() As String
        ReDim keys(0 To n - 1)
        Dim i As Long
        For i = 0 To n - 1
            .sorted(i) = i
            keys(i) = Chr(65 + user_rank(.users(i), prefix_chars)) & .users(i).lnick
        Next i
        ' shell sort on the key strings
        Dim gap As Long = n \ 2
        While gap > 0
            For i = gap To n - 1
                Dim tk As String = keys(i)
                Dim ti As Long = .sorted(i)
                Dim j As Long = i
                While j >= gap AndAlso keys(j - gap) > tk
                    keys(j) = keys(j - gap)
                    .sorted(j) = .sorted(j - gap)
                    j -= gap
                Wend
                keys(j) = tk
                .sorted(j) = ti
            Next i
            gap \= 2
        Wend
        .sort_ok = 1
    End With
End Sub
