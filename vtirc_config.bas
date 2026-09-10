' -----------------------------------------------------------------------------
' vtirc - F3 Common settings form
' -----------------------------------------------------------------------------
Function settings_common_form() As Long
    Const ITEM_COUNT   = 22
    Const CFORM_W      = 40
    Const CFORM_H      = 22
    Dim items(0 To ITEM_COUNT - 1) As vt_tui_form_item
    Dim focused  As Long = 1
    Dim k        As ULong
    Dim result   As Long
    Dim cform_x  As Long = (g_screen_cols - CFORM_W) \ 2
    Dim cform_y  As Long = (g_screen_rows - CFORM_H) \ 2
    
    ' --- scheme ---
    items(0).kind   = VT_FORM_LABEL
    items(0).x      = 1 : items(0).y   = 1
    items(0).wid    = CFORM_W - 2
    items(0).val    = "Colour Scheme:"
    items(0).align  = VT_ALIGN_LEFT
    items(0).lbl_fg = VT_BLACK
    items(0).lbl_bg = VT_LIGHT_GREY

    items(1).kind     = VT_FORM_RADIO
    items(1).x        = 2  : items(1).y = 3
    items(1).val      = "Dark"
    items(1).group_id = 1
    items(1).checked  = IIf(cfg.scheme = 0, 1, 0)

    items(2).kind     = VT_FORM_RADIO
    items(2).x        = 13 : items(2).y = 3
    items(2).val      = "Classic"
    items(2).group_id = 1
    items(2).checked  = IIf(cfg.scheme = 1, 1, 0)

    items(3).kind     = VT_FORM_RADIO
    items(3).x        = 25 : items(3).y = 3
    items(3).val      = "Light"
    items(3).group_id = 1
    items(3).checked  = IIf(cfg.scheme = 2, 1, 0)

    ' --- logging ---
    items(4).kind   = VT_FORM_LABEL
    items(4).x      = 1 : items(4).y   = 5
    items(4).wid    = 10
    items(4).val    = "Logging:"
    items(4).align  = VT_ALIGN_RIGHT
    items(4).lbl_fg = VT_BLACK
    items(4).lbl_bg = VT_LIGHT_GREY

    items(5).kind    = VT_FORM_CHECKBOX
    items(5).x       = 12 : items(5).y = 5
    items(5).val     = "Log channel"
    items(5).checked = cfg.log_enabled

    items(6).kind   = VT_FORM_LABEL
    items(6).x      = 1 : items(6).y   = 7
    items(6).wid    = 10
    items(6).val    = "PM Log:"
    items(6).align  = VT_ALIGN_RIGHT
    items(6).lbl_fg = VT_BLACK
    items(6).lbl_bg = VT_LIGHT_GREY

    items(7).kind    = VT_FORM_CHECKBOX
    items(7).x       = 12 : items(7).y = 7
    items(7).val     = "Log PMs"
    items(7).checked = cfg.log_pm
    
    ' --- network ---
    items(8).kind   = VT_FORM_LABEL
    items(8).x      = 1 : items(8).y   = 9
    items(8).wid    = 10
    items(8).val    = "Network:"
    items(8).align  = VT_ALIGN_RIGHT
    items(8).lbl_fg = VT_BLACK
    items(8).lbl_bg = VT_LIGHT_GREY

    items(9).kind    = VT_FORM_CHECKBOX
    items(9).x       = 12 : items(9).y = 9
    items(9).val     = "Auto-reconnect"
    items(9).checked = cfg.auto_reconnect

    ' --- display ---
    items(10).kind   = VT_FORM_LABEL
    items(10).x      = 1 : items(10).y   = 11
    items(10).wid    = 10
    items(10).val    = "Display:"
    items(10).align  = VT_ALIGN_RIGHT
    items(10).lbl_fg = VT_BLACK
    items(10).lbl_bg = VT_LIGHT_GREY

   ' timestamp
    items(11).kind    = VT_FORM_CHECKBOX
    items(11).x       = 12 : items(11).y = 11
    items(11).val     = "Show timestamps [HH:MM]"
    items(11).checked = cfg.show_timestamps

    ' notify
    items(12).kind   = VT_FORM_LABEL
    items(12).x      = 1 : items(12).y   = 13
    items(12).wid    = 10
    items(12).val    = "Notify:"
    items(12).align  = VT_ALIGN_RIGHT
    items(12).lbl_fg = VT_BLACK
    items(12).lbl_bg = VT_LIGHT_GREY

    items(13).kind    = VT_FORM_CHECKBOX
    items(13).x       = 12 : items(13).y = 13
    items(13).val     = "Beep on mention / PM"
    items(13).checked = cfg.beep_notify

    ' font size
    items(14).kind   = VT_FORM_LABEL
    items(14).x      = 1 : items(14).y   = 15
    items(14).wid    = 10
    items(14).val    = "Font Size:"
    items(14).align  = VT_ALIGN_RIGHT
    items(14).lbl_fg = VT_BLACK
    items(14).lbl_bg = VT_LIGHT_GREY

    items(15).kind     = VT_FORM_RADIO
    items(15).x        = 12 : items(15).y = 15
    items(15).val      = "8x16"
    items(15).group_id = 2
    items(15).checked  = IIf(cfg.font_size = 0, 1, 0)

    items(16).kind     = VT_FORM_RADIO
    items(16).x        = 27 : items(16).y = 15
    items(16).val      = "16x24"
    items(16).group_id = 2
    items(16).checked  = IIf(cfg.font_size = 1, 1, 0)

    ' renderer
    items(17).kind   = VT_FORM_LABEL
    items(17).x      = 1 : items(17).y   = 17
    items(17).wid    = 10
    items(17).val    = "Rendering:"
    items(17).align  = VT_ALIGN_RIGHT
    items(17).lbl_fg = VT_BLACK
    items(17).lbl_bg = VT_LIGHT_GREY

    items(18).kind     = VT_FORM_RADIO
    items(18).x        = 12 : items(18).y = 17
    items(18).val      = "Soft"
    items(18).group_id = 3
    items(18).checked  = IIf(cfg.renderer = 0, 1, 0)

    items(19).kind     = VT_FORM_RADIO
    items(19).x        = 27 : items(19).y = 17
    items(19).val      = "HW-ACC"
    items(19).group_id = 3
    items(19).checked  = IIf(cfg.renderer = 1, 1, 0)

    ' --- buttons ---
    items(20).kind = VT_FORM_BUTTON
    items(20).x    = 10 : items(20).y = 19
    items(20).val  = "OK"
    items(20).ret  = 1

    items(21).kind = VT_FORM_BUTTON
    items(21).x    = 22 : items(21).y = 19
    items(21).val  = "Cancel"
    items(21).ret  = 2

    vt_tui_form_offset(items(), cform_x, cform_y)
    draw_ui()
    vt_tui_theme_default()
    dialog_lock_size()

    Do
        irc_poll()
        k = vt_inkey()
 
        result = vt_tui_form_handle(items(), focused, k)
        vt_tui_rect_fill(cform_x + 1, cform_y + 1, CFORM_W - 2, CFORM_H - 2, _
                         32, VT_BLACK, VT_LIGHT_GREY)
        vt_tui_window(cform_x, cform_y, CFORM_W, CFORM_H, " VTIRC Settings ", _
                      VT_TUI_WIN_SHADOW)
        vt_tui_form_draw(items(), focused)
        vt_sleep(IDLE_MS)

        Select Case result
        Case VT_FORM_CANCEL, 2
            scheme_apply()
            dialog_unlock_size()
            Return 0
        Case 1
            If items(1).checked Then cfg.scheme = 0
            If items(2).checked Then cfg.scheme = 1
            If items(3).checked Then cfg.scheme = 2
            Dim new_log As Byte = items(5).checked
            If cfg.log_enabled = 1 AndAlso new_log = 0 Then
                hist_append("*** Logging stopped.", col_fg_sys)
                cfg.log_enabled = 0
            ElseIf cfg.log_enabled = 0 AndAlso new_log = 1 Then
                cfg.log_enabled = 1
                hist_append("*** Logging started.", col_fg_sys)
            End If
            cfg.log_pm = items(7).checked
            Dim new_ar As Byte = items(9).checked
            If cfg.auto_reconnect = 1 AndAlso new_ar = 0 Then
                reconnect_pending = 0
            End If
            cfg.auto_reconnect  = new_ar
            cfg.show_timestamps = items(11).checked
            cfg.beep_notify     = items(13).checked
            Dim new_font As Byte = IIf(items(16).checked, 1, 0)
            Dim new_renderer As Byte = IIf(items(19).checked, 1, 0)
            Dim info_dialog As Byte = 0
            If new_font <> cfg.font_size Then            
                info_dialog = 1
            End If
            cfg.font_size = new_font
            If new_renderer <> cfg.renderer Then
                info_dialog = 1
            End If
            cfg.renderer = new_renderer

            If info_dialog = 1 Then vt_tui_dialog("Settings", _
                    "Changes will be applied after restart.", _
                    VT_DLG_OK)

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