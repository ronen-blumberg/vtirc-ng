' vtirc - Help window
sub help_window()
    Const HW   = 44
    Const HH   = 17
    Dim   HX   As Long = (g_screen_cols - HW) \ 2
    Dim   HY   As Long = (g_screen_rows - HH) \ 2
    Dim   ED_X As Long = HX + 2
    Dim   ED_Y As Long = HY + 2
    Const ED_W = HW - 4
    Const ED_H = HH - 5

    Const help_txt As String = _
        " Keyboard Shortcuts"                    & VT_LF & _
        "  F1          This help"                & VT_LF & _
        "  F2          Server settings"          & VT_LF & _
        "  F3          Client settings"          & VT_LF & _
        "  F4          Browse channels"          & VT_LF & _
        "  F10         Disconnect"               & VT_LF & _
        "  Ctrl+Tab    Cycle windows"            & VT_LF & _
        "  Ctrl+W      Close PM window"          & VT_LF & _
        "   Note: use /part for channels"        & VT_LF & _
        "  Tab         Nick completion"          & VT_LF & _
        ""                                       & VT_LF & _
        " Scrolling"                             & VT_LF & _
        "  PgUp/PgDn/Wheel  Scroll history"      & VT_LF & _
        "  Home             Jump to oldest"      & VT_LF & _
        "  End              Jump to newest"      & VT_LF & _
        ""                                       & VT_LF & _
        " User List (left pane)"                 & VT_LF & _
        "  Shows users in the active channel"    & VT_LF & _
        "  (Empty when active window is a PM)"   & VT_LF & _
        "  Click nick to select"                 & VT_LF & _
        "  Double-click to open PM"              & VT_LF & _
        ""                                       & VT_LF & _
        " Copy from history"                     & VT_LF & _
        "  1)hold LMB and drag to select"        & VT_LF & _
        "  2)RMB to copy selection to clipboard" & VT_LF & _
        ""                                       & VT_LF & _
        " Paste from clipboard"                  & VT_LF & _
        "  in chat line MMB|SHIFT+INS|CTRL+V"    & VT_LF & _
        ""                                       & VT_LF & _
        " Open a logfile"                        & VT_LF & _
        "  if enabled, click on [log] in status" & VT_LF & _
        ""                                       & VT_LF & _
        " Commands"                              & VT_LF & _
        "  /nick <n>       Change nickname"      & VT_LF & _
        "  /msg <n> [txt]  Open PM window"       & VT_LF & _
        "  /me <text>      Send action message"  & VT_LF & _
        "  /afk [msg]      Set away status"      & VT_LF & _
        "  /back           Return from AFK"      & VT_LF & _
        "  /clear          Clear chat history"   & VT_LF & _
        "  /part           Leave active channel" & VT_LF & _
        "  /join <ch>      Join channel(new win)"& VT_LF & _
        "  /quit           Disconnect"           & VT_LF & _
        ""                                       & VT_LF & _
        " Input History"                         & VT_LF & _
        "  Up/Down arrows  Browse sent lines"    & VT_LF & _
        ""                                       & VT_LF & _
        " Color Input (EGA indexes)"             & VT_LF & _
        "  ^ 0=blk   ^1=blu   ^2=grn   ^3=cyn"   & VT_LF & _
        "  ^ 4=red   ^5=mag   ^6=brn   ^7=lgr"   & VT_LF & _
        "  ^ 8=dgr   ^9=bblu ^10=bgrn ^11=bcyn"  & VT_LF & _
        "  ^12=bred ^13=bmag ^14=yel  ^15=wht"

    Dim ed_st As vt_tui_editor_state
    ed_st.work   = help_txt
    ed_st.cpos   = 0
    ed_st.top_ln = 0
    ed_st.dirty  = 0
    ed_st.flags  = VT_TUI_ED_READONLY

    Dim hlp_items(0) As vt_tui_form_item
    Dim hlp_focused  As Long = 0
    hlp_items(0).kind = VT_FORM_BUTTON
    hlp_items(0).x    = (HW - 9) \ 2
    hlp_items(0).y    = HH - 2
    hlp_items(0).val  = "Close"
    hlp_items(0).ret  = 1
    vt_tui_form_offset(hlp_items(), HX, HY)

    Dim k      As ULong
    Dim result As Long

    draw_ui()
    vt_tui_theme_default()
    dialog_lock_size()

    Do
        irc_poll()
        k      = vt_inkey()

        result = vt_tui_form_handle(hlp_items(), hlp_focused, k, VT_FORM_NO_ESC)
        vt_tui_editor_handle(ED_X, ED_Y, ED_W, ED_H, ed_st, k)

        If VT_SCAN(k) = VT_KEY_ESC Then Exit Do
        If result = 1 Then Exit Do

        vt_tui_rect_fill(HX + 1, HY + 1, HW - 2, HH - 2, 32, VT_BLACK, VT_LIGHT_GREY)
        vt_tui_window(HX, HY, HW, HH, " VTIRC Quick Manual - MWheel to scroll ", VT_TUI_WIN_SHADOW)
        vt_tui_editor_draw(ED_X, ED_Y, ED_W, ED_H, ed_st)
        vt_tui_form_draw(hlp_items(), hlp_focused)
        vt_sleep(IDLE_MS)
    Loop
    scheme_apply()
    dialog_unlock_size()
End Sub
