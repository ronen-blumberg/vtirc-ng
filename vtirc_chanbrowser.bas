' -----------------------------------------------------------------------------
' vtirc - F4 Channel browser
' -----------------------------------------------------------------------------
Sub channel_browser()
    Const BFW  = 78
    Const BFH  = 28
    Dim   BFX  As Long = (g_screen_cols - BFW) \ 2
    Dim   BFY  As Long = (g_screen_rows - BFH) \ 2
    Dim   BLBX As Long = BFX + 1                      ' listbox left edge
    Dim   BLBY As Long = BFY + 3                      ' listbox top (row after header)
    Const BLBW = BFW - 2                              ' = 76
    Const BLBH = 19                                   ' was 20; row BFY+1 given to search bar
    Const CH_W  = 22
    Const CNT_W = 6
    Const TOP_W = BLBW - CH_W - 1 - CNT_W - 1   ' = 46

    ' -- request channel list ------------------------------------------------
    chlist_active = 1
    chlist_done   = 0
    chlist_count  = 0
    irc_send("LIST")

    draw_ui()
    vt_tui_theme_default()
    dialog_lock_size()

    ' -- fetch loop: show progress until 323 or timeout ----------------------
    Dim t_start As Double = Timer
    Dim ek      As ULong
    Do
        irc_poll()
        If chlist_done Then Exit Do
        If Timer - t_start > 15.0 Then Exit Do

        vt_tui_rect_fill(BFX + 1, BFY + 1, BFW - 2, BFH - 2, 32, VT_BLACK, VT_LIGHT_GREY)
        vt_tui_window(BFX, BFY, BFW, BFH, " Channel Browser ", VT_TUI_WIN_SHADOW)
        vt_color(VT_BLACK, VT_LIGHT_GREY)
        vt_locate(BFY + 5, BFX + 3)
        vt_print("Fetching channel list...  " & chlist_count & " channels received so far.")
        vt_locate(BFY + 7, BFX + 3)
        vt_print("Press Esc to cancel.")

        ek = vt_inkey()
        
        If VT_SCAN(ek) = VT_KEY_ESC Then
            chlist_active = 0
            scheme_apply()
            dialog_unlock_size()
            Return
        End If
        vt_sleep(IDLE_MS)
    Loop
    chlist_active = 0

    If chlist_count = 0 Then
        scheme_apply()
        dialog_unlock_size()
        hist_append("*** Channel list empty or request timed out.", col_fg_sys)
        Return
    End If

    ' -- filtered index map --------------------------------------------------
    ' filtered_idx(i) = index into chlist_* for the i-th visible listbox row
    ReDim filtered_idx(chlist_count - 1) As Long
    ReDim lb_items(chlist_count - 1)     As String
    Dim flt_count As Long = 0

    ' -- combined form: search label + input + Join + Cancel -----------------
    Dim frm_items(3) As vt_tui_form_item
    Dim frm_focused  As Long = 1   ' start focus on the search input

    frm_items(0).kind   = VT_FORM_LABEL
    frm_items(0).x      = 2 : frm_items(0).y   = 1
    frm_items(0).wid    = 8
    frm_items(0).val    = "Search:"
    frm_items(0).align  = VT_ALIGN_LEFT
    frm_items(0).lbl_fg = VT_DARK_GREY
    frm_items(0).lbl_bg = VT_LIGHT_GREY

    frm_items(1).kind    = VT_FORM_INPUT
    frm_items(1).x       = 10 : frm_items(1).y  = 1
    frm_items(1).wid     = BLBW - 10            ' = 66
    frm_items(1).max_len = 50
    frm_items(1).val     = ""
    frm_items(1).cpos    = 0

    frm_items(2).kind = VT_FORM_BUTTON
    frm_items(2).x    = (BFW \ 2) - 10
    frm_items(2).y    = BFH - 2
    frm_items(2).val  = "Join"
    frm_items(2).ret  = 1

    frm_items(3).kind = VT_FORM_BUTTON
    frm_items(3).x    = (BFW \ 2) + 4
    frm_items(3).y    = BFH - 2
    frm_items(3).val  = "Cancel"
    frm_items(3).ret  = 2

    vt_tui_form_offset(frm_items(), BFX, BFY)

    Dim lb_st As vt_tui_listbox_state
    lb_st.sel             = 0
    lb_st.top_item        = 0
    lb_st.last_click_item = -1
    lb_st.last_click_time = 0.0
    lb_st.prev_btns       = 0

    Dim k_cb      As ULong
    Dim result    As Long
    Dim prev_srch As String = Chr(1)   ' impossible init value -- forces first build

    ' -- browser loop --------------------------------------------------------
    Do
        irc_poll()
        k_cb = vt_inkey()

        ' -- rebuild lb_items whenever the search string changes --------------
        If frm_items(1).val <> prev_srch Then
            prev_srch = frm_items(1).val
            Dim srch_lc As String = LCase(prev_srch)
            flt_count = 0
            Dim fi As Long
            For fi = 0 To chlist_count - 1
                If Len(srch_lc) = 0 _
                   OrElse InStr(LCase(chlist_names(fi)),  srch_lc) > 0 _
                   OrElse InStr(LCase(chlist_topics(fi)), srch_lc) > 0 Then
                    filtered_idx(flt_count) = fi
                    flt_count += 1
                End If
            Next fi
            ReDim lb_items(IIf(flt_count > 0, flt_count - 1, 0)) As String
            Dim li As Long
            For li = 0 To flt_count - 1
                Dim ri      As Long   = filtered_idx(li)
                Dim ch_col  As String = chlist_names(ri)
                If Len(ch_col) > CH_W Then ch_col = Left(ch_col, CH_W)
                ch_col = ch_col & Space(CH_W - Len(ch_col))
                Dim cnt_str As String = Trim(Str(chlist_users(ri)))
                Dim cnt_col As String = Space(CNT_W - Len(cnt_str)) & cnt_str
                Dim top_col As String = chlist_topics(ri)
                If Len(top_col) > TOP_W Then top_col = Left(top_col, TOP_W)
                lb_items(li) = ch_col & " " & cnt_col & " " & top_col
            Next li
            lb_st.sel      = 0
            lb_st.top_item = 0
        End If

        ' -- key routing: input focused -> listbox gets no keys ---------------
        ' (arrows stay in the text field; mouse clicks on listbox still work)
        Dim lb_key As ULong = IIf(frm_focused = 1, 0, k_cb)

        result = vt_tui_form_handle(frm_items(), frm_focused, k_cb, VT_FORM_NO_ESC)

        Dim lb_ret As Long = VT_FORM_PENDING
        If flt_count > 0 Then
            lb_ret = vt_tui_listbox_handle(BLBX, BLBY, BLBW, BLBH, _
                                           lb_items(), lb_st, lb_key)
        End If
        If lb_ret >= 0 Then result = 1   ' double-click in listbox = join

        If VT_SCAN(k_cb) = VT_KEY_ESC OrElse result = 2 Then 
            ReDim lb_items(0)
            ReDim filtered_idx(0)
            Clear lb_items(0),,SizeOf(lb_items)*ubound(lb_items)
            Clear filtered_idx(0),,SizeOf(filtered_idx)*ubound(filtered_idx)
            Exit Do
        End If

        If result = 1 Then
            If flt_count > 0 Then
                Dim real_idx As Long   = filtered_idx(lb_st.sel)
                Dim sel_ch   As String = chlist_names(real_idx)
                If Len(sel_ch) > 0 Then
                    do_channel_join(sel_ch)
                End If
            End If
            Exit Do
        End If

        ' -- draw ------------------------------------------------------------
        vt_tui_rect_fill(BFX + 1, BFY + 1, BFW - 2, BFH - 2, 32, VT_BLACK, VT_LIGHT_GREY)
        Dim ttl_str As String = " Channel Browser  " & chlist_count & " channels"
        If flt_count < chlist_count Then
            ttl_str &= "  (" & flt_count & " shown)"
        End If
        ttl_str &= "  Enter/DblClick=Join "
        vt_tui_window(BFX, BFY, BFW, BFH, ttl_str, VT_TUI_WIN_SHADOW)

        ' column header
        vt_color(VT_DARK_GREY, VT_LIGHT_GREY)
        vt_locate(BFY + 2, BLBX)
        vt_print(Left(vt_str_pad_right("Channel", CH_W, " ") & " " & _
                      vt_str_pad_right("Users", CNT_W, " ") & " " & "Topic", BLBW))

        ' topic of selected item (uses real index via filtered_idx)
        Dim sel_topic As String = ""
        If flt_count > 0 Then
            Dim si As Long = lb_st.sel
            If si < 0 Then si = 0
            If si >= flt_count Then si = flt_count - 1
            sel_topic = chlist_topics(filtered_idx(si))
            If Len(sel_topic) > BFW - 4 Then sel_topic = Left(sel_topic, BFW - 4)
        End If
        vt_color(VT_BLACK, VT_LIGHT_GREY)
        vt_locate(BFY + BFH - 4, BFX + 2)
        vt_print(vt_str_pad_right(sel_topic, BFW - 4, " "))

        If flt_count > 0 Then
            vt_tui_listbox_draw(BLBX, BLBY, BLBW, BLBH, lb_items(), lb_st)
        Else
            vt_color(VT_DARK_GREY, VT_LIGHT_GREY)
            vt_locate(BLBY, BLBX)
            vt_print(vt_str_pad_right(" (no channels match)", BLBW, " "))
        End If
        vt_tui_form_draw(frm_items(), frm_focused)
        vt_sleep(IDLE_MS)
    Loop

    ReDim lb_items(0)
    ReDim filtered_idx(0)
    Clear lb_items(0),,SizeOf(lb_items)*ubound(lb_items)
    Clear filtered_idx(0),,SizeOf(filtered_idx)*ubound(filtered_idx)
    dialog_unlock_size()
    scheme_apply()
End Sub