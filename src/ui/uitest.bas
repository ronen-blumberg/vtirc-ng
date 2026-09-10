' =============================================================================
' src/ui/uitest.bas -- scripted UI driving for automated tests
'
' Active only when VTIRC_TEST_SCRIPT names a script file. Commands, one per
' line (runs from the idle hook, so it also drives modal dialogs):
'   wait <seconds>          pause the script
'   cmd <input line>        run as if typed + Enter in the active window
'   type <text>             type text (UTF-8) through the keyboard path
'   key [ctrl+|alt+|shift+]<name>   press a key (F1..F12 TAB ENTER ESC UP DOWN
'                           LEFT RIGHT PGUP PGDN HOME END BKSP DEL or a letter)
'   mouse <col> <row> <buttons>     set the mouse (buttons: 0 none 1 left 2 right 4 middle)
'   wheel <delta>           mouse wheel
'   snap <file.bmp>         save the current screen
'   echo <text>             print to stdout
'   expect_active <text>    check the active window name contains text
'   quit                    exit the program
' =============================================================================

Dim Shared ut_on As Byte
Dim Shared ut_lines() As String
Dim Shared ut_n As Long
Dim Shared ut_i As Long
Dim Shared ut_wait As Double
Dim Shared ut_fail As Long

Sub uitest_init()
    Dim f As String = Environ("VTIRC_TEST_SCRIPT")
    If Len(f) = 0 OrElse file_exists(f) = 0 Then Exit Sub
    Dim fh As Long = FreeFile()
    If Open(f For Input As #fh) <> 0 Then Exit Sub
    ReDim ut_lines(0 To 15)
    ut_n = 0
    Do While Not EOF(fh)
        Dim ln As String
        Line Input #fh, ln
        ln = Trim(ln)
        If Len(ln) = 0 OrElse Left(ln, 1) = "#" Then Continue Do
        If ut_n > UBound(ut_lines) Then ReDim Preserve ut_lines(0 To ut_n * 2 + 1)
        ut_lines(ut_n) = ln
        ut_n += 1
    Loop
    Close #fh
    ut_on = 1
    ut_i = 0
    ut_wait = clock_s() + 0.3
End Sub

Sub uitest_snap(ByRef fname As String)
    #Ifndef BACKEND_VT
        vt_internal.dirty = 1
        vt_present()
        Dim w As Long = vt_internal.scr_cols * vt_internal.glyph_w
        Dim h As Long = vt_internal.scr_rows * vt_internal.glyph_h
        SDL_SetRenderTarget(vt_internal.sdl_renderer, vt_internal.sdl_buffer)
        Dim surf As SDL_Surface Ptr = SDL_CreateRGBSurfaceWithFormat(0, w, h, 32, SDL_PIXELFORMAT_ARGB8888)
        If surf <> 0 Then
            SDL_RenderReadPixels(vt_internal.sdl_renderer, 0, SDL_PIXELFORMAT_ARGB8888, surf->pixels, surf->pitch)
            SDL_SaveBMP_RW(surf, SDL_RWFromFile(fname, "wb"), 1)
            SDL_FreeSurface(surf)
        End If
        SDL_SetRenderTarget(vt_internal.sdl_renderer, 0)
    #Endif
End Sub

Private Function ut_key(ByRef spec As String, ByRef cp As ULong) As ULong
    Dim s As String = LCase(spec)
    Dim mods As ULong = 0
    cp = 0
    Do
        If Left(s, 5) = "ctrl+" Then
            mods Or= (1UL Shl 30) : s = Mid(s, 6)
        ElseIf Left(s, 4) = "alt+" Then
            mods Or= (1UL Shl 31) : s = Mid(s, 5)
        ElseIf Left(s, 6) = "shift+" Then
            mods Or= (1UL Shl 29) : s = Mid(s, 7)
        Else
            Exit Do
        End If
    Loop
    Dim sc As Long = 0
    Select Case s
    Case "f1" : sc = VT_KEY_F1
    Case "f2" : sc = VT_KEY_F2
    Case "f3" : sc = VT_KEY_F3
    Case "f4" : sc = VT_KEY_F4
    Case "f7" : sc = VT_KEY_F7
    Case "f8" : sc = VT_KEY_F8
    Case "f10" : sc = VT_KEY_F10
    Case "tab" : sc = VT_KEY_TAB
    Case "enter" : sc = VT_KEY_ENTER
    Case "esc" : sc = VT_KEY_ESC
    Case "up" : sc = VT_KEY_UP
    Case "down" : sc = VT_KEY_DOWN
    Case "left" : sc = VT_KEY_LEFT
    Case "right" : sc = VT_KEY_RIGHT
    Case "pgup" : sc = VT_KEY_PGUP
    Case "pgdn" : sc = VT_KEY_PGDN
    Case "home" : sc = VT_KEY_HOME
    Case "end" : sc = VT_KEY_END
    Case "bksp" : sc = VT_KEY_BKSP
    Case "del" : sc = VT_KEY_DEL
    Case "space" : sc = VT_KEY_SPACE : cp = 32
    End Select
    If sc <> 0 Then Return (CULng(sc) Shl 16) Or mods Or IIf(sc = VT_KEY_SPACE, 32, 0)
    Dim ch As Long = Asc(s)
    If (mods And (1UL Shl 30)) <> 0 AndAlso ch >= 97 AndAlso ch <= 122 Then Return CULng(ch - 96) Or mods
    cp = ch
    Return CULng(ch) Or mods
End Function

Sub uitest_tick()
    If ut_on = 0 OrElse clock_s() < ut_wait Then Exit Sub
    While ut_i < ut_n
        Dim ln As String = ut_lines(ut_i)
        ut_i += 1
        Dim verb As String = LCase(str_word(ln, 0))
        Dim arg As String = str_rest(ln, 1)
        Select Case verb
        Case "wait"
            ut_wait = clock_s() + Val(arg)
            Exit Sub
        Case "cmd"
            cmd_execute(ui_active, arg)
        Case "type"
            Dim p As Long = 0
            While p < Len(arg)
                Dim cp As ULong = utf8_decode(arg, p)
                Dim ch As UByte = vt_uni_to_cp437(cp)
                If cp < 128 Then
                    vt_key_inject(cp, cp)
                ElseIf ch <> 0 Then
                    vt_key_inject(ch, cp)
                Else
                    vt_key_inject(CULng(VT_KEY_UNICODE) Shl 16, cp)
                End If
            Wend
        Case "key"
            Dim kc As ULong
            Dim kcp As ULong
            kc = ut_key(arg, kcp)
            vt_key_inject(kc, kcp)
        Case "mouse"
            vt_internal.mouse_col = str_to_int(str_word(arg, 0), 1)
            vt_internal.mouse_row = str_to_int(str_word(arg, 1), 1)
            vt_internal.mouse_btns = str_to_int(str_word(arg, 2), 0)
        Case "wheel"
            vt_internal.mouse_wheel += str_to_int(arg, 0)
        Case "snap"
            uitest_snap(arg)
        Case "echo"
            Print arg
        Case "expect_active"
            Dim nm As String = IIf(buf_valid(ui_active), bufs(ui_active).name, "")
            If InStr(LCase(nm), LCase(arg)) > 0 Then
                Print "PASS active window: " & nm
            Else
                Print "FAIL active window is '" & nm & "', expected '" & arg & "'"
                ut_fail += 1
            End If
        Case "quit"
            app_quit = 1
            ut_on = 0
            Exit Sub
        End Select
    Wend
    ut_on = 0
End Sub
