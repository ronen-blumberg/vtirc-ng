' =============================================================================
' src/core/logger.bas -- chat logs
'
'   <cfg>/logs/<network>/<target>.log       one file per channel / query
'   <cfg>/logs/<network>/_status.log         server window
'   line format:  [YYYY-MM-DD HH:MM:SS] <prefix> <text without formatting>
' =============================================================================

Dim Shared log_dirs_ok As String      ' dirs already created, "|dir|dir|"

Function log_path_for(id As Long) As String
    If buf_valid(id) = 0 Then Return ""
    Dim c As Long = bufs(id).conn_id
    If conn_valid(c) = 0 Then Return ""
    Dim nd As String = path_join(path_log_dir, path_sanitize(conns(c).name))
    Dim fn As String
    Select Case bufs(id).kind
    Case BK_STATUS            : fn = "_status"
    Case BK_CHANNEL, BK_QUERY : fn = path_sanitize(LCase(bufs(id).name))
    Case BK_DCC               : fn = "dcc_" & path_sanitize(LCase(bufs(id).name))
    Case Else                 : Return ""
    End Select
    Return path_join(nd, fn & ".log")
End Function

Private Function log_wanted(id As Long) As Byte
    If cfg.log_enabled = 0 OrElse buf_valid(id) = 0 Then Return 0
    Select Case bufs(id).kind
    Case BK_QUERY, BK_DCC : Return cfg.log_pm
    Case BK_CHANNEL, BK_STATUS : Return 1
    End Select
    Return 0
End Function

Sub log_line(id As Long, ByRef prefix As String, ByRef text As String, t As Double)
    If log_wanted(id) = 0 Then Exit Sub
    Dim p As String = log_path_for(id)
    If Len(p) = 0 Then Exit Sub
    Dim d As String = path_join(path_log_dir, path_sanitize(conns(bufs(id).conn_id).name))
    If InStr(log_dirs_ok, "|" & d & "|") = 0 Then
        mkdir_p(d)
        log_dirs_ok &= "|" & d & "|"
    End If
    Dim fh As Long = FreeFile()
    If Open(p For Append As #fh) <> 0 Then Exit Sub
    Dim ln As String = "[" & time_format(t, "%Y-%m-%d %H:%M:%S") & "] "
    If Len(prefix) > 0 Then ln &= prefix & " "
    Print #fh, ln & irc_strip_format(text)
    Close #fh
End Sub

' Last n lines of a buffer's log (oldest first). Reads at most the final 256 KB.
Function log_tail(id As Long, n As Long, lines() As String) As Long
    If n <= 0 Then Return 0
    Dim p As String = log_path_for(id)
    If Len(p) = 0 OrElse file_exists(p) = 0 Then Return 0
    Dim fh As Long = FreeFile()
    If Open(p For Binary Access Read As #fh) <> 0 Then Return 0
    Dim sz As LongInt = Lof(fh)
    Dim rd As LongInt = IIf(sz > 262144, 262144, sz)
    Dim blob As String = Space(rd)
    Get #fh, sz - rd + 1, blob
    Close #fh
    Dim a() As String
    Dim cnt As Long = str_split(blob, Chr(10), a())
    ' drop an incomplete first line when we started mid-file
    Dim first As Long = IIf(rd < sz, 1, 0)
    Dim got As Long = 0
    ReDim lines(0 To n - 1)
    Dim i As Long
    For i = cnt - 1 To first Step -1
        Dim s As String = a(i)
        If Right(s, 1) = Chr(13) Then s = Left(s, Len(s) - 1)
        If Len(s) = 0 Then Continue For
        got += 1
        If got > n Then got = n : Exit For
        lines(n - got) = s
    Next i
    If got = 0 Then Return 0
    ' shift to the start of the array
    If got < n Then
        For i = 0 To got - 1
            lines(i) = lines(n - got + i)
        Next i
    End If
    ReDim Preserve lines(0 To got - 1)
    Return got
End Function
