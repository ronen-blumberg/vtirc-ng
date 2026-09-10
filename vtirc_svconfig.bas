' -----------------------------------------------------------------------------
' vtirc - F2 Server settings form
' -----------------------------------------------------------------------------
Function settings_server_form() As Long
    Const ITEM_COUNT   = 14
    Const FORM_W       = 46
    Const FORM_H       = 15

    Dim items(0 To ITEM_COUNT - 1) As vt_tui_form_item
    Dim focused As Long = 1
    Dim k       As ULong
    Dim result  As Long
    Dim form_x  As Long = (g_screen_cols - FORM_W) \ 2
    Dim form_y  As Long = (g_screen_rows - FORM_H) \ 2

    Dim li As Long
    For li = 0 To 8 Step 2
        items(li).kind   = VT_FORM_LABEL
        items(li).wid    = 10
        items(li).align  = VT_ALIGN_RIGHT
        items(li).lbl_fg = VT_BLACK
        items(li).lbl_bg = VT_LIGHT_GREY
    Next li
    items(0).x = 1 : items(0).y = 1 : items(0).val = "Server:"
    items(2).x = 1 : items(2).y = 3 : items(2).val = "Port:"
    items(4).x = 1 : items(4).y = 5 : items(4).val = "Channels:"
    items(6).x = 1 : items(6).y = 7 : items(6).val = "Nick:"
    items(8).x = 1 : items(8).y = 9 : items(8).val = "Password:"

    items(1).kind    = VT_FORM_INPUT
    items(1).x       = 12 : items(1).y       = 1
    items(1).wid     = 30 : items(1).max_len = 63
    items(1).val     = cfg.server
    items(1).cpos    = Len(cfg.server)

    items(3).kind    = VT_FORM_INPUT
    items(3).x       = 12 : items(3).y       = 3
    items(3).wid     = 8  : items(3).max_len = 5
    items(3).val     = Trim(Str(cfg.port))
    items(3).cpos    = Len(items(3).val)

    items(5).kind    = VT_FORM_INPUT
    items(5).x       = 12 : items(5).y       = 5
    items(5).wid     = 30 : items(5).max_len = 200
    items(5).val     = cfg.channel
    items(5).cpos    = Len(cfg.channel)

    items(7).kind    = VT_FORM_INPUT
    items(7).x       = 12 : items(7).y       = 7
    items(7).wid     = 20 : items(7).max_len = 30
    items(7).val     = cfg.nick
    items(7).cpos    = Len(cfg.nick)

    items(9).kind    = VT_FORM_INPUT
    items(9).x       = 12 : items(9).y       = 9
    items(9).wid     = 30 : items(9).max_len = 64
    items(9).val     = cfg.password
    items(9).cpos    = Len(cfg.password)

    items(10).kind   = VT_FORM_LABEL
    items(10).x      = 1 : items(10).y  = 11
    items(10).wid    = 10
    items(10).val    = "Alt Nick:"
    items(10).align  = VT_ALIGN_RIGHT
    items(10).lbl_fg = VT_BLACK
    items(10).lbl_bg = VT_LIGHT_GREY

    items(11).kind    = VT_FORM_INPUT
    items(11).x       = 12 : items(11).y = 11
    items(11).wid     = FORM_W - 14
    items(11).val     = cfg.nick_alt
    items(11).cpos    = Len(cfg.nick_alt)
    items(11).max_len = 30

    items(12).kind = VT_FORM_BUTTON
    items(12).x    = 10 : items(12).y = 13
    items(12).val  = "OK"
    items(12).ret  = 1

    items(13).kind = VT_FORM_BUTTON
    items(13).x    = 22 : items(13).y = 13
    items(13).val  = "Cancel"
    items(13).ret  = 2

    vt_tui_form_offset(items(), form_x, form_y)
    draw_ui()
    vt_tui_theme_default()
    dialog_lock_size()
    Do
        k = vt_inkey()

        result = vt_tui_form_handle(items(), focused, k)
        vt_tui_rect_fill(form_x + 1, form_y + 1, FORM_W - 2, FORM_H - 2, _
                         32, VT_BLACK, VT_LIGHT_GREY)
        vt_tui_window(form_x, form_y, FORM_W, FORM_H, " VTIRC Server Settings ", _
                      VT_TUI_WIN_SHADOW)
        vt_tui_form_draw(items(), focused)
        vt_sleep(IDLE_MS)

        Select Case result
        Case VT_FORM_CANCEL, 2
            scheme_apply()
            dialog_unlock_size()
            Return 0
        Case 1
            cfg.server   = Trim(items(1).val)
            cfg.port     = Val(Trim(items(3).val))
            If cfg.port < 1 Or cfg.port > 65535 Then cfg.port = 6667
            cfg.channel  = Trim(items(5).val)
            cfg.nick     = Trim(items(7).val)
            cfg.password = items(9).val
            cfg.nick_alt = Trim(items(11).val)
            cfg_save()
            scheme_apply()
            dialog_unlock_size()
            Return 1
        End Select
    Loop
    scheme_apply()
    dialog_unlock_size()
    Return 0
End Function
