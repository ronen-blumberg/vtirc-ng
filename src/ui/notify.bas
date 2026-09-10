' =============================================================================
' src/ui/notify.bas -- sounds, taskbar flashing, desktop notifications, URLs
' =============================================================================

#Ifdef __FB_WIN32__
    #Include Once "win/shellapi.bi"
    #Include Once "win/mmsystem.bi"
#Else
    #Inclib "dl"
    Declare Function crt_dlsym Cdecl Alias "dlsym" (ByVal h As Any Ptr, ByVal nm As ZString Ptr) As Any Ptr
    Declare Function crt_dlopen Cdecl Alias "dlopen" (ByVal nm As ZString Ptr, ByVal flags As Long) As Any Ptr
#Endif

Type sdl_flash_fn As Function Cdecl(ByVal w As Any Ptr, ByVal op As Long) As Long
Dim Shared notify_flash_fn As sdl_flash_fn
Dim Shared notify_snd_cmd As String
Dim Shared notify_last_beep As Double

' SDL_FlashWindow exists since SDL 2.0.16; look it up at run time so an older
' SDL2 library still works (without flashing).
Sub notify_init()
    #Ifdef __FB_WIN32__
        Dim h As HMODULE = GetModuleHandle("SDL2.dll")
        If h <> 0 Then notify_flash_fn = CPtr(sdl_flash_fn, GetProcAddress(h, "SDL_FlashWindow"))
    #Else
        Dim h As Any Ptr = crt_dlopen(0, 1)                ' the running program + its libraries
        If h <> 0 Then notify_flash_fn = CPtr(sdl_flash_fn, crt_dlsym(h, "SDL_FlashWindow"))
        ' sound: a freedesktop sound through paplay / aplay, else the terminal bell
        Dim snd As String = ""
        If file_exists("/usr/share/sounds/freedesktop/stereo/message-new-instant.oga") Then
            snd = "/usr/share/sounds/freedesktop/stereo/message-new-instant.oga"
        ElseIf file_exists("/usr/share/sounds/freedesktop/stereo/bell.oga") Then
            snd = "/usr/share/sounds/freedesktop/stereo/bell.oga"
        End If
        If Len(snd) > 0 Then
            If Shell("command -v paplay >/dev/null 2>&1") = 0 Then
                notify_snd_cmd = "paplay '" & snd & "' >/dev/null 2>&1 &"
            ElseIf Shell("command -v aplay >/dev/null 2>&1") = 0 Then
                notify_snd_cmd = "aplay -q '" & snd & "' >/dev/null 2>&1 &"
            End If
        End If
    #Endif
End Sub

Function window_focused() As Byte
    #Ifndef BACKEND_VT
        If vt_internal.sdl_window = 0 Then Return 1
        Return IIf((SDL_GetWindowFlags(vt_internal.sdl_window) And SDL_WINDOW_INPUT_FOCUS) <> 0, 1, 0)
    #Else
        Return 1
    #Endif
End Function

Sub notify_beep()
    If clock_s() - notify_last_beep < 2 Then Exit Sub
    notify_last_beep = clock_s()
    #Ifdef __FB_WIN32__
        PlaySound("MailBeep", NULL, SND_ALIAS Or SND_ASYNC)
    #Else
        If Len(notify_snd_cmd) > 0 Then Shell notify_snd_cmd Else Beep
    #Endif
End Sub

Sub notify_flash()
    If notify_flash_fn <> 0 AndAlso vt_internal.sdl_window <> 0 Then
        notify_flash_fn(vt_internal.sdl_window, 2)          ' SDL_FLASH_UNTIL_FOCUSED
    End If
End Sub

' Single-quote a string for /bin/sh.
Function shell_quote(ByRef s As String) As String
    Dim r As String = "'"
    Dim i As Long
    For i = 0 To Len(s) - 1
        Select Case s[i]
        Case 39      : r &= "'\''"
        Case 0 To 31 : r &= " "
        Case Else    : r &= Chr(s[i])
        End Select
    Next i
    Return r & "'"
End Function

Sub notify_desktop(ByRef title As String, ByRef text As String)
    #Ifndef __FB_WIN32__
        If cfg.notify_send = 0 Then Exit Sub
        Shell "notify-send -a vtirc-ng -- " & shell_quote(Left(title, 100)) & " " & _
              shell_quote(Left(text, 300)) & " >/dev/null 2>&1 &"
    #Endif
End Sub

' Open a URL (http, https, ftp, irc) or a local file in the default program.
' Anything else is refused: IRC text is untrusted.
Function open_url(ByRef url As String, is_local As Byte = 0) As Byte
    Dim u As String = Trim(url)
    If Len(u) = 0 Then Return 0
    If is_local = 0 Then
        Dim lu As String = LCase(u)
        If Left(lu, 4) = "www." Then u = "http://" & u : lu = "http://" & lu
        If Left(lu, 7) <> "http://" AndAlso Left(lu, 8) <> "https://" AndAlso Left(lu, 6) <> "ftp://" AndAlso _
           Left(lu, 6) <> "irc://" AndAlso Left(lu, 7) <> "ircs://" Then Return 0
    End If
    #Ifdef __FB_WIN32__
        ShellExecute(NULL, "open", u, NULL, NULL, SW_SHOWNORMAL)
    #Else
        Shell "xdg-open " & shell_quote(u) & " >/dev/null 2>&1 &"
    #Endif
    Return 1
End Function
