' =============================================================================
' src/core/ircmsg.bas -- IRC message parsing (RFC 1459/2812 + IRCv3 tags)
'
'   [@tags] [:source] COMMAND [params...] [:trailing]
' =============================================================================

Const IRC_MAX_PARAMS = 20

Type irc_msg
    tags     As String                  ' raw tag string without '@'
    src      As String                  ' full source without ':'
    nick     As String                  ' source nick (or server name)
    user     As String
    host     As String
    cmd      As String                  ' upper case command / numeric
    params(IRC_MAX_PARAMS - 1) As String
    pcount   As Long
    t        As Double                  ' message time (server-time tag or now)
End Type

Sub irc_msg_clear(ByRef m As irc_msg)
    m.tags = "" : m.src = "" : m.nick = "" : m.user = "" : m.host = "" : m.cmd = ""
    Dim i As Long
    For i = 0 To m.pcount - 1
        m.params(i) = ""
    Next i
    m.pcount = 0
    m.t = 0
End Sub

' Split "nick!user@host" (any part may be missing).
Sub irc_split_source(ByRef src As String, ByRef nick As String, ByRef user As String, ByRef host As String)
    Dim bang As Long = InStr(src, "!")
    Dim at   As Long = InStr(src, "@")
    nick = "" : user = "" : host = ""
    If bang > 0 Then
        nick = Left(src, bang - 1)
        If at > bang Then
            user = Mid(src, bang + 1, at - bang - 1)
            host = Mid(src, at + 1)
        Else
            user = Mid(src, bang + 1)
        End If
    ElseIf at > 0 Then
        nick = Left(src, at - 1)
        host = Mid(src, at + 1)
    Else
        nick = src
    End If
End Sub

Function irc_nick_of(ByRef src As String) As String
    Dim n As String, u As String, h As String
    irc_split_source(src, n, u, h)
    Return n
End Function

Sub irc_parse(ByRef ln As String, ByRef m As irc_msg)
    irc_msg_clear(m)
    Dim n As Long = Len(ln)
    Dim p As Long = 0
    Dim st As Long
    If n = 0 Then Exit Sub
    If ln[0] = Asc("@") Then
        st = 1
        While p < n AndAlso ln[p] <> 32
            p += 1
        Wend
        m.tags = Mid(ln, st + 1, p - st)
    End If
    While p < n AndAlso ln[p] = 32
        p += 1
    Wend
    If p < n AndAlso ln[p] = Asc(":") Then
        st = p + 1
        While p < n AndAlso ln[p] <> 32
            p += 1
        Wend
        m.src = Mid(ln, st + 1, p - st)
        irc_split_source(m.src, m.nick, m.user, m.host)
    End If
    While p < n AndAlso ln[p] = 32
        p += 1
    Wend
    st = p
    While p < n AndAlso ln[p] <> 32
        p += 1
    Wend
    m.cmd = UCase(Mid(ln, st + 1, p - st))
    Do
        While p < n AndAlso ln[p] = 32
            p += 1
        Wend
        If p >= n OrElse m.pcount >= IRC_MAX_PARAMS Then Exit Do
        If ln[p] = Asc(":") Then
            m.params(m.pcount) = Mid(ln, p + 2)
            m.pcount += 1
            Exit Do
        End If
        st = p
        While p < n AndAlso ln[p] <> 32
            p += 1
        Wend
        m.params(m.pcount) = Mid(ln, st + 1, p - st)
        m.pcount += 1
    Loop
End Sub

' i-th parameter or "" (safe for missing parameters).
Function irc_param(ByRef m As irc_msg, i As Long) As String
    If i < 0 OrElse i >= m.pcount Then Return ""
    Return m.params(i)
End Function

' Last parameter (usually the text) or "".
Function irc_last(ByRef m As irc_msg) As String
    If m.pcount = 0 Then Return ""
    Return m.params(m.pcount - 1)
End Function

' Parameters from i to the end joined by spaces.
Function irc_params_from(ByRef m As irc_msg, i As Long) As String
    Dim r As String
    Dim k As Long
    For k = i To m.pcount - 1
        If k > i Then r &= " "
        r &= m.params(k)
    Next k
    Return r
End Function

' Unescape an IRCv3 tag value (\: ; \s space \\ \r \n).
Function irc_tag_unescape(ByRef v As String) As String
    If InStr(v, "\") = 0 Then Return v
    Dim r As String
    Dim i As Long = 0
    While i < Len(v)
        If v[i] = Asc("\") AndAlso i + 1 < Len(v) Then
            Select Case v[i + 1]
            Case Asc(":") : r &= ";"
            Case Asc("s") : r &= " "
            Case Asc("\") : r &= "\"
            Case Asc("r") : r &= Chr(13)
            Case Asc("n") : r &= Chr(10)
            Case Else     : r &= Chr(v[i + 1])
            End Select
            i += 2
        ElseIf v[i] = Asc("\") Then
            i += 1
        Else
            r &= Chr(v[i])
            i += 1
        End If
    Wend
    Return r
End Function

' Value of tag `key` ("" if absent; present-without-value also gives "").
Function irc_tag(ByRef m As irc_msg, ByRef key As String) As String
    If Len(m.tags) = 0 Then Return ""
    Dim a() As String
    Dim n As Long = str_split(m.tags, ";", a())
    Dim i As Long
    For i = 0 To n - 1
        Dim eq As Long = InStr(a(i), "=")
        Dim k As String = IIf(eq > 0, Left(a(i), eq - 1), a(i))
        If k = key Then Return IIf(eq > 0, irc_tag_unescape(Mid(a(i), eq + 1)), "")
    Next i
    Return ""
End Function

Function irc_has_tag(ByRef m As irc_msg, ByRef key As String) As Byte
    If Len(m.tags) = 0 Then Return 0
    Dim a() As String
    Dim n As Long = str_split(m.tags, ";", a())
    Dim i As Long
    For i = 0 To n - 1
        Dim eq As Long = InStr(a(i), "=")
        Dim k As String = IIf(eq > 0, Left(a(i), eq - 1), a(i))
        If k = key Then Return 1
    Next i
    Return 0
End Function

' -----------------------------------------------------------------------------
' Case mapping (RPL_ISUPPORT CASEMAPPING)
' -----------------------------------------------------------------------------
Enum CASEMAP_KIND
    CM_ASCII = 0
    CM_RFC1459          ' also maps []\~ to {}|^
    CM_STRICT_RFC1459   ' maps []\ to {}| only
End Enum

Function irc_lc(ByRef s As String, cm As Long = CM_RFC1459) As String
    Dim r As String = s
    Dim i As Long
    For i = 0 To Len(r) - 1
        Select Case r[i]
        Case 65 To 90 : r[i] += 32
        Case 91 : If cm <> CM_ASCII Then r[i] = 123     ' [ -> {
        Case 93 : If cm <> CM_ASCII Then r[i] = 125     ' ] -> }
        Case 92 : If cm <> CM_ASCII Then r[i] = 124     ' \ -> |
        Case 126 : If cm = CM_RFC1459 Then r[i] = 94    ' ~ -> ^
        End Select
    Next i
    Return r
End Function

Function irc_eq(ByRef a As String, ByRef b As String, cm As Long = CM_RFC1459) As Byte
    If Len(a) <> Len(b) Then Return 0
    Return IIf(irc_lc(a, cm) = irc_lc(b, cm), 1, 0)
End Function

' Strip mIRC formatting: ^B ^C[fg[,bg]] ^D(hex) ^O ^Q ^R ^V ^] ^^ ^_
Function irc_strip_format(ByRef s As String) As String
    Dim r As String
    Dim i As Long = 0
    Dim n As Long = Len(s)
    While i < n
        Select Case s[i]
        Case 2, 15, 17, 22, 29, 30, 31
            i += 1
        Case 3
            i += 1
            Dim d As Long = 0
            While d < 2 AndAlso i < n AndAlso s[i] >= 48 AndAlso s[i] <= 57
                i += 1 : d += 1
            Wend
            If d > 0 AndAlso i + 1 < n AndAlso s[i] = Asc(",") AndAlso s[i + 1] >= 48 AndAlso s[i + 1] <= 57 Then
                i += 1 : d = 0
                While d < 2 AndAlso i < n AndAlso s[i] >= 48 AndAlso s[i] <= 57
                    i += 1 : d += 1
                Wend
            End If
        Case 4
            i += 1
            Dim h As Long = 0
            While h < 6 AndAlso i < n AndAlso ((s[i] >= 48 AndAlso s[i] <= 57) OrElse _
                  (s[i] >= 65 AndAlso s[i] <= 70) OrElse (s[i] >= 97 AndAlso s[i] <= 102))
                i += 1 : h += 1
            Wend
            If h = 6 AndAlso i + 6 < n AndAlso s[i] = Asc(",") Then i += 7
        Case Else
            r &= Chr(s[i])
            i += 1
        End Select
    Wend
    Return r
End Function
