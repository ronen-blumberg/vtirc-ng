' =============================================================================
' src/ui/render.bas -- screen layout and drawing
'
'   row 1          menu bar
'   row 2          topic bar (channels, optional)
'   rows top..bot  [window tree] | chat | [nick list]
'   row h-1        input line
'   row h          status bar
' =============================================================================

Type ui_layout
    w          As Long
    h          As Long
    topic_row  As Long      ' 0 = no topic bar
    top        As Long
    bot        As Long
    input_row  As Long
    status_row As Long
    tree_on    As Byte
    tree_x2    As Long
    chat_x1    As Long
    chat_x2    As Long
    chat_w     As Long
    chat_h     As Long
    nl_on      As Byte
    nl_x1      As Long
End Type

Dim Shared lay As ui_layout
Dim Shared ui_active As Long = -1
Dim Shared ui_dirty As Byte = 1
Dim Shared ui_seq(0 To BUF_MAX - 1) As Long       ' creation order of buffers
Dim Shared ui_seq_next As Long
Dim Shared ui_order(0 To BUF_MAX - 1) As Long     ' window order (tree / Alt+n)
Dim Shared ui_order_n As Long
Dim Shared ui_order_ok As Byte
Dim Shared tree_top As Long
Dim Shared nl_top As Long
Dim Shared nl_sel As Long = -1                     ' selected row in the sorted nick list

' what is under each chat row (for mouse hits, URLs and selection)
Const ROWMAP_MAX = 256
Type row_map
    li      As Long         ' history line index (-1 = none / marker)
    serial  As LongInt
    first   As Byte         ' first row of the line (prefix visible)
    tx      As Long         ' screen column where the text cells start
    nick_x1 As Long         ' prefix column range (clicking a nick)
    nick_x2 As Long
    nick    As String
End Type
Dim Shared rmap(1 To ROWMAP_MAX) As row_map
Dim Shared rcol_cell(1 To ROWMAP_MAX, 0 To 255) As Long   ' logical text cell under a column (-1)
Dim Shared rcol_url(1 To ROWMAP_MAX, 0 To 255) As UByte   ' URL index under a column
Dim Shared rurls(1 To ROWMAP_MAX) As String               ' "|url1|url2|" per row

' chat selection (history line index + text cell index, logical order)
Dim Shared sel_on As Byte
Dim Shared sel_buf As Long
Dim Shared sel_a_li As Long, sel_a_ci As Long
Dim Shared sel_b_li As Long, sel_b_ci As Long

Dim Shared menu_groups(0 To 5) As String
Dim Shared menu_items(Any) As String
Dim Shared menu_counts(0 To 5) As Long

' ---------------------------------------------------------------- layout
Sub ui_layout_calc()
    With lay
        .w = vt_cols()
        .h = vt_rows()
        .input_row = .h - 1
        .status_row = .h
        .topic_row = 0
        Dim is_chan As Byte = IIf(buf_valid(ui_active) AndAlso bufs(ui_active).kind = BK_CHANNEL, 1, 0)
        If cfg.show_topic AndAlso is_chan Then .topic_row = 2
        .top = IIf(.topic_row > 0, 3, 2)
        .bot = .h - 2
        .tree_on = cfg.show_tree
        .nl_on = IIf(cfg.show_nicklist AndAlso is_chan, 1, 0)
        Dim tw As Long = cfg.tree_width
        Dim nw As Long = cfg.nicklist_width
        If tw < 8 Then tw = 8
        If nw < 8 Then nw = 8
        ' keep at least 40 columns of chat
        If .nl_on AndAlso .w - IIf(.tree_on, tw + 1, 0) - (nw + 1) < 40 Then .nl_on = 0
        If .tree_on AndAlso .w - (tw + 1) < 40 Then .tree_on = 0
        .tree_x2 = IIf(.tree_on, tw, 0)
        .chat_x1 = IIf(.tree_on, tw + 2, 1)
        .nl_x1 = IIf(.nl_on, .w - nw + 1, .w + 1)
        .chat_x2 = IIf(.nl_on, .nl_x1 - 2, .w)
        .chat_w = .chat_x2 - .chat_x1 + 1
        .chat_h = .bot - .top + 1
        If .chat_h > ROWMAP_MAX Then .chat_h = ROWMAP_MAX
    End With
End Sub

' ---------------------------------------------------------------- window order
Sub ui_order_rebuild()
    ui_order_n = 0
    Dim c As Long
    Dim k As Long
    Dim i As Long
    Dim kinds(2) As Long = { BK_CHANNEL, BK_QUERY, BK_DCC }
    For c = -1 To CONN_MAX - 1
        If c >= 0 AndAlso conns(c).alive = 0 Then Continue For
        If c >= 0 AndAlso buf_valid(conns(c).status_buf) Then
            ui_order(ui_order_n) = conns(c).status_buf : ui_order_n += 1
        End If
        Dim kk As Long
        For kk = 0 To IIf(c >= 0, 2, 0)
            ' collect buffers of this conn/kind sorted by creation order
            Dim start As Long = ui_order_n
            For i = 0 To BUF_MAX - 1
                If bufs(i).alive = 0 OrElse bufs(i).conn_id <> c Then Continue For
                If c >= 0 AndAlso bufs(i).kind <> kinds(kk) Then Continue For
                If c < 0 AndAlso bufs(i).kind = BK_STATUS Then Continue For
                ' insertion by seq
                Dim j As Long = ui_order_n
                While j > start AndAlso ui_seq(ui_order(j - 1)) > ui_seq(i)
                    ui_order(j) = ui_order(j - 1)
                    j -= 1
                Wend
                ui_order(j) = i
                ui_order_n += 1
            Next i
        Next kk
    Next c
    ui_order_ok = 1
End Sub

Function ui_order_pos(id As Long) As Long
    If ui_order_ok = 0 Then ui_order_rebuild()
    Dim i As Long
    For i = 0 To ui_order_n - 1
        If ui_order(i) = id Then Return i
    Next i
    Return -1
End Function

' ---------------------------------------------------------------- line styling
Private Function line_hidden(ByVal p As irc_line Ptr) As Byte
    If cfg.hide_joinpart = 0 Then Return 0
    Select Case p->kind
    Case LK_JOIN, LK_PART, LK_QUIT, LK_NICK
        If (p->flags And LF_SELF) Then Return 0
        If cfg.hide_joinpart = 2 Then Return 1
        If (p->flags And LF_NOISE) Then Return 1
    End Select
    Return 0
End Function

Private Sub line_colors(ByVal p As irc_line Ptr, ByRef pfg As UByte, ByRef pbg As UByte, ByRef tfg As UByte)
    pbg = th.bg
    tfg = th.fg
    Select Case p->kind
    Case LK_MSG
        If (p->flags And LF_SELF) Then
            pfg = th.own
        ElseIf cfg.colored_nicks Then
            pfg = nick_color(p->nick)
        Else
            pfg = th.fg
        End If
    Case LK_ACTION : pfg = th.action : tfg = th.action
    Case LK_NOTICE : pfg = th.notice
    Case LK_JOIN   : pfg = th.joinc : tfg = th.joinc
    Case LK_PART, LK_QUIT, LK_KICK : pfg = th.partc : tfg = th.partc
    Case LK_NICK, LK_MODE, LK_TOPIC, LK_INVITE : pfg = th.event : tfg = th.event
    Case LK_SERVER : pfg = th.server : tfg = th.server
    Case LK_ERROR  : pfg = th.errc : tfg = th.errc
    Case LK_WHOIS  : pfg = th.whois : tfg = IIf(p->prefix = "|", th.fg, th.whois)
    Case LK_CTCP   : pfg = th.ctcp : tfg = th.ctcp
    Case Else      : pfg = th.info : tfg = th.info
    End Select
    If (p->flags And LF_HISTORY) Then pfg = th.history : tfg = th.history
    If (p->flags And LF_HIGHLIGHT) Then pfg = th.hl_fg : pbg = th.hl_bg
End Sub

Function ui_stamp_width() As Long
    If cfg.show_time = 0 Then Return 0
    Return utf8_width(time_format(0, cfg.time_fmt)) + 1
End Function

' Is text cell ci of history line li inside the selection?
Private Function sel_contains(li As Long, ci As Long) As Byte
    If sel_on = 0 OrElse sel_buf <> ui_active Then Return 0
    Dim a_li As Long = sel_a_li, a_ci As Long = sel_a_ci
    Dim b_li As Long = sel_b_li, b_ci As Long = sel_b_ci
    If a_li > b_li OrElse (a_li = b_li AndAlso a_ci > b_ci) Then
        Swap a_li, b_li : Swap a_ci, b_ci
    End If
    If li < a_li OrElse li > b_li Then Return 0
    If li = a_li AndAlso ci < a_ci Then Return 0
    If li = b_li AndAlso ci > b_ci Then Return 0
    Return 1
End Function

' ---------------------------------------------------------------- chat
' Layout of one history line: cells + rows. Kept in statics for speed.
Dim Shared lc_cells() As ucell
Dim Shared lc_rows() As Long
Dim Shared lc_urls() As String
Dim Shared lc_url_n As Long
Dim Shared lc_n As Long
Dim Shared lc_nrows As Long
Dim Shared lc_indent As Long
Dim Shared lc_prefix_w As Long

Private Sub layout_line(ByVal p As irc_line Ptr)
    Dim pfg As UByte, pbg As UByte, tfg As UByte
    line_colors(p, pfg, pbg, tfg)
    Dim sw As Long = ui_stamp_width()
    Dim pw As Long = utf8_width(p->prefix)
    lc_prefix_w = IIf(pw < cfg.nick_width, cfg.nick_width, pw)
    If cfg.nick_width <= 0 Then lc_prefix_w = pw
    lc_indent = sw + lc_prefix_w + IIf(lc_prefix_w > 0, 1, 0)
    If lc_indent > lay.chat_w \ 2 Then lc_indent = sw + 2
    Dim textw As Long = lay.chat_w - lc_indent
    If textw < 10 Then textw = 10
    lc_n = text_cells(p->text, tfg, th.bg, lc_cells(), cfg.strip_colors)
    lc_url_n = text_find_urls(lc_cells(), lc_n, lc_urls())
    lc_nrows = text_wrap(lc_cells(), lc_n, textw, lc_rows())
End Sub

' Draw row r (0-based) of the line laid out by layout_line at screen row y.
Private Sub draw_line_row(ByVal p As irc_line Ptr, li As Long, r As Long, y As Long)
    Dim pfg As UByte, pbg As UByte, tfg As UByte
    line_colors(p, pfg, pbg, tfg)
    Dim x As Long = lay.chat_x1
    Dim ri As Long = y - lay.top + 1
    rmap(ri).li = li
    rmap(ri).serial = p->serial
    rmap(ri).first = IIf(r = 0, 1, 0)
    rmap(ri).nick = p->nick
    rmap(ri).nick_x1 = 0 : rmap(ri).nick_x2 = -1
    rurls(ri) = "|"
    Dim cc As Long
    For cc = 0 To 255
        rcol_cell(ri, cc) = -1
        rcol_url(ri, cc) = 0
    Next cc
    If r = 0 Then
        If cfg.show_time Then
            x += ui_text(x, y, ui_stamp_width() - 1, time_format(p->t, cfg.time_fmt), th.stamp, th.bg)
            vt_set_cell(x, y, 32, th.fg, th.bg) : x += 1
        End If
        Dim pw As Long = utf8_width(p->prefix)
        Dim pad As Long = lc_prefix_w - pw
        While pad > 0
            vt_set_cell(x, y, 32, th.fg, th.bg) : x += 1 : pad -= 1
        Wend
        rmap(ri).nick_x1 = x
        x += ui_text(x, y, lay.chat_x2 - x + 1, p->prefix, pfg, pbg)
        rmap(ri).nick_x2 = x - 1
        If lc_prefix_w > 0 Then vt_set_cell(x, y, 32, th.fg, th.bg) : x += 1
        x = lay.chat_x1 + lc_indent
    Else
        x = lay.chat_x1 + lc_indent
    End If
    rmap(ri).tx = x
    Dim a As Long = lc_rows(r)
    Dim b As Long = lc_rows(r + 1)
    ' copy the row so bidi mirroring does not change the layout cache
    Static rowc() As ucell
    If b - a > 0 Then
        ReDim rowc(0 To b - a - 1)
        Dim k As Long
        For k = 0 To b - a - 1
            rowc(k) = lc_cells(a + k)
        Next k
        Static vis() As Long
        text_row_visual(rowc(), 0, b - a, vis())
        For k = 0 To b - a - 1
            Dim ci As Long = vis(k)
            If x + rowc(ci).w - 1 > lay.chat_x2 Then Exit For
            Dim fg As UByte = rowc(ci).fg
            Dim bg As UByte = rowc(ci).bg
            Dim at As UByte = rowc(ci).attr
            If rowc(ci).url Then
                fg = th.link : at Or= VT_ATTR_UNDERLINE
            End If
            If sel_contains(li, a + ci) Then fg = th.sel_fg : bg = th.sel_bg
            Dim col0 As Long = x - lay.chat_x1
            If col0 >= 0 AndAlso col0 <= 255 Then
                rcol_cell(ri, col0) = a + ci
                rcol_url(ri, col0) = IIf(rowc(ci).url > 255, 0, rowc(ci).url)
                If rowc(ci).w = 2 AndAlso col0 < 255 Then rcol_cell(ri, col0 + 1) = a + ci : rcol_url(ri, col0 + 1) = rcol_url(ri, col0)
            End If
            x += ui_put(x, y, rowc(ci).cp, fg, bg, at, rowc(ci).w)
        Next k
    End If
    ' remember the URLs of this line (rcol_url holds their 1-based index)
    Dim u As Long
    For u = 1 To lc_url_n
        rurls(ri) &= lc_urls(u) & "|"
    Next u
    While x <= lay.chat_x2
        vt_set_cell(x, y, 32, th.fg, th.bg) : x += 1
    Wend
End Sub

' URL number u (1-based) of chat row ri.
Function rmap_url(ri As Long, u As Long) As String
    Dim a() As String
    Dim n As Long = str_split(rurls(ri), "|", a())
    If u >= 1 AndAlso u < n Then Return a(u)
    Return ""
End Function

Sub render_chat()
    Dim y As Long
    For y = 1 To lay.chat_h
        rmap(y).li = -1 : rmap(y).first = 0 : rmap(y).nick = "" : rurls(y) = "|"
        rmap(y).nick_x1 = 0 : rmap(y).nick_x2 = -1
    Next y
    ui_fill(lay.chat_x1, lay.top, lay.chat_x2, lay.bot, th.fg, th.bg)
    Dim id As Long = ui_active
    If buf_valid(id) = 0 Then
        ui_text(lay.chat_x1 + 2, lay.top + 1, lay.chat_w - 4, "vtirc-ng " & VTIRC_VERSION, th.info, th.bg)
        ui_text(lay.chat_x1 + 2, lay.top + 3, lay.chat_w - 4, "Press F2 to open the network list and connect.", th.fg, th.bg)
        Exit Sub
    End If
    Dim skip As Long = bufs(id).scroll
    Dim yy As Long = lay.bot
    Dim li As Long = bufs(id).hist_count - 1
    Dim marker As LongInt = bufs(id).marker
    Dim newest As LongInt = 0
    If bufs(id).hist_count > 0 Then newest = buf_line(id, bufs(id).hist_count - 1)->serial
    Dim marker_drawn As Byte = 0
    Dim total_rows As Long = 0
    While li >= 0 AndAlso yy >= lay.top
        Dim p As irc_line Ptr = buf_line(id, li)
        ' marker line goes above the first unread line
        If marker_drawn = 0 AndAlso marker > 0 AndAlso p->serial = marker AndAlso marker < newest Then
            marker_drawn = 1
            If skip > 0 Then
                skip -= 1
            Else
                Dim mx As Long
                For mx = lay.chat_x1 To lay.chat_x2
                    vt_set_cell_ex(mx, yy, &h2500, th.marker, th.bg)
                Next mx
                yy -= 1
                If yy < lay.top Then Exit While
            End If
        End If
        If line_hidden(p) = 0 Then
            layout_line(p)
            Dim r As Long
            For r = lc_nrows - 1 To 0 Step -1
                If skip > 0 Then
                    skip -= 1
                Else
                    draw_line_row(p, li, r, yy)
                    yy -= 1
                    If yy < lay.top Then Exit For
                End If
            Next r
        End If
        li -= 1
    Wend
    ' scrolled past the oldest line: clamp and redraw next frame
    If li < 0 AndAlso skip > 0 Then
        bufs(id).scroll -= skip
        If bufs(id).scroll < 0 Then bufs(id).scroll = 0
        ui_dirty = 1
    End If
End Sub

' ---------------------------------------------------------------- panes
Function ui_buf_label(id As Long) As String
    If buf_valid(id) = 0 Then Return ""
    Return bufs(id).name
End Function

Sub render_tree()
    If lay.tree_on = 0 Then Exit Sub
    If ui_order_ok = 0 Then ui_order_rebuild()
    Dim h As Long = lay.chat_h
    Dim pos_ As Long = ui_order_pos(ui_active)
    If pos_ >= 0 Then
        If pos_ < tree_top Then tree_top = pos_
        If pos_ >= tree_top + h Then tree_top = pos_ - h + 1
    End If
    If tree_top > ui_order_n - h Then tree_top = ui_order_n - h
    If tree_top < 0 Then tree_top = 0
    Dim y As Long
    For y = 0 To h - 1
        Dim row As Long = lay.top + y
        ui_fill(1, row, lay.tree_x2, row, th.tree_fg, th.tree_bg)
        Dim k As Long = tree_top + y
        If k >= ui_order_n Then Continue For
        Dim id As Long = ui_order(k)
        Dim fg As UByte = th.tree_fg
        Dim bg As UByte = th.tree_bg
        Dim label As String
        Dim indent As Long = 0
        If bufs(id).kind = BK_STATUS Then
            label = bufs(id).name
            Dim c As Long = bufs(id).conn_id
            fg = IIf(conn_online(c), th.tree_net, th.off)
        Else
            indent = 1
            label = bufs(id).name
            If bufs(id).kind = BK_CHANNEL AndAlso bufs(id).joined = 0 Then fg = th.off
        End If
        Select Case bufs(id).activity
        Case ACT_EVENT     : fg = th.act_event
        Case ACT_MSG       : fg = th.act_msg
        Case ACT_HIGHLIGHT : fg = th.act_hl
        End Select
        If id = ui_active Then fg = th.tree_act_fg : bg = th.tree_act_bg
        ui_fill(1, row, lay.tree_x2, row, fg, bg)
        Dim num As String = IIf(k < 9, LTrim(Str(k + 1)), IIf(k = 9, "0", " "))
        Dim x As Long = 1
        x += ui_text(x, row, 1, num, IIf(id = ui_active, fg, th.stamp), bg)
        x += indent + 1
        Dim tail As String = ""
        If bufs(id).highlights > 0 AndAlso id <> ui_active Then
            tail = LTrim(Str(bufs(id).highlights)) & "!"
        ElseIf bufs(id).unread > 0 AndAlso id <> ui_active Then
            tail = LTrim(Str(bufs(id).unread))
        End If
        Dim room As Long = lay.tree_x2 - x + 1 - IIf(Len(tail) > 0, Len(tail) + 1, 0)
        ui_text(x, row, room, label, fg, bg, IIf(bufs(id).activity = ACT_HIGHLIGHT AndAlso id <> ui_active, VT_ATTR_BOLD, 0))
        If Len(tail) > 0 Then ui_text(lay.tree_x2 - Len(tail) + 1, row, Len(tail), tail, IIf(id = ui_active, fg, th.act_hl), bg)
    Next y
    ' separator
    For y = lay.top To lay.bot
        vt_set_cell(lay.tree_x2 + 1, y, 179, th.sep, th.bg)
    Next y
End Sub

Sub render_nicklist()
    If lay.nl_on = 0 Then Exit Sub
    Dim id As Long = ui_active
    Dim c As Long = bufs(id).conn_id
    Dim pc As String = IIf(conn_valid(c), conns(c).prefix_chars, "@+")
    user_sort(id, pc)
    Dim x1 As Long = lay.nl_x1
    Dim x2 As Long = lay.w
    Dim y As Long
    For y = lay.top To lay.bot
        vt_set_cell(x1 - 1, y, 179, th.sep, th.bg)
    Next y
    ' header: user count
    Dim ops As Long = 0
    Dim i As Long
    For i = 0 To bufs(id).user_count - 1
        Dim p1 As String = Left(bufs(id).users(i).pfx, 1)
        If Len(p1) > 0 AndAlso p1 <> "+" Then ops += 1
    Next i
    ui_fill(x1, lay.top, x2, lay.top, th.bar_fg, th.bar_bg)
    ui_text(x1, lay.top, x2 - x1 + 1, " " & bufs(id).user_count & " users, " & ops & " ops", th.bar_fg, th.bar_bg)
    Dim h As Long = lay.bot - lay.top
    Dim n As Long = bufs(id).user_count
    If nl_top > n - h Then nl_top = n - h
    If nl_top < 0 Then nl_top = 0
    For y = 0 To h - 1
        Dim row As Long = lay.top + 1 + y
        ui_fill(x1, row, x2, row, th.nl_fg, th.nl_bg)
        Dim k As Long = nl_top + y
        If k >= n Then Continue For
        Dim ui As Long = bufs(id).sorted(k)
        Dim fg As UByte = th.nl_fg
        Dim bg As UByte = th.nl_bg
        Dim sym As String = Left(bufs(id).users(ui).pfx, 1)
        If sym = "+" Then
            fg = th.nl_voice
        ElseIf Len(sym) > 0 Then
            fg = th.nl_op
        End If
        If bufs(id).users(ui).away Then fg = th.nl_away
        If k = nl_sel Then Swap fg, bg
        ui_fill(x1, row, x2, row, fg, bg)
        ui_text(x1, row, 1, IIf(Len(sym) > 0, sym, " "), fg, bg)
        ui_text(x1 + 1, row, x2 - x1, bufs(id).users(ui).nick, fg, bg)
    Next y
End Sub

Sub render_topic()
    If lay.topic_row = 0 Then Exit Sub
    Dim id As Long = ui_active
    ui_fill(1, lay.topic_row, lay.w, lay.topic_row, th.bar_fg, th.bar_bg)
    Dim modes As String = ""
    If Len(bufs(id).chmodes) > 0 Then modes = " [+" & bufs(id).chmodes & IIf(Len(bufs(id).chlimit) > 0, " " & bufs(id).chlimit, "") & "]"
    Dim x As Long = 2
    x += ui_text(x, lay.topic_row, lay.w - 2, bufs(id).name & modes & ": ", th.bar_hi, th.bar_bg)
    ui_text(x, lay.topic_row, lay.w - x, irc_strip_format(bufs(id).topic), th.bar_fg, th.bar_bg)
End Sub

' irssi-style status bar
Sub render_status()
    Dim row As Long = lay.status_row
    ui_fill(1, row, lay.w, row, th.bar_fg, th.bar_bg)
    Dim x As Long = 1
    Dim id As Long = ui_active
    Dim c As Long = IIf(buf_valid(id), bufs(id).conn_id, -1)
    #Macro SEG(txt, col)
        x += ui_text(x, row, lay.w - x + 1, txt, col, th.bar_bg)
    #EndMacro
    SEG("[" & time_format(time_now(), "%H:%M") & "] ", th.bar_fg)
    If conn_valid(c) Then
        Dim nk As String = conns(c).nick
        If Len(conns(c).umodes) > 0 Then nk &= "(+" & conns(c).umodes & ")"
        SEG("[" & nk & "] ", th.bar_fg)
        If conns(c).away Then SEG("[away] ", th.bar_hi)
    End If
    If buf_valid(id) Then
        Dim wn As Long = ui_order_pos(id) + 1
        Dim nm As String = IIf(conn_valid(c), conns(c).name & IIf(bufs(id).kind <> BK_STATUS, "/" & bufs(id).name, ""), bufs(id).name)
        SEG("[" & wn & ":" & nm & "] ", th.bar_fg)
    End If
    If conn_valid(c) Then
        Select Case conns(c).st
        Case CS_ONLINE
            If conns(c).lag > 1 Then SEG("[lag " & LTrim(Str(CLng(conns(c).lag * 10) / 10)) & "s] ", th.bar_hi)
            If conns(c).tls <> 0 Then SEG("[TLS] ", th.bar_fg)
        Case CS_CONNECTING, CS_REGISTERING : SEG("[connecting] ", th.bar_hi)
        Case CS_WAIT_RECONNECT             : SEG("[reconnecting] ", th.bar_hi)
        Case Else                          : SEG("[offline] ", th.bar_hi)
        End Select
    End If
    ' activity: numbers of windows with news
    Dim act As String = ""
    Dim k As Long
    If ui_order_ok = 0 Then ui_order_rebuild()
    For k = 0 To ui_order_n - 1
        Dim b As Long = ui_order(k)
        If b <> id AndAlso bufs(b).activity >= ACT_MSG Then act &= IIf(Len(act) > 0, ",", "") & (k + 1)
    Next k
    If Len(act) > 0 Then SEG("[Act: " & act & "] ", th.bar_hi)
    If buf_valid(id) AndAlso bufs(id).scroll > 0 Then
        ui_text(lay.w - 9, row, 9, "-- MORE --", th.bar_hi, th.bar_bg)
    End If
End Sub

Sub render_menu()
    vt_tui_menubar_draw(1, menu_groups())
    Dim t As String = VTIRC_NAME & " " & VTIRC_VERSION & " "
    ui_text(lay.w - Len(t) + 1, 1, Len(t), t, th.bar_fg, th.bar_bg)
End Sub

Declare Sub input_render()

Sub render_all()
    ui_layout_calc()
    render_menu()
    render_topic()
    render_tree()
    render_chat()
    render_nicklist()
    input_render()
    render_status()
    ui_dirty = 0
End Sub
