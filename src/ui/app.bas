' =============================================================================
' src/ui/app.bas -- startup, main loop, keys, mouse, menus
' =============================================================================

Dim Shared home_buf As Long = -1
Dim Shared last_input_t As Double
Dim Shared auto_away_on As Byte
Dim Shared last_minute As Long = -1
Dim Shared first_run As Byte

' ---------------------------------------------------------------- menus
Enum MENU_GROUP_T
    MG_IRC = 1
    MG_WINDOW
    MG_CHANNEL
    MG_VIEW
    MG_SETTINGS
    MG_HELP
End Enum

Sub menu_init()
    menu_groups(0) = "IRC"
    menu_groups(1) = "Window"
    menu_groups(2) = "Channel"
    menu_groups(3) = "View"
    menu_groups(4) = "Settings"
    menu_groups(5) = "Help"
    Dim it() As String
    Dim n As Long = 0
    ReDim menu_items(0 To 40)
    #Macro MI(txt)
        menu_items(n) = txt : n += 1
    #EndMacro
    MI("Networks...       F2") : MI("Connect") : MI("Disconnect") : MI("Reconnect") : MI("Away / back") : MI("Quit          Ctrl+Q")
    menu_counts(0) = 6
    MI("Next window   Ctrl+Tab") : MI("Previous window") : MI("Next active    Alt+A") : MI("Close          Ctrl+W") : MI("Clear") : MI("Search...      Ctrl+F") : MI("DCC transfers...")
    menu_counts(1) = 7
    MI("Join...        Ctrl+J") : MI("Part") : MI("Channel list...     F4") : MI("Change topic...") : MI("Ban list") : MI("Channel modes")
    menu_counts(2) = 6
    MI("Window tree       F7") : MI("Nick list         F8") : MI("Topic bar") : MI("Timestamps") : MI("Joins/parts: next mode") : MI("Next colour theme")
    menu_counts(3) = 6
    MI("Preferences...     F3") : MI("Ignore list...") : MI("Highlight words...") : MI("Aliases...") : MI("Save settings")
    menu_counts(4) = 5
    MI("Manual             F1") : MI("Command list") : MI("About")
    menu_counts(5) = 3
    ReDim Preserve menu_items(0 To n - 1)
End Sub

Private Function active_conn() As Long
    If buf_valid(ui_active) Then Return bufs(ui_active).conn_id
    Return -1
End Function

' Edit a client-wide [section] list stored in cfg_ini (highlight / ignore / alias).
Private Sub edit_ini_list(ByRef sec As String, ByRef title As String, ByRef hint As String, as_pairs As Byte)
    Dim lst() As String
    Dim n As Long = 0
    Dim i As Long
    ReDim lst(0 To 7)
    For i = 0 To cfg_ini.cnt - 1
        If LCase(cfg_ini.ents(i).sec) = LCase(sec) Then
            If n > UBound(lst) Then ReDim Preserve lst(0 To n * 2 + 7)
            lst(n) = IIf(as_pairs, cfg_ini.ents(i).key & " = " & cfg_ini.ents(i).value, cfg_ini.ents(i).value)
            n += 1
        End If
    Next i
    If dlg_list_edit(title, hint, lst(), n) = 0 Then Exit Sub
    ini_del_section(cfg_ini, sec)
    For i = 0 To n - 1
        If as_pairs Then
            Dim eq As Long = InStr(lst(i), "=")
            If eq > 0 Then ini_add(cfg_ini, sec, Trim(Left(lst(i), eq - 1)), Trim(Mid(lst(i), eq + 1)))
        Else
            ini_add(cfg_ini, sec, IIf(LCase(sec) = "highlight", "word", "item"), Trim(lst(i)))
        End If
    Next i
    ignore_load()
    highlight_load()
    alias_load()
    config_save()
End Sub

Sub menu_action(r As Long)
    Dim g As Long = VT_TUI_MENU_GROUP(r)
    Dim it As Long = VT_TUI_MENU_ITEM(r)
    Dim c As Long = active_conn()
    Select Case g
    Case MG_IRC
        Select Case it
        Case 1 : dlg_networks()
        Case 2 : If conn_valid(c) Then conn_connect(c) Else dlg_networks()
        Case 3 : If conn_valid(c) Then conn_disconnect(c)
        Case 4 : If conn_valid(c) Then cmd_execute(ui_active, "/reconnect")
        Case 5
            If conn_online(c) Then
                If conns(c).away Then cmd_execute(ui_active, "/back") Else cmd_execute(ui_active, "/away")
            End If
        Case 6 : If dlg_confirm("Quit", "Disconnect from all networks and quit?") Then cmd_execute(ui_active, "/exit")
        End Select
    Case MG_WINDOW
        Select Case it
        Case 1 : ui_switch_rel(1)
        Case 2 : ui_switch_rel(-1)
        Case 3 : ui_switch_activity()
        Case 4 : cmd_execute(ui_active, "/close")
        Case 5 : buf_clear(ui_active)
        Case 6
            Dim s As String = ""
            If dlg_input("Search", "Find lines containing:", s) AndAlso Len(s) > 0 Then cmd_execute(ui_active, "/lastlog " & s)
        Case 7 : dlg_dcc()
        End Select
    Case MG_CHANNEL
        Select Case it
        Case 1
            Dim ch As String = "#"
            If conn_online(c) AndAlso dlg_input("Join", "Channel (and key):", ch) AndAlso Len(ch) > 1 Then cmd_execute(ui_active, "/join " & ch)
        Case 2 : cmd_execute(ui_active, "/part")
        Case 3 : dlg_chanlist(c)
        Case 4
            If buf_valid(ui_active) AndAlso bufs(ui_active).kind = BK_CHANNEL Then
                Dim tp As String = bufs(ui_active).topic
                If dlg_input("Topic", "New topic for " & bufs(ui_active).name & ":", tp, 76) Then cmd_execute(ui_active, "/topic " & bufs(ui_active).name & " " & tp)
            End If
        Case 5 : cmd_execute(ui_active, "/banlist")
        Case 6 : cmd_execute(ui_active, "/mode")
        End Select
    Case MG_VIEW
        Select Case it
        Case 1 : cfg.show_tree = 1 - cfg.show_tree
        Case 2 : cfg.show_nicklist = 1 - cfg.show_nicklist
        Case 3 : cfg.show_topic = 1 - cfg.show_topic
        Case 4 : cfg.show_time = 1 - cfg.show_time
        Case 5
            cfg.hide_joinpart = (cfg.hide_joinpart + 1) Mod 3
            ev_client("Joins/parts: " & IIf(cfg.hide_joinpart = 0, "shown", IIf(cfg.hide_joinpart = 1, "hidden for inactive users", "hidden")))
        Case 6
            cfg.theme = (cfg.theme + 1) Mod 3
            theme_apply(cfg.theme)
        End Select
        config_save()
    Case MG_SETTINGS
        Select Case it
        Case 1 : dlg_settings()
        Case 2 : edit_ini_list("ignore", "Ignore list", "mask = types  (e.g. troll!*@* = all, or *!*@spam.host = msgs privs)", 1)
        Case 3 : edit_ini_list("highlight", "Highlight words", "A word that highlights a line like your nick does", 0)
        Case 4 : edit_ini_list("alias", "Aliases", "name = command  (e.g. ghost = /ns ghost $1 $2-)", 1)
        Case 5 : If config_save() Then ev_client("Settings saved to " & cfg_path)
        End Select
    Case MG_HELP
        Select Case it
        Case 1 : dlg_help()
        Case 2 : cmd_execute(ui_active, "/help")
        Case 3 : dlg_about()
        End Select
    End Select
    ui_dirty = 1
End Sub

' ---------------------------------------------------------------- UI commands
Function ui_command_impl(buf As Long, ByRef cmd As String, ByRef args As String) As Byte
    Select Case cmd
    Case "window", "win", "w"
        Dim a As String = LCase(str_word(args, 0))
        Select Case a
        Case "next" : ui_switch_rel(1)
        Case "prev" : ui_switch_rel(-1)
        Case "close" : cmd_execute(buf, "/close")
        Case ""
            ev_client("/window <number|name|next|prev|close>")
        Case Else
            Dim n As Long = str_to_int(a, -1)
            If n >= 1 Then
                ui_switch_pos(n - 1)
            Else
                If ui_order_ok = 0 Then ui_order_rebuild()
                Dim k As Long
                For k = 0 To ui_order_n - 1
                    If InStr(LCase(bufs(ui_order(k)).name), a) > 0 Then ui_switch(ui_order(k)) : Exit For
                Next k
            End If
        End Select
        Return 1
    Case "lastlog", "find", "search"
        If Len(args) = 0 OrElse buf_valid(buf) = 0 Then ev_client("Usage: /lastlog <text>") : Return 1
        Dim needle As String = utf8_lcase(args)
        Dim i As Long
        Dim hits As Long = 0
        Dim n As Long = bufs(buf).hist_count
        ev_line(buf, LK_INFO, 0, "--", "", "Lines containing '" & args & "':")
        For i = 0 To n - 1
            Dim p As irc_line Ptr = buf_line(buf, i)
            If p->kind <> LK_INFO OrElse p->prefix <> "--" Then
                If InStr(utf8_lcase(irc_strip_format(p->prefix & " " & p->text)), needle) > 0 Then
                    hits += 1
                    ev_line(buf, LK_INFO, LF_HISTORY, "", "", "[" & time_format(p->t, "%d/%m %H:%M") & "] " & p->prefix & " " & p->text)
                End If
            End If
        Next i
        ev_line(buf, LK_INFO, 0, "--", "", hits & " matching line" & IIf(hits = 1, "", "s"))
        Return 1
    Case "networks", "servers", "serverlist"
        dlg_networks() : Return 1
    Case "prefs", "settings", "options"
        dlg_settings() : Return 1
    Case "chanlist", "browser", "channels"
        dlg_chanlist(IIf(buf_valid(buf), bufs(buf).conn_id, -1)) : Return 1
    Case "about"
        dlg_about() : Return 1
    Case "transfers"
        dlg_dcc() : Return 1
    Case "manual"
        dlg_help() : Return 1
    Case "theme"
        Select Case LCase(Trim(args))
        Case "dark"    : cfg.theme = 0
        Case "classic" : cfg.theme = 1
        Case "light"   : cfg.theme = 2
        Case Else      : cfg.theme = (cfg.theme + 1) Mod 3
        End Select
        theme_apply(cfg.theme)
        config_save()
        ui_dirty = 1
        Return 1
    Case "tree"
        cfg.show_tree = 1 - cfg.show_tree : config_save() : ui_dirty = 1 : Return 1
    Case "nicklist", "userlist"
        cfg.show_nicklist = 1 - cfg.show_nicklist : config_save() : ui_dirty = 1 : Return 1
    Case "save"
        If config_save() Then ev_client("Settings saved to " & cfg_path)
        Return 1
    End Select
    Return 0
End Function

' ---------------------------------------------------------------- paste / submit
Sub app_paste(ByRef clip As String)
    Dim s As String = str_replace(str_replace(clip, Chr(13, 10), Chr(10)), Chr(13), Chr(10))
    If Right(s, 1) = Chr(10) Then s = Left(s, Len(s) - 1)
    If InStr(s, Chr(10)) = 0 Then
        input_insert(str_replace(s, Chr(9), " "))
        Exit Sub
    End If
    Dim a() As String
    Dim n As Long = str_split(s, Chr(10), a())
    Dim tgt As String = IIf(buf_valid(ui_active), bufs(ui_active).name, "")
    If cfg.confirm_paste > 0 AndAlso n > cfg.confirm_paste Then
        If dlg_confirm("Paste", "Send " & n & " lines to " & tgt & "?") = 0 Then Exit Sub
    End If
    Dim i As Long
    For i = 0 To n - 1
        If Len(a(i)) = 0 Then Continue For
        ' pasted lines are text, never commands
        cmd_execute(ui_active, IIf(Left(a(i), 1) = "/", "/", "") & str_replace(a(i), Chr(9), " "))
    Next i
End Sub

Sub app_submit()
    Dim ln As String = in_text
    If Len(ln) = 0 Then Exit Sub
    input_history_add(ln)
    in_hist_pos = -1
    input_set("")
    If buf_valid(ui_active) Then
        bufs(ui_active).scroll = 0
        bufs(ui_active).draft = ""
    End If
    cmd_execute(ui_active, ln)
End Sub

' ---------------------------------------------------------------- scrolling
Sub app_scroll(rows As Long)
    If buf_valid(ui_active) = 0 Then Exit Sub
    bufs(ui_active).scroll += rows
    If bufs(ui_active).scroll < 0 Then bufs(ui_active).scroll = 0
    ui_dirty = 1
End Sub

' ---------------------------------------------------------------- keys
Sub app_key(k As ULong, cp As ULong)
    If k = 0 Then Exit Sub
    last_input_t = clock_s()
    Dim sc As Long = VT_SCAN(k)
    Dim ch As Long = VT_CHAR(k)
    Dim al As Long = VT_ALT(k)
    Dim ctl As Long = VT_CTRL(k)
    Dim sh As Long = VT_SHIFT(k)
    ui_dirty = 1
    If al Then
        If ch >= Asc("1") AndAlso ch <= Asc("9") Then ui_switch_pos(ch - Asc("1")) : Exit Sub
        If ch = Asc("0") Then ui_switch_pos(9) : Exit Sub
        If sc = VT_KEY_LEFT Then ui_switch_rel(-1) : Exit Sub
        If sc = VT_KEY_RIGHT Then ui_switch_rel(1) : Exit Sub
        If ch = Asc("a") Then ui_switch_activity() : Exit Sub
        Exit Sub
    End If
    Select Case sc
    Case VT_KEY_F1 : dlg_help() : Exit Sub
    Case VT_KEY_F2 : dlg_networks() : Exit Sub
    Case VT_KEY_F3 : dlg_settings() : Exit Sub
    Case VT_KEY_F4 : dlg_chanlist(active_conn()) : Exit Sub
    Case VT_KEY_F7 : cfg.show_tree = 1 - cfg.show_tree : config_save() : Exit Sub
    Case VT_KEY_F8 : cfg.show_nicklist = 1 - cfg.show_nicklist : config_save() : Exit Sub
    Case VT_KEY_PGUP
        If ctl Then ui_switch_rel(-1) Else app_scroll(IIf(sh, 1, lay.chat_h \ 2))
        Exit Sub
    Case VT_KEY_PGDN
        If ctl Then ui_switch_rel(1) Else app_scroll(-IIf(sh, 1, lay.chat_h \ 2))
        Exit Sub
    Case VT_KEY_HOME
        If ctl Then app_scroll(1000000) : Exit Sub
    Case VT_KEY_END
        If ctl Then
            If buf_valid(ui_active) Then bufs(ui_active).scroll = 0
            Exit Sub
        End If
    Case VT_KEY_TAB
        If ctl Then ui_switch_rel(IIf(sh, -1, 1)) : Exit Sub
    Case VT_KEY_ENTER
        app_submit() : Exit Sub
    Case VT_KEY_ESC
        sel_on = 0 : tc_on = 0
        Exit Sub
    End Select
    If ctl AndAlso (sc = 0 OrElse sc = VT_KEY_SPACE) Then
        Select Case ch
        Case 23 : cmd_execute(ui_active, "/close") : Exit Sub                     ' Ctrl+W
        Case 17                                                                     ' Ctrl+Q
            If dlg_confirm("Quit", "Disconnect from all networks and quit?") Then cmd_execute(ui_active, "/exit")
            Exit Sub
        Case 10                                                                     ' Ctrl+J
            menu_action(MG_CHANNEL * 1000 + 1) : Exit Sub
        Case 6                                                                      ' Ctrl+F
            menu_action(MG_WINDOW * 1000 + 6) : Exit Sub
        Case 14 : ui_switch_rel(1) : Exit Sub                                     ' Ctrl+N
        Case 16 : ui_switch_rel(-1) : Exit Sub                                    ' Ctrl+P
        End Select
    End If
    input_key(k, cp)
End Sub

' ---------------------------------------------------------------- mouse
Dim Shared m_prev As Long
Dim Shared m_drag As Byte
Dim Shared m_moved As Byte
Dim Shared m_url As String
Dim Shared m_last_click As Double
Dim Shared m_last_x As Long, m_last_y As Long

' Chat cell under the mouse: history line + text cell (clamped to the row).
Private Function chat_hit(mx As Long, my As Long, ByRef li As Long, ByRef ci As Long) As Byte
    If my < lay.top OrElse my > lay.bot OrElse mx < lay.chat_x1 OrElse mx > lay.chat_x2 Then Return 0
    Dim ri As Long = my - lay.top + 1
    If rmap(ri).li < 0 Then Return 0
    li = rmap(ri).li
    Dim col0 As Long = mx - lay.chat_x1
    If col0 > 255 Then col0 = 255
    ci = rcol_cell(ri, col0)
    If ci >= 0 Then Return 1
    ' left of the text: first cell of the row; right of it: last cell
    Dim lo As Long = &h7FFFFFFF, hi As Long = -1
    Dim cc As Long
    For cc = 0 To 255
        Dim v As Long = rcol_cell(ri, cc)
        If v >= 0 Then
            If v < lo Then lo = v
            If v > hi Then hi = v
        End If
    Next cc
    If hi < 0 Then ci = 0 : Return 1
    ci = IIf(mx < rmap(ri).tx, lo, hi)
    Return 1
End Function

' Text of the current selection (logical order, lines joined with newlines).
Function selection_text() As String
    If sel_on = 0 OrElse buf_valid(sel_buf) = 0 Then Return ""
    Dim a_li As Long = sel_a_li, a_ci As Long = sel_a_ci
    Dim b_li As Long = sel_b_li, b_ci As Long = sel_b_ci
    If a_li > b_li OrElse (a_li = b_li AndAlso a_ci > b_ci) Then Swap a_li, b_li : Swap a_ci, b_ci
    Dim txt_out As String
    Dim cells() As ucell
    Dim li As Long
    For li = a_li To b_li
        Dim p As irc_line Ptr = buf_line(sel_buf, li)
        If p = 0 Then Continue For
        Dim n As Long = text_cells(p->text, 7, 0, cells(), 1)
        Dim s As Long = IIf(li = a_li, a_ci, 0)
        Dim e As Long = IIf(li = b_li, b_ci, n - 1)
        If e >= n Then e = n - 1
        ' copy the original text (cells may hold Arabic presentation forms)
        Dim piece As String = ""
        If e >= s Then
            Dim b0 As Long = cells(s).src
            Dim b1 As Long = IIf(e + 1 < n, cells(e + 1).src, Len(p->text))
            piece = irc_strip_format(Mid(p->text, b0 + 1, b1 - b0))
        End If
        If a_li <> b_li AndAlso s = 0 AndAlso Len(p->prefix) > 0 Then piece = p->prefix & " " & piece
        If li > a_li Then txt_out &= Chr(10)
        txt_out &= piece
    Next li
    Return txt_out
End Function

Private Sub popup_nick(ByRef nick As String, mx As Long, my As Long)
    If Len(nick) = 0 Then Exit Sub
    Dim items(0 To 11) As String = { "Query", "Whois", "Op", "Deop", "Voice", "Devoice", "Kick", "Ban", _
                                     "Kick + ban", "Ignore", "CTCP version", "CTCP ping" }
    Dim r As Long = dlg_popup(mx, my, items(), 12)
    Select Case r
    Case 0 : cmd_execute(ui_active, "/query " & nick)
    Case 1 : cmd_execute(ui_active, "/whois " & nick)
    Case 2 : cmd_execute(ui_active, "/op " & nick)
    Case 3 : cmd_execute(ui_active, "/deop " & nick)
    Case 4 : cmd_execute(ui_active, "/voice " & nick)
    Case 5 : cmd_execute(ui_active, "/devoice " & nick)
    Case 6 : cmd_execute(ui_active, "/kick " & nick)
    Case 7 : cmd_execute(ui_active, "/ban " & nick)
    Case 8 : cmd_execute(ui_active, "/kb " & nick)
    Case 9 : cmd_execute(ui_active, "/ignore " & nick & " all")
    Case 10 : cmd_execute(ui_active, "/ctcp " & nick & " VERSION")
    Case 11 : cmd_execute(ui_active, "/ctcp " & nick & " PING")
    End Select
End Sub

Private Sub popup_window(id As Long, mx As Long, my As Long)
    If buf_valid(id) = 0 Then Exit Sub
    Dim items(0 To 4) As String = { "Close", "Clear", "Reconnect", "Disconnect", "Mark all as read" }
    Dim r As Long = dlg_popup(mx, my, items(), 5)
    Select Case r
    Case 0 : cmd_execute(id, "/close")
    Case 1 : buf_clear(id)
    Case 2 : cmd_execute(id, "/reconnect")
    Case 3 : If conn_valid(bufs(id).conn_id) Then conn_disconnect(bufs(id).conn_id)
    Case 4
        Dim i As Long
        For i = 0 To BUF_MAX - 1
            If bufs(i).alive Then bufs(i).activity = 0 : bufs(i).unread = 0 : bufs(i).highlights = 0
        Next i
    End Select
End Sub

Sub app_mouse(mx As Long, my As Long, mb As Long, wh As Long)
    Dim pressed As Long = mb And Not m_prev
    Dim released As Long = m_prev And Not mb
    Dim in_chat As Byte = IIf(mx >= lay.chat_x1 AndAlso mx <= lay.chat_x2 AndAlso my >= lay.top AndAlso my <= lay.bot, 1, 0)
    Dim in_tree As Byte = IIf(lay.tree_on AndAlso mx <= lay.tree_x2 AndAlso my >= lay.top AndAlso my <= lay.bot, 1, 0)
    Dim in_nl As Byte = IIf(lay.nl_on AndAlso mx >= lay.nl_x1 AndAlso my > lay.top AndAlso my <= lay.bot, 1, 0)
    If mb <> 0 OrElse m_prev <> 0 OrElse wh <> 0 Then last_input_t = clock_s()

    If wh <> 0 Then
        If in_tree Then
            tree_top -= wh : ui_dirty = 1
        ElseIf in_nl Then
            nl_top -= wh * 3 : ui_dirty = 1
        Else
            app_scroll(wh * 3)
        End If
    End If

    Dim dbl As Byte = 0
    If pressed And VT_MOUSE_BTN_LEFT Then
        If clock_s() - m_last_click < 0.4 AndAlso mx = m_last_x AndAlso my = m_last_y Then dbl = 1
        m_last_click = clock_s() : m_last_x = mx : m_last_y = my
    End If

    ' ---- left button
    If pressed And VT_MOUSE_BTN_LEFT Then
        m_moved = 0
        m_url = ""
        If in_tree Then
            Dim k As Long = tree_top + (my - lay.top)
            If k < ui_order_n Then ui_switch(ui_order(k))
        ElseIf in_nl Then
            Dim row As Long = nl_top + (my - lay.top - 1)
            If row < bufs(ui_active).user_count Then
                nl_sel = row
                If dbl Then cmd_execute(ui_active, "/query " & bufs(ui_active).users(bufs(ui_active).sorted(row)).nick)
            End If
            ui_dirty = 1
        ElseIf in_chat Then
            Dim ri As Long = my - lay.top + 1
            Dim col0 As Long = mx - lay.chat_x1
            If col0 > 255 Then col0 = 255
            If rmap(ri).li >= 0 AndAlso rcol_url(ri, col0) > 0 Then m_url = rmap_url(ri, rcol_url(ri, col0))
            If dbl AndAlso rmap(ri).first AndAlso mx >= rmap(ri).nick_x1 AndAlso mx <= rmap(ri).nick_x2 AndAlso Len(rmap(ri).nick) > 0 Then
                cmd_execute(ui_active, "/query " & rmap(ri).nick)
            Else
                Dim li As Long, ci As Long
                If chat_hit(mx, my, li, ci) Then
                    sel_on = 0
                    sel_buf = ui_active
                    sel_a_li = li : sel_a_ci = ci
                    sel_b_li = li : sel_b_ci = ci
                    m_drag = 1
                End If
            End If
        ElseIf my = lay.input_row Then
            ' place the cursor (logical approximation)
            Dim target As Long = mx - 1 - IIf(buf_valid(ui_active) AndAlso conn_valid(bufs(ui_active).conn_id), _
                                              Len(conns(bufs(ui_active).conn_id).nick) + 3, 0) + in_view
            Dim p As Long = 0
            Dim w As Long = 0
            While p < Len(in_text) AndAlso w < target
                Dim q As Long = p
                w += IIf(in_text[p] < 32, 1, utf8_cp_width(utf8_decode(in_text, q)))
                p = utf8_next(in_text, p)
            Wend
            in_pos = p
            ui_dirty = 1
        End If
    ElseIf (mb And VT_MOUSE_BTN_LEFT) AndAlso m_drag Then
        ' extend the selection; drag above / below scrolls
        If my < lay.top Then app_scroll(1)
        If my > lay.bot Then app_scroll(-1)
        Dim cy As Long = IIf(my < lay.top, lay.top, IIf(my > lay.bot, lay.bot, my))
        Dim cx As Long = IIf(mx < lay.chat_x1, lay.chat_x1, IIf(mx > lay.chat_x2, lay.chat_x2, mx))
        Dim li2 As Long, ci2 As Long
        If chat_hit(cx, cy, li2, ci2) Then
            If li2 <> sel_b_li OrElse ci2 <> sel_b_ci Then
                sel_b_li = li2 : sel_b_ci = ci2
                sel_on = 1
                m_moved = 1
                ui_dirty = 1
            End If
        End If
    End If
    If released And VT_MOUSE_BTN_LEFT Then
        If m_drag AndAlso m_moved AndAlso sel_on Then
            Dim t As String = selection_text()
            If Len(t) > 0 Then vt_clipboard_set(t)
        ElseIf m_moved = 0 AndAlso Len(m_url) > 0 Then
            If Left(m_url, 1) = "#" Then
                cmd_execute(ui_active, "/join " & m_url)
            ElseIf open_url(m_url) = 0 Then
                ev_client("Not opening " & m_url)
            End If
            sel_on = 0
        Else
            sel_on = 0
        End If
        m_drag = 0
        ui_dirty = 1
    End If

    ' ---- right button: context menus
    If pressed And VT_MOUSE_BTN_RIGHT Then
        If in_tree Then
            Dim k2 As Long = tree_top + (my - lay.top)
            If k2 < ui_order_n Then popup_window(ui_order(k2), mx, my)
        ElseIf in_nl Then
            Dim row2 As Long = nl_top + (my - lay.top - 1)
            If row2 < bufs(ui_active).user_count Then
                nl_sel = row2
                render_all()
                popup_nick(bufs(ui_active).users(bufs(ui_active).sorted(row2)).nick, mx, my)
            End If
        ElseIf in_chat Then
            Dim ri2 As Long = my - lay.top + 1
            Dim col2 As Long = mx - lay.chat_x1
            If col2 > 255 Then col2 = 255
            If rmap(ri2).li >= 0 AndAlso rmap(ri2).first AndAlso mx >= rmap(ri2).nick_x1 AndAlso mx <= rmap(ri2).nick_x2 AndAlso Len(rmap(ri2).nick) > 0 Then
                popup_nick(rmap(ri2).nick, mx, my)
            ElseIf rmap(ri2).li >= 0 AndAlso rcol_url(ri2, col2) > 0 Then
                Dim u As String = rmap_url(ri2, rcol_url(ri2, col2))
                Dim ui_items(0 To 1) As String = { IIf(Left(u, 1) = "#", "Join channel", "Open link"), "Copy" }
                Select Case dlg_popup(mx, my, ui_items(), 2)
                Case 0 : If Left(u, 1) = "#" Then cmd_execute(ui_active, "/join " & u) Else open_url(u)
                Case 1 : vt_clipboard_set(u)
                End Select
            Else
                Dim ci_items(0 To 3) As String = { "Copy selection", "Search...", "Clear window", "Close window" }
                Select Case dlg_popup(mx, my, ci_items(), 4)
                Case 0 : If sel_on Then vt_clipboard_set(selection_text())
                Case 1 : menu_action(MG_WINDOW * 1000 + 6)
                Case 2 : buf_clear(ui_active)
                Case 3 : cmd_execute(ui_active, "/close")
                End Select
            End If
        End If
        ui_dirty = 1
    End If

    ' ---- middle button: paste
    If pressed And VT_MOUSE_BTN_MIDDLE Then app_paste(vt_clipboard_get())
    m_prev = mb
End Sub

' ---------------------------------------------------------------- lifecycle
Function app_on_close() As Byte
    app_quit = 1
    Return 1            ' veto libvt's immediate shutdown; we quit gracefully
End Function

Sub app_idle()
    core_poll()
    If ut_on Then uitest_tick()
End Sub

Private Sub app_timers()
    Dim y As Long, mo As Long, d As Long, h As Long, mi As Long, se As Long
    time_local_fields(time_now(), y, mo, d, h, mi, se)
    If mi <> last_minute Then last_minute = mi : ui_dirty = 1      ' status bar clock
    If cfg.auto_away_min > 0 Then
        Dim idle As Double = clock_s() - last_input_t
        If auto_away_on = 0 AndAlso idle > cfg.auto_away_min * 60 Then
            auto_away_on = 1
            Dim c As Long
            For c = 0 To CONN_MAX - 1
                If conn_online(c) AndAlso conns(c).away = 0 Then conn_send(c, "AWAY :" & cfg.away_msg & " (auto-away)")
            Next c
        ElseIf auto_away_on AndAlso idle < 2 Then
            auto_away_on = 0
            Dim c2 As Long
            For c2 = 0 To CONN_MAX - 1
                If conn_online(c2) AndAlso conns(c2).away Then conn_send(c2, "AWAY")
            Next c2
        End If
    End If
End Sub

Private Sub app_check_resize()
    Dim nc As Long, nr As Long
    If vt_screeninfo(nc, nr) Then
        If nc < 60 Then nc = 60
        If nr < 20 Then nr = 20
        If nc > 255 Then nc = 255
        If nr > 255 Then nr = 255
        vt_width(nc, nr)
        cfg.screen_cols = nc
        cfg.screen_rows = nr
        ui_dirty = 1
    End If
End Sub

Sub app_welcome()
    home_buf = buf_new(-1, BK_SPECIAL, VTIRC_NAME, 1)
    ev_line(home_buf, LK_INFO, 0, "--", "", "Welcome to " & VTIRC_NAME & " " & VTIRC_VERSION & ", a full-featured IRC client for the text screen.")
    ev_line(home_buf, LK_INFO, 0, "--", "", "F2 opens the network list, F1 the manual. Or type /server irc.libera.chat +6697")
    ev_line(home_buf, LK_INFO, 0, "--", "", "Settings are stored in " & path_cfg_dir)
End Sub

Sub app_main()
    core_init()
    first_run = IIf(file_exists(cfg_path), 0, 1)
    ' screen
    Dim fw As Long = 8, fh As Long = 16
    Select Case cfg.font_size
    Case 1 : fw = 16 : fh = 32
    Case 2 : fw = 24 : fh = 48
    End Select
    Dim cols As Long = cfg.screen_cols
    Dim rows As Long = cfg.screen_rows
    If cols < 60 OrElse cols > 255 Then cols = 120
    If rows < 20 OrElse rows > 255 Then rows = 40
    vt_title(VTIRC_NAME)
    Dim flags As Long = VT_WINDOWED Or IIf(cfg.renderer_hw, VT_RENDERER_HW, 0)
    If vt_screen(VT_SCREENPARAM(cols, rows, fw, fh), flags) <> 0 Then
        If vt_screen(VT_SCREENPARAM(100, 30, 8, 16), VT_WINDOWED) <> 0 Then End 1
    End If
    vt_screen_minimum(60, 20)
    vt_scroll_enable(0)
    vt_mouse(1)
    vt_copypaste(VT_DISABLED)
    vt_locate(, , 1, 95)
    vt_on_close(@app_on_close)
    vt_on_idle(@app_idle)
    ' fonts: embedded subset, plus the full file when available
    vt_font_unicode_embed(vtirc_unifont_embed_blob(), VTIRC_UNIFONT_EMBED_LEN)
    If cfg.unicode_font Then
        ' next to the program (release layout), or fonts/ in the working directory
        Dim ff As String = path_join(path_join(path_exe_dir, "fonts"), "vtirc-ng.vtuf")
        If file_exists(ff) = 0 Then ff = path_join(path_exe_dir, "vtirc-ng.vtuf")
        If file_exists(ff) = 0 Then ff = path_join(path_join(CurDir(), "fonts"), "vtirc-ng.vtuf")
        If file_exists(ff) Then vt_font_unicode_load(ff)
    End If
    utf8_font_width = @vt_uni_glyph_width
    theme_apply(cfg.theme)
    notify_init()
    menu_init()
    uitest_init()
    app_welcome()
    ' autoconnect
    Dim i As Long
    For i = 0 To net_count - 1
        If nets(i).autoconnect Then
            Dim c As Long = conn_new(i, nets(i).name)
            If c >= 0 Then conn_connect(c)
        End If
    Next i
    last_input_t = clock_s()
    render_all()
    If first_run Then
        config_save()
        dlg_networks()
    End If

    Dim mx As Long, my As Long, mb As Long, wh As Long
    Do
        ' handle every key that arrived since the last frame (fast typing,
        ' IME commits); the menu bar sees each key first, and one call with
        ' no key lets it react to clicks on the bar
        Dim nkeys As Long = 0
        Do
            Dim k As ULong = vt_inkey()
            Dim cp As ULong = vt_key_cp()
            If k = 0 AndAlso nkeys > 0 Then Exit Do
            Dim mr As Long = vt_tui_menubar_handle(1, menu_groups(), menu_items(), menu_counts(), k)
            If mr > 0 Then
                menu_action(mr)
                k = 0
                m_prev = 7          ' ignore the click that closed the menu
            ElseIf mr <> 0 Then
                k = 0
            End If
            If k <> 0 Then app_key(k, cp)
            nkeys += 1
            If k = 0 OrElse nkeys > 64 OrElse app_quit Then Exit Do
        Loop
        app_check_resize()
        If vt_paste_requested() Then app_paste(vt_clipboard_get())
        vt_getmouse(@mx, @my, @mb, @wh)
        app_mouse(mx, my, mb, wh)
        app_timers()
        If ui_dirty Then render_all()
        vt_sleep(10)
    Loop Until app_quit

    ' graceful shutdown: QUIT everywhere, wait briefly for the messages to go out
    For i = 0 To CONN_MAX - 1
        If conns(i).alive AndAlso conns(i).st <> CS_OFFLINE Then conn_disconnect(i)
    Next i
    Dim t0 As Double = clock_s()
    While conn_any_closing() AndAlso clock_s() - t0 < 2
        vt_sleep(20)
    Wend
    cfg.screen_cols = vt_cols()
    cfg.screen_rows = vt_rows()
    config_save()
    vt_shutdown()
    If ut_fail > 0 Then End 1
End Sub
