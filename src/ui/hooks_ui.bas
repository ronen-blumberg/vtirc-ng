' =============================================================================
' src/ui/hooks_ui.bas -- core -> UI hooks, window switching
' =============================================================================

Declare Function ui_command_impl(buf As Long, ByRef cmd As String, ByRef args As String) As Byte
Dim Shared app_quit As Byte
Dim Shared app_need_restart As Byte

Sub ui_update_title()
    Dim t As String = VTIRC_NAME
    Dim id As Long = ui_active
    If buf_valid(id) Then
        Dim c As Long = bufs(id).conn_id
        If conn_valid(c) Then
            t &= " - " & conns(c).name
            If bufs(id).kind <> BK_STATUS Then t &= " / " & bufs(id).name
        Else
            t &= " - " & bufs(id).name
        End If
    End If
    ' the title bar is ANSI on Windows / UTF-8 on X11: keep it ASCII-safe
    vt_title(vt_utf8_to_cp437(t))
End Sub

' Make id the active window.
Sub ui_switch(id As Long)
    If buf_valid(id) = 0 OrElse id = ui_active Then Exit Sub
    If buf_valid(ui_active) Then
        bufs(ui_active).draft = in_text
        ' remember the last line seen, for the "new messages" marker
        If bufs(ui_active).hist_count > 0 Then
            bufs(ui_active).marker = buf_line(ui_active, bufs(ui_active).hist_count - 1)->serial
        End If
    End If
    ui_active = id
    bufs(id).activity = ACT_NONE
    bufs(id).unread = 0
    bufs(id).highlights = 0
    in_text = bufs(id).draft
    in_pos = Len(in_text)
    in_view = 0
    in_hist_pos = -1
    tc_on = 0
    nl_sel = -1
    nl_top = 0
    sel_on = 0
    ui_dirty = 1
    ui_update_title()
End Sub

' Window by position in the tree (0-based).
Sub ui_switch_pos(p As Long)
    If ui_order_ok = 0 Then ui_order_rebuild()
    If p >= 0 AndAlso p < ui_order_n Then ui_switch(ui_order(p))
End Sub

Sub ui_switch_rel(delta As Long)
    If ui_order_ok = 0 Then ui_order_rebuild()
    If ui_order_n = 0 Then Exit Sub
    Dim p As Long = ui_order_pos(ui_active)
    If p < 0 Then p = 0
    ui_switch(ui_order(((p + delta) Mod ui_order_n + ui_order_n) Mod ui_order_n))
End Sub

' Jump to the window with the most important unseen activity.
Sub ui_switch_activity()
    If ui_order_ok = 0 Then ui_order_rebuild()
    Dim best As Long = -1
    Dim lvl As Long = ACT_EVENT
    Dim k As Long
    For k = 0 To ui_order_n - 1
        Dim b As Long = ui_order(k)
        If b <> ui_active AndAlso bufs(b).activity > lvl Then lvl = bufs(b).activity : best = b
    Next k
    If best < 0 Then
        For k = 0 To ui_order_n - 1
            If ui_order(k) <> ui_active AndAlso bufs(ui_order(k)).activity >= ACT_EVENT Then best = ui_order(k) : Exit For
        Next k
    End If
    If best >= 0 Then ui_switch(best)
End Sub

' ---------------------------------------------------------------- hooks
Sub ui_on_buffer_new(id As Long, focus As Byte)
    ui_seq_next += 1
    ui_seq(id) = ui_seq_next
    ui_order_ok = 0
    ui_dirty = 1
    If focus OrElse buf_valid(ui_active) = 0 Then ui_switch(id)
End Sub

Sub ui_on_buffer_closed(id As Long)
    ui_order_ok = 0
    ui_dirty = 1
    If sel_buf = id Then sel_on = 0
    If id <> ui_active Then Exit Sub
    ' pick the neighbour above in the tree (skipping the closing window)
    ui_order_rebuild()
    Dim p As Long = ui_order_pos(id)
    Dim nxt As Long = -1
    If p > 0 Then nxt = ui_order(p - 1)
    If nxt < 0 AndAlso ui_order_n > 1 Then nxt = ui_order(1)
    ui_active = -1
    If nxt >= 0 AndAlso nxt <> id Then
        ui_switch(nxt)
    End If
    ui_update_title()
End Sub

Sub ui_on_buffer_line(id As Long)
    If id = ui_active Then
        ' keep the view still while the user reads back
        If bufs(id).scroll > 0 Then bufs(id).scroll += 1
    End If
    ui_dirty = 1
End Sub

Sub ui_on_nicklist(id As Long)
    If id = ui_active Then ui_dirty = 1
End Sub

Sub ui_on_topic(id As Long)
    If id = ui_active Then ui_dirty = 1
End Sub

Sub ui_on_conn_state(conn_id As Long)
    ui_order_ok = 0
    ui_dirty = 1
    ui_update_title()
End Sub

Sub ui_on_notify(id As Long, kind As Long, ByRef title As String, ByRef text As String)
    Dim focused As Byte = window_focused()
    If focused AndAlso id = ui_active Then Exit Sub
    If kind = NK_QUERY AndAlso cfg.notify_pm = 0 Then Exit Sub
    If cfg.beep Then notify_beep()
    If cfg.flash AndAlso focused = 0 Then notify_flash()
    If focused = 0 Then notify_desktop(title, text)
End Sub

Sub ui_on_chanlist(conn_id As Long)
    ui_dirty = 1
End Sub

Sub ui_on_dcc()
    ui_dirty = 1
End Sub

Sub ui_request_focus(id As Long)
    ui_switch(id)
End Sub

Function ui_active_buffer() As Long
    Return ui_active
End Function

Function ui_command(buf As Long, ByRef cmd As String, ByRef args As String) As Byte
    Return ui_command_impl(buf, cmd, args)
End Function

Sub ui_request_exit()
    app_quit = 1
End Sub

Sub ui_settings_changed()
    theme_apply(cfg.theme)
    ui_dirty = 1
End Sub
