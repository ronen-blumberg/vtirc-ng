' =============================================================================
' src/util/paths.bas -- where vtirc-ng keeps its files
'
'   portable mode  : a file named "portable" next to the executable -> all data
'                    lives next to the executable (like VTIRC 1.x)
'   Windows        : %APPDATA%\vtirc-ng
'   Linux          : $XDG_CONFIG_HOME/vtirc-ng  (default ~/.config/vtirc-ng)
'
'   <cfg>/vtirc-ng.ini   configuration        <cfg>/logs/<network>/   logs
'   <cfg>/certs.ini      TLS certificate pins <cfg>/downloads/        DCC files
' =============================================================================
#Include Once "file.bi"
#Include Once "dir.bi"

#Ifdef __FB_WIN32__
    Const PATH_SEP = "\"
#Else
    Const PATH_SEP = "/"
    Declare Function crt_chmod Cdecl Alias "chmod" (ByVal p As ZString Ptr, ByVal mode As ULong) As Long
#Endif

Dim Shared path_exe_dir  As String
Dim Shared path_cfg_dir  As String
Dim Shared path_log_dir  As String
Dim Shared path_dl_dir   As String
Dim Shared path_portable As Byte

Function path_join(ByRef a As String, ByRef b As String) As String
    If Len(a) = 0 Then Return b
    If Right(a, 1) = "/" OrElse Right(a, 1) = "\" Then Return a & b
    Return a & PATH_SEP & b
End Function

Function dir_exists(ByRef p As String) As Byte
    If Len(p) = 0 Then Return 0
    Dim t As String = p
    If Len(t) > 1 AndAlso (Right(t, 1) = "/" OrElse Right(t, 1) = "\") Then t = Left(t, Len(t) - 1)
    Return IIf(Len(Dir(t, fbDirectory Or fbHidden Or fbSystem)) > 0, 1, 0)
End Function

Function file_exists(ByRef p As String) As Byte
    Return IIf(FileExists(p), 1, 0)
End Function

' mkdir -p
Function mkdir_p(ByRef p As String) As Byte
    If dir_exists(p) Then Return 1
    Dim i As Long
    For i = 2 To Len(p)
        Dim c As String = Mid(p, i, 1)
        If c = "/" OrElse c = "\" Then
            Dim part As String = Left(p, i - 1)
            If Len(part) > 0 AndAlso Right(part, 1) <> ":" AndAlso dir_exists(part) = 0 Then MkDir part
        End If
    Next i
    MkDir p
    Return dir_exists(p)
End Function

' Restrict a file to the owner (config holds passwords). No-op on Windows,
' where %APPDATA% is already per-user.
Sub file_make_private(ByRef p As String)
    #Ifndef __FB_WIN32__
        crt_chmod(StrPtr(p), &o600)
    #Endif
End Sub

' Make an arbitrary string (channel / nick / network name) safe as one path
' component: no separators, reserved characters or leading dots.
Function path_sanitize(ByRef s As String) As String
    Dim r As String
    Dim i As Long
    For i = 0 To Len(s) - 1
        Dim c As UByte = s[i]
        Select Case c
        Case 0 To 31, Asc("/"), Asc("\"), Asc(":"), Asc("*"), Asc("?"), Asc(""""), Asc("<"), Asc(">"), Asc("|")
            r &= "_"
        Case Else
            r &= Chr(c)
        End Select
    Next i
    While Left(r, 1) = "." OrElse Left(r, 1) = " "
        r = "_" & Mid(r, 2)
    Wend
    While Right(r, 1) = "." OrElse Right(r, 1) = " "
        r = Left(r, Len(r) - 1) & "_"
    Wend
    If Len(r) = 0 Then r = "_"
    ' Windows reserved device names
    Select Case UCase(r)
    Case "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "LPT1", "LPT2", "LPT3"
        r = "_" & r
    End Select
    If Len(r) > 120 Then r = Left(r, 120)
    Return r
End Function

Sub paths_init(ByRef app As String = "vtirc-ng", ByRef override_dir As String = "")
    path_exe_dir = ExePath()
    If Len(override_dir) > 0 Then
        path_cfg_dir  = override_dir
        path_portable = 0
    ElseIf file_exists(path_join(path_exe_dir, "portable")) OrElse _
           file_exists(path_join(path_exe_dir, "portable.txt")) Then
        path_cfg_dir  = path_exe_dir
        path_portable = 1
    Else
        path_portable = 0
        #Ifdef __FB_WIN32__
            Dim basedir As String = Environ("APPDATA")
            If Len(basedir) = 0 Then basedir = path_exe_dir
            path_cfg_dir = path_join(basedir, app)
        #Else
            Dim basedir As String = Environ("XDG_CONFIG_HOME")
            If Len(basedir) = 0 Then
                Dim home As String = Environ("HOME")
                If Len(home) = 0 Then home = path_exe_dir
                basedir = path_join(home, ".config")
            End If
            path_cfg_dir = path_join(basedir, app)
        #Endif
    End If
    mkdir_p(path_cfg_dir)
    path_log_dir = path_join(path_cfg_dir, "logs")
    path_dl_dir  = path_join(path_cfg_dir, "downloads")
End Sub
