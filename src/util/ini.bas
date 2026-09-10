' =============================================================================
' src/util/ini.bas -- ordered INI store
'
'   [global]
'   nick=bob
'   [network Libera]
'   server=irc.libera.chat/6697/tls
'   server=irc.eu.libera.chat/6697/tls      <- keys may repeat (ordered lists)
'
' Sections keep the order they were first seen in; keys keep insertion order.
' Section and key names compare case-insensitively. Values are stored verbatim
' (UTF-8, no newlines). Lines starting with ';' or '#' are comments and are not
' preserved when the file is saved again.
' =============================================================================

Type ini_entry
    sec As String
    key As String
    value As String
End Type

Type ini_file
    ents(Any) As ini_entry
    cnt       As Long
End Type

Sub ini_clear(ByRef f As ini_file)
    Erase f.ents
    f.cnt = 0
End Sub

Private Sub ini_push(ByRef f As ini_file, ByRef sec As String, ByRef key As String, ByRef value As String)
    If f.cnt > UBound(f.ents) Then ReDim Preserve f.ents(0 To f.cnt * 2 + 15)
    f.ents(f.cnt).sec   = sec
    f.ents(f.cnt).key   = key
    f.ents(f.cnt).value = value
    f.cnt += 1
End Sub

' Insert after the last entry of sec (or append a new section at the end).
Private Sub ini_insert(ByRef f As ini_file, ByRef sec As String, ByRef key As String, ByRef value As String)
    Dim lsec As String = LCase(sec)
    Dim last As Long = -1
    Dim i As Long
    For i = 0 To f.cnt - 1
        If LCase(f.ents(i).sec) = lsec Then last = i
    Next i
    If last < 0 OrElse last = f.cnt - 1 Then
        ini_push(f, sec, key, value)
        Exit Sub
    End If
    ini_push(f, "", "", "")               ' grow by one
    For i = f.cnt - 1 To last + 2 Step -1
        f.ents(i) = f.ents(i - 1)
    Next i
    f.ents(last + 1).sec   = f.ents(last).sec
    f.ents(last + 1).key   = key
    f.ents(last + 1).value = value
End Sub

Function ini_load(ByRef f As ini_file, ByRef path As String) As Byte
    ini_clear(f)
    Dim fh As Long = FreeFile()
    If Open(path For Input As #fh) <> 0 Then Return 0
    Dim ln  As String
    Dim sec As String = ""
    Dim first As Byte = 1
    Do While Not EOF(fh)
        Line Input #fh, ln
        ' strip a UTF-8 BOM on the first line
        If first AndAlso Left(ln, 3) = Chr(&hEF, &hBB, &hBF) Then ln = Mid(ln, 4)
        first = 0
        If Right(ln, 1) = Chr(13) Then ln = Left(ln, Len(ln) - 1)
        Dim t As String = Trim(ln)
        If Len(t) = 0 OrElse t[0] = Asc(";") OrElse t[0] = Asc("#") Then Continue Do
        If t[0] = Asc("[") AndAlso Right(t, 1) = "]" Then
            sec = Trim(Mid(t, 2, Len(t) - 2))
            Continue Do
        End If
        Dim eq As Long = InStr(t, "=")
        If eq = 0 Then Continue Do
        ini_push(f, sec, Trim(Left(t, eq - 1)), Trim(Mid(t, eq + 1)))
    Loop
    Close #fh
    Return 1
End Function

' Write atomically (temp file + rename).
Function ini_save(ByRef f As ini_file, ByRef path As String) As Byte
    Dim tmp As String = path & ".tmp"
    Dim fh  As Long = FreeFile()
    If Open(tmp For Output As #fh) <> 0 Then Return 0
    ' collect section order
    Dim secs() As String
    Dim ns As Long = 0
    Dim i As Long
    Dim j As Long
    ReDim secs(0 To 15)
    For i = 0 To f.cnt - 1
        Dim seen As Byte = 0
        For j = 0 To ns - 1
            If LCase(secs(j)) = LCase(f.ents(i).sec) Then seen = 1 : Exit For
        Next j
        If seen = 0 Then
            If ns > UBound(secs) Then ReDim Preserve secs(0 To ns * 2 + 1)
            secs(ns) = f.ents(i).sec
            ns += 1
        End If
    Next i
    For j = 0 To ns - 1
        If j > 0 Then Print #fh, ""
        If Len(secs(j)) > 0 Then Print #fh, "[" & secs(j) & "]"
        For i = 0 To f.cnt - 1
            If LCase(f.ents(i).sec) = LCase(secs(j)) Then Print #fh, f.ents(i).key & "=" & f.ents(i).value
        Next i
    Next j
    Close #fh
    If Len(Dir(path)) > 0 Then Kill path
    If Name(tmp, path) <> 0 Then Return 0
    Return 1
End Function

Function ini_get(ByRef f As ini_file, ByRef sec As String, ByRef key As String, ByRef def As String = "") As String
    Dim lsec As String = LCase(sec)
    Dim lkey As String = LCase(key)
    Dim i As Long
    For i = 0 To f.cnt - 1
        If LCase(f.ents(i).key) = lkey AndAlso LCase(f.ents(i).sec) = lsec Then Return f.ents(i).value
    Next i
    Return def
End Function

Function ini_has(ByRef f As ini_file, ByRef sec As String, ByRef key As String) As Byte
    Dim lsec As String = LCase(sec)
    Dim lkey As String = LCase(key)
    Dim i As Long
    For i = 0 To f.cnt - 1
        If LCase(f.ents(i).key) = lkey AndAlso LCase(f.ents(i).sec) = lsec Then Return 1
    Next i
    Return 0
End Function

Function ini_get_int(ByRef f As ini_file, ByRef sec As String, ByRef key As String, def As LongInt) As LongInt
    Dim v As String = ini_get(f, sec, key, "")
    If Len(v) = 0 Then Return def
    Return str_to_int(v, def)
End Function

' All values of a repeated key, in order.
Function ini_get_all(ByRef f As ini_file, ByRef sec As String, ByRef key As String, arr() As String) As Long
    Dim lsec As String = LCase(sec)
    Dim lkey As String = LCase(key)
    Dim n As Long = 0
    Dim i As Long
    ReDim arr(0 To 7)
    For i = 0 To f.cnt - 1
        If LCase(f.ents(i).key) = lkey AndAlso LCase(f.ents(i).sec) = lsec Then
            If n > UBound(arr) Then ReDim Preserve arr(0 To n * 2 + 1)
            arr(n) = f.ents(i).value
            n += 1
        End If
    Next i
    If n = 0 Then ReDim arr(0 To 0) Else ReDim Preserve arr(0 To n - 1)
    Return n
End Function

Sub ini_del_key(ByRef f As ini_file, ByRef sec As String, ByRef key As String)
    Dim lsec As String = LCase(sec)
    Dim lkey As String = LCase(key)
    Dim w As Long = 0
    Dim i As Long
    For i = 0 To f.cnt - 1
        If LCase(f.ents(i).key) = lkey AndAlso LCase(f.ents(i).sec) = lsec Then Continue For
        If w <> i Then f.ents(w) = f.ents(i)
        w += 1
    Next i
    f.cnt = w
End Sub

Sub ini_del_section(ByRef f As ini_file, ByRef sec As String)
    Dim lsec As String = LCase(sec)
    Dim w As Long = 0
    Dim i As Long
    For i = 0 To f.cnt - 1
        If LCase(f.ents(i).sec) = lsec Then Continue For
        If w <> i Then f.ents(w) = f.ents(i)
        w += 1
    Next i
    f.cnt = w
End Sub

' Set a single-valued key (replaces the first occurrence, drops the rest).
Sub ini_set(ByRef f As ini_file, ByRef sec As String, ByRef key As String, ByRef value As String)
    Dim lsec As String = LCase(sec)
    Dim lkey As String = LCase(key)
    Dim i As Long
    For i = 0 To f.cnt - 1
        If LCase(f.ents(i).key) = lkey AndAlso LCase(f.ents(i).sec) = lsec Then
            f.ents(i).value = value
            ' remove later duplicates
            Dim w As Long = i + 1
            Dim k As Long
            For k = i + 1 To f.cnt - 1
                If LCase(f.ents(k).key) = lkey AndAlso LCase(f.ents(k).sec) = lsec Then Continue For
                If w <> k Then f.ents(w) = f.ents(k)
                w += 1
            Next k
            f.cnt = w
            Exit Sub
        End If
    Next i
    ini_insert(f, sec, key, value)
End Sub

' Append one value of a repeated key.
Sub ini_add(ByRef f As ini_file, ByRef sec As String, ByRef key As String, ByRef value As String)
    ini_insert(f, sec, key, value)
End Sub

' Replace all values of a repeated key.
Sub ini_set_all(ByRef f As ini_file, ByRef sec As String, ByRef key As String, arr() As String, n As Long)
    ini_del_key(f, sec, key)
    Dim i As Long
    For i = 0 To n - 1
        ini_insert(f, sec, key, arr(i))
    Next i
End Sub

' Distinct section names in file order.
Function ini_sections(ByRef f As ini_file, arr() As String) As Long
    Dim n As Long = 0
    Dim i As Long
    Dim j As Long
    ReDim arr(0 To 7)
    For i = 0 To f.cnt - 1
        Dim seen As Byte = 0
        For j = 0 To n - 1
            If LCase(arr(j)) = LCase(f.ents(i).sec) Then seen = 1 : Exit For
        Next j
        If seen = 0 Then
            If n > UBound(arr) Then ReDim Preserve arr(0 To n * 2 + 1)
            arr(n) = f.ents(i).sec
            n += 1
        End If
    Next i
    If n = 0 Then ReDim arr(0 To 0) Else ReDim Preserve arr(0 To n - 1)
    Return n
End Function
