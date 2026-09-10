' =============================================================================
' src/util/strutil.bas -- string helpers, wildcards, base64, time
' =============================================================================
#Include Once "crt/time.bi"

' -----------------------------------------------------------------------------
' Tokens
' -----------------------------------------------------------------------------

' Split s on sep (single or multi-character). Empty fields are kept.
' Returns the element count; arr is ReDim'ed to 0..count-1.
Function str_split(ByRef s As String, ByRef sep As String, arr() As String) As Long
    Dim cnt As Long = 0
    Dim p   As Long = 1
    Dim q   As Long
    Dim sl  As Long = Len(sep)
    ReDim arr(0 To 15)
    If sl = 0 Then arr(0) = s : ReDim Preserve arr(0 To 0) : Return 1
    Do
        q = InStr(p, s, sep)
        If cnt > UBound(arr) Then ReDim Preserve arr(0 To cnt * 2 + 1)
        If q = 0 Then
            arr(cnt) = Mid(s, p)
            cnt += 1
            Exit Do
        End If
        arr(cnt) = Mid(s, p, q - p)
        cnt += 1
        p = q + sl
    Loop
    ReDim Preserve arr(0 To cnt - 1)
    Return cnt
End Function

' Split on runs of spaces (no empty fields).
Function str_words(ByRef s As String, arr() As String) As Long
    Dim cnt As Long = 0
    Dim i   As Long = 0
    Dim n   As Long = Len(s)
    ReDim arr(0 To 15)
    While i < n
        While i < n AndAlso s[i] = 32
            i += 1
        Wend
        If i >= n Then Exit While
        Dim st As Long = i
        While i < n AndAlso s[i] <> 32
            i += 1
        Wend
        If cnt > UBound(arr) Then ReDim Preserve arr(0 To cnt * 2 + 1)
        arr(cnt) = Mid(s, st + 1, i - st)
        cnt += 1
    Wend
    If cnt = 0 Then
        ReDim arr(0 To 0)
    Else
        ReDim Preserve arr(0 To cnt - 1)
    End If
    Return cnt
End Function

' n-th space-separated word (0-based), "" if missing.
Function str_word(ByRef s As String, n As Long) As String
    Dim i  As Long = 0
    Dim ln As Long = Len(s)
    Dim w  As Long = 0
    While i < ln
        While i < ln AndAlso s[i] = 32
            i += 1
        Wend
        If i >= ln Then Exit While
        Dim st As Long = i
        While i < ln AndAlso s[i] <> 32
            i += 1
        Wend
        If w = n Then Return Mid(s, st + 1, i - st)
        w += 1
    Wend
    Return ""
End Function

' Everything from the n-th word (0-based) to the end, leading spaces removed.
Function str_rest(ByRef s As String, n As Long) As String
    Dim i  As Long = 0
    Dim ln As Long = Len(s)
    Dim w  As Long = 0
    While i < ln
        While i < ln AndAlso s[i] = 32
            i += 1
        Wend
        If i >= ln Then Exit While
        If w = n Then Return Mid(s, i + 1)
        While i < ln AndAlso s[i] <> 32
            i += 1
        Wend
        w += 1
    Wend
    Return ""
End Function

Function str_replace(ByRef s As String, ByRef a As String, ByRef b As String) As String
    If Len(a) = 0 Then Return s
    Dim r As String
    Dim p As Long = 1
    Dim q As Long
    Do
        q = InStr(p, s, a)
        If q = 0 Then r &= Mid(s, p) : Exit Do
        r &= Mid(s, p, q - p) & b
        p = q + Len(a)
    Loop
    Return r
End Function

Function str_starts(ByRef s As String, ByRef pfx As String) As Byte
    Return IIf(Left(s, Len(pfx)) = pfx, 1, 0)
End Function

Function str_starts_ci(ByRef s As String, ByRef pfx As String) As Byte
    Return IIf(LCase(Left(s, Len(pfx))) = LCase(pfx), 1, 0)
End Function

Function str_ends(ByRef s As String, ByRef sfx As String) As Byte
    Return IIf(Right(s, Len(sfx)) = sfx, 1, 0)
End Function

' Parse a decimal integer; returns def when s is not a number.
Function str_to_int(ByRef s As String, def As LongInt = 0) As LongInt
    Dim t As String = Trim(s)
    If Len(t) = 0 Then Return def
    Dim i As Long = 0
    If t[0] = Asc("-") OrElse t[0] = Asc("+") Then i = 1
    If i >= Len(t) Then Return def
    While i < Len(t)
        If t[i] < Asc("0") OrElse t[i] > Asc("9") Then Return def
        i += 1
    Wend
    Return ValLng(t)
End Function

Function int_str(v As LongInt) As String
    Return LTrim(Str(v))
End Function

Function bool_str(v As Long) As String
    Return IIf(v <> 0, "1", "0")
End Function

Function str_to_bool(ByRef s As String, def As Byte = 0) As Byte
    Select Case LCase(Trim(s))
    Case "1", "yes", "true", "on"  : Return 1
    Case "0", "no", "false", "off" : Return 0
    End Select
    Return def
End Function

' -----------------------------------------------------------------------------
' Wildcard match: '*' any run, '?' one byte. Case-insensitive (ASCII) when ci.
' Iterative with single backtrack point -- linear for typical patterns.
' -----------------------------------------------------------------------------
Function wild_match(ByRef pat As String, ByRef s As String, ci As Byte = 1) As Byte
    Dim p As String = IIf(ci, LCase(pat), pat)
    Dim t As String = IIf(ci, LCase(s), s)
    Dim pi As Long = 0
    Dim ti As Long = 0
    Dim star_p As Long = -1
    Dim star_t As Long = 0
    Dim pl As Long = Len(p)
    Dim tl As Long = Len(t)
    While ti < tl
        If pi < pl AndAlso (p[pi] = Asc("?") OrElse p[pi] = t[ti]) Then
            pi += 1 : ti += 1
        ElseIf pi < pl AndAlso p[pi] = Asc("*") Then
            star_p = pi : star_t = ti : pi += 1
        ElseIf star_p >= 0 Then
            pi = star_p + 1 : star_t += 1 : ti = star_t
        Else
            Return 0
        End If
    Wend
    While pi < pl AndAlso p[pi] = Asc("*")
        pi += 1
    Wend
    Return IIf(pi = pl, 1, 0)
End Function

' -----------------------------------------------------------------------------
' Base64 (SASL)
' -----------------------------------------------------------------------------
Function base64_encode(ByRef s As String) As String
    Dim tbl As String = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    Dim r As String
    Dim i As Long = 0
    Dim n As Long = Len(s)
    Dim v As ULong
    While i + 2 < n
        v = (CULng(s[i]) Shl 16) Or (CULng(s[i + 1]) Shl 8) Or s[i + 2]
        r &= Chr(tbl[(v Shr 18) And 63], tbl[(v Shr 12) And 63], tbl[(v Shr 6) And 63], tbl[v And 63])
        i += 3
    Wend
    If n - i = 1 Then
        v = CULng(s[i]) Shl 16
        r &= Chr(tbl[(v Shr 18) And 63], tbl[(v Shr 12) And 63]) & "=="
    ElseIf n - i = 2 Then
        v = (CULng(s[i]) Shl 16) Or (CULng(s[i + 1]) Shl 8)
        r &= Chr(tbl[(v Shr 18) And 63], tbl[(v Shr 12) And 63], tbl[(v Shr 6) And 63]) & "="
    End If
    Return r
End Function

Function base64_decode(ByRef s As String) As String
    Dim r    As String
    Dim acc  As ULong = 0
    Dim bits As Long  = 0
    Dim i    As Long
    Dim c    As Long
    Dim v    As Long
    For i = 0 To Len(s) - 1
        c = s[i]
        Select Case c
        Case Asc("A") To Asc("Z") : v = c - Asc("A")
        Case Asc("a") To Asc("z") : v = c - Asc("a") + 26
        Case Asc("0") To Asc("9") : v = c - Asc("0") + 52
        Case Asc("+")             : v = 62
        Case Asc("/")             : v = 63
        Case Else                 : Continue For
        End Select
        acc = ((acc Shl 6) Or v) And &hFFFFFF
        bits += 6
        If bits >= 8 Then
            bits -= 8
            r &= Chr((acc Shr bits) And &hFF)
        End If
    Next i
    Return r
End Function

' -----------------------------------------------------------------------------
' Time. Internally times are Unix seconds (Double, UTC).
' -----------------------------------------------------------------------------
Function time_now() As Double
    ' FreeBASIC's Now is local time as a serial date; convert via time()
    Dim t As time_t = time_(0)
    Return CDbl(t)
End Function

' Seconds east of UTC for the current local time (DST aware).
Function time_utc_offset() As Long
    Dim t  As time_t = time_(0)
    Dim lt As tm = *localtime(@t)
    Dim gt As tm = *gmtime(@t)
    gt.tm_isdst = lt.tm_isdst
    Return CLng(difftime(mktime(@lt), mktime(@gt)))
End Function

' Days since 1970-01-01 of a civil date (proleptic Gregorian).
Private Function days_from_civil(y As Long, m As Long, d As Long) As Long
    Dim yy As Long = IIf(m <= 2, y - 1, y)
    Dim era As Long = IIf(yy >= 0, yy, yy - 399) \ 400
    Dim yoe As Long = yy - era * 400
    Dim mm As Long = IIf(m > 2, m - 3, m + 9)
    Dim doy As Long = (153 * mm + 2) \ 5 + d - 1
    Dim doe As Long = yoe * 365 + yoe \ 4 - yoe \ 100 + doy
    Return era * 146097 + doe - 719468
End Function

' Parse IRCv3 server-time "YYYY-MM-DDThh:mm:ss[.sss]Z" -> Unix seconds; 0 on error.
Function time_parse_iso(ByRef s As String) As Double
    If Len(s) < 19 Then Return 0
    If s[4] <> Asc("-") OrElse s[7] <> Asc("-") OrElse s[10] <> Asc("T") Then Return 0
    Dim y  As Long = ValInt(Mid(s, 1, 4))
    Dim mo As Long = ValInt(Mid(s, 6, 2))
    Dim d  As Long = ValInt(Mid(s, 9, 2))
    Dim h  As Long = ValInt(Mid(s, 12, 2))
    Dim mi As Long = ValInt(Mid(s, 15, 2))
    Dim se As Double = Val(Mid(s, 18, IIf(InStr(s, "Z") > 18, InStr(s, "Z") - 18, 2)))
    If y < 1970 OrElse mo < 1 OrElse mo > 12 OrElse d < 1 OrElse d > 31 Then Return 0
    Return CDbl(days_from_civil(y, mo, d)) * 86400 + h * 3600 + mi * 60 + se
End Function

' Break Unix seconds into local calendar fields.
Sub time_local_fields(t As Double, ByRef y As Long, ByRef mo As Long, ByRef d As Long, _
                      ByRef h As Long, ByRef mi As Long, ByRef se As Long)
    Dim tt As time_t = CLngInt(Int(t))
    Dim p  As tm Ptr = localtime(@tt)
    If p = 0 Then y = 1970 : mo = 1 : d = 1 : h = 0 : mi = 0 : se = 0 : Exit Sub
    y = p->tm_year + 1900 : mo = p->tm_mon + 1 : d = p->tm_mday
    h = p->tm_hour : mi = p->tm_min : se = p->tm_sec
End Sub

Private Function z2(v As Long) As String
    Return Right("0" & LTrim(Str(v)), 2)
End Function

' Format a Unix time with a tiny strftime subset: %H %M %S %d %m %Y %y %%.
Function time_format(t As Double, ByRef fmt As String) As String
    Dim y As Long, mo As Long, d As Long, h As Long, mi As Long, se As Long
    time_local_fields(t, y, mo, d, h, mi, se)
    Dim r As String
    Dim i As Long = 0
    While i < Len(fmt)
        If fmt[i] = Asc("%") AndAlso i + 1 < Len(fmt) Then
            Select Case fmt[i + 1]
            Case Asc("H") : r &= z2(h)
            Case Asc("M") : r &= z2(mi)
            Case Asc("S") : r &= z2(se)
            Case Asc("d") : r &= z2(d)
            Case Asc("m") : r &= z2(mo)
            Case Asc("Y") : r &= LTrim(Str(y))
            Case Asc("y") : r &= z2(y Mod 100)
            Case Asc("%") : r &= "%"
            Case Else     : r &= Chr(fmt[i], fmt[i + 1])
            End Select
            i += 2
        Else
            r &= Chr(fmt[i])
            i += 1
        End If
    Wend
    Return r
End Function

' "3d 4h", "4m12s", "12s"
Function time_duration(secs As Double) As String
    Dim s As LongInt = CLngInt(Int(secs))
    If s < 0 Then s = 0
    Dim dd As LongInt = s \ 86400
    Dim hh As LongInt = (s Mod 86400) \ 3600
    Dim mm As LongInt = (s Mod 3600) \ 60
    Dim ss As LongInt = s Mod 60
    If dd > 0 Then Return int_str(dd) & "d " & int_str(hh) & "h"
    If hh > 0 Then Return int_str(hh) & "h " & int_str(mm) & "m"
    If mm > 0 Then Return int_str(mm) & "m" & int_str(ss) & "s"
    Return int_str(ss) & "s"
End Function

' Monotonic-ish seconds for timers (Timer wraps at midnight on some targets,
' so time_now() is used for anything persisted; this is for short intervals).
Function clock_s() As Double
    Return Timer
End Function
