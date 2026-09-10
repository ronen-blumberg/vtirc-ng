' vtirc.bas -- VTIRC minimal IRC client built on libvt
' FreeBASIC 1.10.1 | libvt 1.9+ | Windows + Linux + Mac
' To compile for Mac, define __FB_MAC__
#cmdline "-s gui -w all -gen gcc -O 2"

#Ifndef __FB_MAC__
    #Define IRC_LINUX_NOTIFY
#Endif

#Define VT_USE_NET
#Define VT_USE_SORT
#Define VT_USE_TUI
#Include Once "vt/vt.bi"
#Include Once "vtirc.bi"

#ifndef __FB_WIN32__
#ifdef IRC_LINUX_NOTIFY
Sub linux_sound_init()
    Dim candidates(1) As String
    candidates(0) = "/usr/share/sounds/freedesktop/stereo/message-new-instant.oga"
    candidates(1) = "/usr/share/sounds/freedesktop/stereo/bell.oga"
    Dim snd_file As String
    Dim i        As Long
    For i = 0 To 1
        If vt_file_exists(candidates(i)) Then snd_file = candidates(i) : Exit For
    Next i
    If Len(snd_file) = 0 Then 
        g_snd_cmd = ""
        Exit Sub   ' no file -> fallback to BEEP
    Endif

    If Shell("which paplay >/dev/null 2>&1") = 0 Then
        g_snd_cmd = "paplay " & snd_file & " >/dev/null 2>&1 &"
    ElseIf Shell("which aplay >/dev/null 2>&1") = 0 Then
        g_snd_cmd = "aplay "  & snd_file & " >/dev/null 2>&1 &"
    Else
        g_snd_cmd = ""
    End If
End Sub

Sub linux_play_sound()
    If Len(g_snd_cmd) > 0 Then
        Shell g_snd_cmd
    Else
        Beep
    End If
End Sub

Function x11_find_toplevel(dpy As Display Ptr, srch As Const ZString Ptr) As Window
    Dim prop As ULong = XInternAtom(dpy, "_NET_CLIENT_LIST", 1)
    If prop = 0 Then Return 0

    Dim actual_type As ULong
    Dim actual_fmt  As Long
    Dim nitems      As ULong
    Dim bytes_after As ULong
    Dim win_data    As UByte Ptr = 0

    If XGetWindowProperty(dpy, DefaultRootWindow(dpy), prop, _
                          0, 65536, 0, 33, _
                          Cast(Any Ptr, @actual_type), @actual_fmt, _
                          Cast(Any Ptr, @nitems), _
                          Cast(Any Ptr, @bytes_after), _
                          @win_data) <> 0 Then
        Return 0
    End If
    If win_data = 0 Then Return 0

    Dim win_list As ULong Ptr = Cast(ULong Ptr, win_data)
    Dim result   As Window = 0
    Dim i        As ULong
    Dim wname    As ZString Ptr
    For i = 0 To nitems - 1
        If XFetchName(dpy, win_list[i], @wname) <> 0 AndAlso wname <> 0 Then
            If *wname = *srch Then
                result = win_list[i]
                XFree(wname)
                Exit For
            End If
            XFree(wname)
        End If
    Next i
    XFree(win_data)
    Return result
End Function

Sub x11_demand_attention(title As String)
    Dim dpy As Display Ptr = XOpenDisplay(0)
    If dpy = 0 Then Exit Sub

    Dim target As Window = x11_find_toplevel(dpy, title)
    If target = 0 Then XCloseDisplay(dpy) : Exit Sub

    Dim wm_state As ULong = XInternAtom(dpy, "_NET_WM_STATE",                  0)
    Dim demands  As ULong = XInternAtom(dpy, "_NET_WM_STATE_DEMANDS_ATTENTION", 0)

    Dim ev As XEvent
    Clear ev, 0, SizeOf(XEvent)
    With ev.xclient
        .type         = ClientMessage
        .display      = dpy
        .window       = target
        .message_type = wm_state
        .format       = 32
        .data.l(0)    = 1
        .data.l(1)    = Cast(Long, demands)
        .data.l(2)    = 0
    End With

    XSendEvent(dpy, DefaultRootWindow(dpy), 0, _
               SubstructureRedirectMask Or SubstructureNotifyMask, @ev)
    XFlush(dpy)
    XCloseDisplay(dpy)
End Sub
#endif
#endif

' Close callback
Function on_close() As Byte
    quit_flag = 1
    Return 1
End Function

Sub check_resize()
    Dim nc As Long
    Dim nr As Long
    If vt_screeninfo(nc, nr) Then
        If nc >= MIN_SCREEN_COLS AndAlso nr >= MIN_SCREEN_ROWS Then
            vt_width(nc, nr)
            g_screen_cols = vt_cols()
            g_screen_rows = vt_rows()
            screen_relayout()
            df_hist  = 1
            df_pane  = 1
            df_input = 1
        End If
    End If
End Sub

Sub dialog_lock_size()
    Dim pw As Long
    Dim ph As Long
    _VT_DRV_GetWindowSize(vt_internal.sdl_window, @pw, @ph)
    vt_internal.min_win_w = pw
    vt_internal.min_win_h = ph
    vt_internal.max_win_w = pw
    vt_internal.max_win_h = ph
    _VT_DRV_SetWindowMinimumSize(vt_internal.sdl_window, pw, ph)
    _VT_DRV_SetWindowMaximumSize(vt_internal.sdl_window, pw, ph)
End Sub

Sub dialog_unlock_size()
    vt_screen_minimum(MIN_SCREEN_COLS, MIN_SCREEN_ROWS)
    vt_screen_maximum(0, 0)  ' 0 = unconstrained
End Sub

' Recalculate all screen-size-derived layout variables and resize the url_hit_map array. 
Sub screen_relayout()
    g_chat_bot_row  = g_screen_rows - 3
    g_chat_rows     = g_screen_rows - 4
    g_row_input     = g_screen_rows - 1
    g_row_status    = g_screen_rows
    g_chat_wide     = g_screen_cols - PANE_W - 1
    ReDim url_hit_map(g_chat_rows - 1)
    vt_view_print(CHAT_TOP_ROW, g_chat_bot_row + 1, CHAT_COL, g_screen_cols)
    cfg.screen_cols = g_screen_cols
    cfg.screen_rows = g_screen_rows
    Dim wi As Long
    For wi = 0 To win_count - 1
        hist_reflow(wi)
    Next wi
End Sub

' Colour scheme
Sub scheme_apply()
    Select Case cfg.scheme
    Case 1  ' Classic
        col_bg_main   = VT_BLACK
        col_fg_body   = VT_LIGHT_GREY
        col_fg_own    = VT_WHITE
        col_fg_other  = VT_YELLOW
        col_fg_sys    = VT_GREEN
        col_bar_fg    = VT_WHITE
        col_bar_bg    = VT_BLUE
        col_fg_link   = VT_BRIGHT_CYAN
        col_fg_notice = VT_BRIGHT_GREEN

    Case 2  ' Light
        col_bg_main   = VT_WHITE
        col_fg_body   = VT_BLACK
        col_fg_own    = VT_BLACK
        col_fg_other  = VT_BLUE
        col_fg_sys    = VT_MAGENTA
        col_bar_fg    = VT_BLACK
        col_bar_bg    = VT_CYAN
        col_fg_link   = VT_CYAN
        col_fg_notice = VT_BROWN

    Case Else  ' Dark (0, default)
        col_bg_main   = VT_BLACK
        col_fg_body   = VT_LIGHT_GREY
        col_fg_own    = VT_LIGHT_GREY
        col_fg_other  = VT_BRIGHT_BLUE
        col_fg_sys    = VT_RED
        col_bar_fg    = VT_WHITE
        col_bar_bg    = VT_DARK_GREY
        col_fg_link   = VT_BRIGHT_CYAN
        col_fg_notice = VT_GREEN

    End Select

    vt_tui_theme (col_fg_body  , col_bg_main, _    ' window body
                  VT_WHITE  , VT_BLUE, _           ' title bar
                  col_bar_fg, col_bar_bg, _        ' bar/menu
                  VT_BLACK  , VT_LIGHT_GREY, _     ' button
                  VT_BLACK  , VT_LIGHT_GREY, _     ' dialogue
                  col_fg_body, col_bg_main )       ' input field

End Sub

Function nick_color(nick_str As String) As UByte
    Dim h As ULong = 5381
    Dim i As Long
    For i = 1 To Len(nick_str)
        h = ((h Shl 5) + h) Xor Asc(nick_str, i)
    Next i
    Static pal(0 To 5) As UByte = { _
        VT_BRIGHT_CYAN, VT_BROWN, VT_BRIGHT_GREEN, _
        VT_BRIGHT_MAGENTA, VT_BRIGHT_BLUE, VT_BRIGHT_RED }
    Return pal(h Mod 6)
End Function

' -----------------------------------------------------------------------------
' Encoding: CP437 <-> UTF-8
' IRC wire protocol uses UTF-8; libvt stores strings as CP437 internally.
' cp437_to_utf8()   -- outgoing: convert user input before irc_send
' utf8_to_cp437()   -- incoming: convert trail_str received from server
' -----------------------------------------------------------------------------

' -----------------------------------------------------------------------------
' Logging
' -----------------------------------------------------------------------------

' Shared file-append core -- open, write timestamped line, close.
Sub log_write_path(log_path As String, txt As String)
    Dim f As Long = FreeFile()
    Open log_path For Append As #f
    Print #f, "[" & Date() & " " & Time() & "] " & txt
    Close #f
End Sub

Sub log_write(ch_target As String, txt As String)
    If cfg.log_enabled = 0 Then Exit Sub
    If Len(cfg.server) = 0 OrElse Len(ch_target) = 0 Then Exit Sub
    Dim ch_safe As String = ch_target
    If Left(ch_safe, 1) = "#" Then ch_safe = Mid(ch_safe, 2)
    log_write_path(ExePath() & "/" & cfg.server & "_" & ch_safe & ".log", txt)
End Sub

Sub log_write_pm(tgt As String, txt As String)
    If cfg.log_pm = 0 Then Exit Sub
    If Len(cfg.server) = 0 OrElse Len(tgt) = 0 Then Exit Sub
    log_write_path(ExePath() & "/" & cfg.server & "_" & tgt & "_pm.log", txt)
End Sub

Function log_path_active() As String
    If win_count = 0 Then Return ""
    If wins(active_win).is_pm = 0 Then
        If cfg.log_enabled = 0 Then Return ""
        If Len(cfg.server) = 0 OrElse Len(wins(active_win).target) = 0 Then Return ""
        Dim ch_safe As String = wins(active_win).target
        If Left(ch_safe, 1) = "#" Then ch_safe = Mid(ch_safe, 2)
        Return ExePath() & "/" & cfg.server & "_" & ch_safe & ".log"
    Else
        If cfg.log_pm = 0 Then Return ""
        If Len(cfg.server) = 0 OrElse Len(wins(active_win).target) = 0 Then Return ""
        Return ExePath() & "/" & cfg.server & "_" & wins(active_win).target & "_pm.log"
    End If
End Function

' -----------------------------------------------------------------------------
' History  (ring buffer + word-wrap at append time)
' -----------------------------------------------------------------------------

' Low-level ring-buffer push: insert one already-wrapped line into the ring.
' No logging, no timestamps, no unread tracking -- callers handle those.
Sub win_ring_push(win_idx As Long, txt As String, col_fg As UByte, is_cont As Byte = 0, raw_txt As String = "")
    Dim slot As Long
    If wins(win_idx).hist_count < HISTORY_MAX Then
        slot = (wins(win_idx).hist_head + wins(win_idx).hist_count) Mod HISTORY_MAX
        wins(win_idx).history(slot).txt     = txt
        wins(win_idx).history(slot).col_fg  = col_fg
        wins(win_idx).history(slot).is_cont = is_cont
        wins(win_idx).history(slot).raw_txt = raw_txt
        wins(win_idx).hist_count += 1
    Else
        wins(win_idx).history(wins(win_idx).hist_head).txt     = txt
        wins(win_idx).history(wins(win_idx).hist_head).col_fg  = col_fg
        wins(win_idx).history(wins(win_idx).hist_head).is_cont = is_cont
        wins(win_idx).history(wins(win_idx).hist_head).raw_txt = raw_txt
        wins(win_idx).hist_head = (wins(win_idx).hist_head + 1) Mod HISTORY_MAX
    End If
End Sub

Sub win_hist_append(win_idx As Long, txt As String, col_fg As UByte)
    If win_idx < 0 OrElse win_idx >= win_count Then Exit Sub
    If wins(win_idx).is_pm = 0 Then
        If cfg.log_enabled Then log_write(wins(win_idx).target, irc_strip_colors(txt))
    ElseIf cfg.log_pm AndAlso wins(win_idx).is_pm Then
        log_write_pm(wins(win_idx).target, irc_strip_colors(txt))
    End If
    Dim disp_txt As String = txt
    If cfg.show_timestamps Then disp_txt = "[" & Left(Time(), 5) & "] " & txt
    Dim wrapped    As String = mirc_wordwrap(disp_txt, g_chat_wide)
    Dim parts()    As String
    Dim part_count As Long = vt_str_split(wrapped, Chr(10), parts())
    Dim i            As Long
    Dim first_pushed As Byte = 0
    For i = 0 To part_count - 1
        If Len(parts(i)) = 0 Then Continue For
        If first_pushed = 0 Then
            win_ring_push(win_idx, parts(i), col_fg, 0, disp_txt)
            first_pushed = 1
        Else
            win_ring_push(win_idx, parts(i), col_fg, 1, "")
        End If
    Next i
    If win_idx <> active_win Then
        wins(win_idx).unread = 1
        df_input = 1   ' unread indicator in status bar changed
        If wins(win_idx).is_pm Then pane_dirty = 1 : df_pane = 1  ' refresh * marker
    Else
        If wins(win_idx).top_line > 0 Then wins(win_idx).new_msgs = 1
        df_hist = 1    ' active window history grew
    End If
End Sub

Sub hist_append(txt As String, col_fg As UByte)
    If win_count = 0 Then Return
    win_hist_append(0, txt, col_fg)
End Sub

' -----------------------------------------------------------------------------
' win_hist_raw -- insert into ring buffer without logging or timestamp prefix.
' Used by log_load_tail so replayed lines are not re-logged and already carry
' their own [date time] prefix from the log file.
' -----------------------------------------------------------------------------
Sub win_hist_raw(win_idx As Long, txt As String, col_fg As UByte)
    If win_idx < 0 OrElse win_idx >= win_count Then Exit Sub
    Dim wrapped    As String = mirc_wordwrap(txt, g_chat_wide)
    Dim parts()    As String
    Dim part_count As Long = vt_str_split(wrapped, Chr(10), parts())
    Dim i            As Long
    Dim first_pushed As Byte = 0
    For i = 0 To part_count - 1
        If Len(parts(i)) = 0 Then Continue For
        If first_pushed = 0 Then
            win_ring_push(win_idx, parts(i), col_fg, 0, txt)
            first_pushed = 1
        Else
            win_ring_push(win_idx, parts(i), col_fg, 1, "")
        End If
    Next i
End Sub

' -----------------------------------------------------------------------------
' log_load_tail -- read last n lines from channel log into win 0 on connect.
' Only runs when log_enabled=1 (log was being written) and the file exists.
' Lines are inserted raw (no timestamp re-added, no re-logging).
' -----------------------------------------------------------------------------
Sub log_load_tail(win_idx As Long, n As Long)
    If cfg.log_enabled = 0 Then Exit Sub
    If win_idx < 0 OrElse win_idx >= win_count Then Exit Sub
    If wins(win_idx).is_pm Then Exit Sub
    If Len(cfg.server) = 0 OrElse Len(wins(win_idx).target) = 0 Then Exit Sub
    Dim ch_safe  As String = wins(win_idx).target
    If Left(ch_safe, 1) = "#" Then ch_safe = Mid(ch_safe, 2)
    Dim log_path As String = ExePath() & "/" & cfg.server & "_" & ch_safe & ".log"
    If vt_file_exists(log_path) = 0 Then Exit Sub

    ' Ring buffer to capture last n lines without loading full file into memory
    ReDim tail_lines(n - 1) As String
    Dim ring_head As Long = 0
    Dim ring_cnt  As Long = 0
    Dim f         As Long = FreeFile()
    Dim ln        As String
    Open log_path For Input As #f
    Do While EOF(f) = 0
        Line Input #f, ln
        If Len(ln) > 0 Then
            tail_lines(ring_head) = ln
            ring_head = (ring_head + 1) Mod n
            If ring_cnt < n Then ring_cnt += 1
        End If
    Loop
    Close #f

    If ring_cnt = 0 Then Exit Sub

    Dim ring_start As Long = IIf(ring_cnt < n, 0, ring_head)
    win_hist_raw(win_idx, "--- Replaying last " & ring_cnt & " log lines ---", col_fg_sys)
    Dim i As Long
    For i = 0 To ring_cnt - 1
        win_hist_raw(win_idx, tail_lines((ring_start + i) Mod n), VT_DARK_GREY)
    Next i
    win_hist_raw(win_idx, "--- End of log ---", col_fg_sys)
End Sub

' -----------------------------------------------------------------------------
' Config
' -----------------------------------------------------------------------------
Sub cfg_defaults()
    cfg.server          = "irc.libera.chat"
    cfg.port            = 6667
    cfg.channel         = "#freebasic"
    cfg.nick            = "VTIRCuser" &Str(Int(Rnd*998)+1)
    cfg.password        = ""
    cfg.scheme          = 0
    cfg.log_enabled     = 0
    cfg.log_pm          = 0
    cfg.auto_reconnect  = 0
    cfg.show_timestamps = 1
    cfg.beep_notify     = 0
    cfg.nick_alt        = ""
    cfg.screen_cols     = 100
    cfg.screen_rows     = 40
    cfg.font_size       = 0
    cfg.renderer        = 0
End Sub

Function cfg_load() As Byte
    If vt_file_exists(cfg_file) = 0 Then Return 0
    Dim f       As Long = FreeFile()
    Dim ln      As String
    Dim sep_pos As Long
    Open cfg_file For Input As #f
    Do While( EOF(f) = 0 )
        Line Input #f, ln
        ln      = Trim(ln)
        sep_pos = InStr(ln, "=")
        If sep_pos = 0 Then Continue Do
        Dim cfg_key As String = LCase(Left(ln, sep_pos - 1))
        Dim cfg_val As String = Mid(ln, sep_pos + 1)
        Select Case cfg_key
        Case "server"          : cfg.server          = cfg_val
        Case "port"            : cfg.port            = Val(cfg_val)
        Case "channel"         : cfg.channel         = cfg_val
        Case "nick"            : cfg.nick            = cfg_val
        Case "password"        : cfg.password        = cfg_val
        Case "scheme"          : cfg.scheme          = Val(cfg_val)
        Case "log_enabled"     : cfg.log_enabled     = Val(cfg_val)
        Case "log_pm"          : cfg.log_pm          = Val(cfg_val)
        Case "auto_reconnect"  : cfg.auto_reconnect  = Val(cfg_val)
        Case "show_timestamps" : cfg.show_timestamps = Val(cfg_val)
        Case "beep_notify"     : cfg.beep_notify     = Val(cfg_val)
        Case "nick_alt"        : cfg.nick_alt        = cfg_val
        Case "screen_cols"     : cfg.screen_cols     = Val(cfg_val)
        Case "screen_rows"     : cfg.screen_rows     = Val(cfg_val)
        Case "font_size"       : cfg.font_size       = Val(cfg_val)
        Case "renderer"        : cfg.renderer        = Val(cfg_val)
        End Select
    Loop
    Close #f
    Return 1
End Function

Sub cfg_save()
    Dim f As Long = FreeFile()
    Open cfg_file For Output As #f
    Print #f, "server="          & cfg.server
    Print #f, "port="            & cfg.port
    Print #f, "channel="         & cfg.channel
    Print #f, "nick="            & cfg.nick
    Print #f, "password="        & cfg.password
    Print #f, "scheme="          & cfg.scheme
    Print #f, "log_enabled="     & cfg.log_enabled
    Print #f, "log_pm="          & cfg.log_pm
    Print #f, "auto_reconnect="  & cfg.auto_reconnect
    Print #f, "show_timestamps=" & cfg.show_timestamps
    Print #f, "beep_notify="     & cfg.beep_notify
    Print #f, "nick_alt="        & cfg.nick_alt
    Print #f, "screen_cols="     & cfg.screen_cols
    Print #f, "screen_rows="     & cfg.screen_rows
    Print #f, "font_size="       & cfg.font_size
    Print #f, "renderer="        & cfg.renderer
    Close #f
End Sub

' -----------------------------------------------------------------------------
' Pane: rebuild sorted snapshot of user_list into pane_items(), clamp sel
' Called lazily when pane_dirty = 1
' -----------------------------------------------------------------------------
Sub pane_refresh()
    pane_dirty = 0
    Dim uc As Long = wins(active_win).user_count
    If uc = 0 Then
        ReDim pane_items(0)
        ReDim pane_display_items(0)
        pane_items(0)         = ""
        pane_display_items(0) = ""
        pane_lb_st.sel      = 0
        pane_lb_st.top_item = 0
        Return
    End If
    ReDim pane_items(uc - 1)
    Dim i As Long
    For i = 0 To uc - 1
        pane_items(i) = wins(active_win).user_list(i)
    Next i
    vt_sort(pane_items(), VT_ASCENDING)
    If pane_lb_st.sel >= uc Then pane_lb_st.sel = uc - 1
    If pane_lb_st.sel < 0   Then pane_lb_st.sel = 0

    ' Build display copy: prefix "* " for nicks with an unread PM
    ReDim pane_display_items(uc - 1)
    Dim wi As Long
    For i = 0 To uc - 1
        Dim has_unread As Byte = 0
        For wi = 0 To win_count - 1
            If wins(wi).is_pm AndAlso wins(wi).unread AndAlso _
               LCase(wins(wi).target) = LCase(pane_items(i)) Then
                has_unread = 1 : Exit For
            End If
        Next wi
        pane_display_items(i) = IIf(has_unread, "* " & pane_items(i), pane_items(i))
    Next i
End Sub

' -----------------------------------------------------------------------------
' Menu bar
' -----------------------------------------------------------------------------
Sub update_window_title()
    Dim tgt As String = wins(active_win).target
    If Len(cfg.server) > 0 Then
        vt_title("VTIRC - " & cfg.server & _
                 IIf(Len(tgt) > 0, " / " & tgt, ""))
    Else
        vt_title("VTIRC " & IRC_VERSION)
    End If
End Sub

Sub menu_rebuild()
    menu_groups(0) = "IRC"
    menu_groups(1) = "Settings"
    menu_groups(2) = "Channel"
    menu_groups(3) = "Window"
    menu_groups(4) = "Help"

    menu_counts(MENU_IRC - 1)      = 2
    menu_counts(MENU_SETTINGS - 1) = 2
    menu_counts(MENU_CHANNEL - 1)  = 1
    menu_counts(MENU_WINDOW - 1)   = 1 + win_count
    menu_counts(MENU_HELP - 1)     = 3

    Dim total As Long = 0
    Dim gi    As Long
    For gi = 0 To 4
        total += menu_counts(gi)
    Next gi
    ReDim menu_items(total - 1)

    Dim idx As Long = 0
    menu_items(idx) = "Disconnect" : idx += 1
    menu_items(idx) = "Quit"       : idx += 1
    menu_items(idx) = "Server..."  : idx += 1
    menu_items(idx) = "General..."  : idx += 1
    menu_items(idx) = "Browser..."  : idx += 1
    menu_items(idx) = "Close"       : idx += 1
    Dim wi As Long
    For wi = 0 To win_count - 1
        If Len(wins(wi).target) > 0 Then
            menu_items(idx) = wins(wi).target
        Else
            menu_items(idx) = "(status)"
        End If
        idx += 1
    Next wi
    menu_items(idx) = "Quick Manual..." : idx += 1
    menu_items(idx) = "Github..."        : idx += 1
    menu_items(idx) = "About"            : idx += 1
End Sub

Sub menu_draw()
    vt_tui_menubar_draw(1, menu_groups())
End Sub

Function menu_handle(k As ULong) As Long
    Dim r As Long = vt_tui_menubar_handle(1, menu_groups(), menu_items(), menu_counts(), k)
    If r = 0 Then Return 0

    Select Case VT_TUI_MENU_GROUP(r)
    Case MENU_IRC
        Select Case VT_TUI_MENU_ITEM(r)
        Case MENU_IRC_DISCONNECT
            irc_disconnect()
        Case MENU_IRC_QUIT
            irc_disconnect()
            quit_flag = 1
        End Select

    Case MENU_SETTINGS
        Select Case VT_TUI_MENU_ITEM(r)
        Case MENU_SETTINGS_SERVER
            If connected Then
                vt_tui_dialog("Settings", "Disconnect first before changing server settings.", VT_DLG_OK)
            Else
                If settings_server_form() = 1 Then irc_connect()
            End If
        Case MENU_SETTINGS_GENERAL
            settings_common_form()
        End Select

    Case MENU_CHANNEL
        Select Case VT_TUI_MENU_ITEM(r)
        Case MENU_CHANNEL_BROWSER
            If connected Then
                channel_browser()
            Else
                hist_append("*** Connect to a server first to browse channels.", VT_BRIGHT_RED)
            End If
        End Select

    Case MENU_WINDOW
        Dim item_idx As Long = VT_TUI_MENU_ITEM(r)
        If item_idx = MENU_WINDOW_CLOSE Then
            If wins(active_win).is_pm = 0 AndAlso Len(wins(active_win).target) > 0 Then
                Dim close_tgt As String = wins(active_win).target
                irc_send("PART " & close_tgt)
                win_hist_append(active_win, "*** You left " & close_tgt, col_fg_sys)
                Dim c_arr()  As String
                Dim c_cnt    As Long = vt_str_split(cfg.channel, ",", c_arr())
                Dim c_new    As String
                Dim ci       As Long
                For ci = 0 To c_cnt - 1
                    If LCase(Trim(c_arr(ci))) <> LCase(close_tgt) Then
                        If Len(c_new) > 0 Then c_new &= ","
                        c_new &= Trim(c_arr(ci))
                    End If
                Next ci
                cfg.channel = c_new
                cfg_save()
                win_close(active_win)
            Else
                win_close(active_win)
            End If
        ElseIf item_idx >= MENU_WINDOW_FIRST Then
            Dim target_win As Long = item_idx - MENU_WINDOW_FIRST
            If target_win >= 0 AndAlso target_win < win_count Then
                active_win = target_win
                wins(active_win).unread = 0
                pane_dirty = 1
            End If
        End If

    Case MENU_HELP
        Select Case VT_TUI_MENU_ITEM(r)
        Case MENU_HELP_MANUAL
            help_window()
        Case MENU_HELP_GITHUB
            open_url("https://github.com/rbreitinger/vtirc")
        Case MENU_HELP_ABOUT
            vt_tui_dialog("About VTIRC", _
                "VTIRC v" & IRC_VERSION & Chr(10) & _
                "Written in FreeBASIC with libvt" & Chr(10) & _
                "(C) 2026 Rene Breitinger", _
                VT_DLG_OK)
        End Select
    End Select

    df_hist  = 1
    df_pane  = 1
    df_input = 1
    Return r
End Function

' -----------------------------------------------------------------------------
' mIRC color rendering helpers
' -----------------------------------------------------------------------------
Function mirc_to_vt(mirc_idx As Long) As UByte
    Static lut(15) As UByte = { _
        VT_WHITE,          _  ' 0  white
        VT_BLACK,          _  ' 1  black
        VT_BLUE,           _  ' 2  navy blue
        VT_GREEN,          _  ' 3  green
        VT_BRIGHT_RED,     _  ' 4  red
        VT_RED,            _  ' 5  maroon / dark red
        VT_MAGENTA,        _  ' 6  purple
        VT_BROWN,          _  ' 7  orange / brown
        VT_YELLOW,         _  ' 8  yellow
        VT_BRIGHT_GREEN,   _  ' 9  light green
        VT_CYAN,           _  ' 10 teal / dark cyan
        VT_BRIGHT_CYAN,    _  ' 11 light cyan
        VT_BRIGHT_BLUE,    _  ' 12 light blue
        VT_BRIGHT_MAGENTA, _  ' 13 pink / light magenta
        VT_DARK_GREY,      _  ' 14 grey
        VT_LIGHT_GREY }       ' 15 light grey
    If mirc_idx < 0  Then mirc_idx = 0
    If mirc_idx > 15 Then mirc_idx = 15
    Return lut(mirc_idx)
End Function

' -----------------------------------------------------------------------------
' mirc_skip_color -- advance ii past a Chr(3)[fg][,bg] sequence.
' On entry  ii points to the Chr(3) byte itself.
' On return ii is positioned on the first byte after the sequence.
' nfg / nbg receive the parsed colour indices, or -1 when absent.
' Used by mirc_visual_len, draw_mirc_line, and irc_strip_colors.
' (mirc_wordwrap has its own copy-to-accumulator variant and is not changed.)
' -----------------------------------------------------------------------------
Sub mirc_skip_color(txt As String, ByRef ii As Long, slen As Long, _
                    ByRef nfg As Long, ByRef nbg As Long)
    nfg = -1
    nbg = -1
    ii += 1   ' skip Chr(3) itself
    Dim dstr As String
    Dim d    As Long = 0
    Do While ii <= slen AndAlso d < 2
        If Asc(txt, ii) >= 48 AndAlso Asc(txt, ii) <= 57 Then
            dstr &= Chr(Asc(txt, ii)) : ii += 1 : d += 1
        Else
            Exit Do
        End If
    Loop
    If Len(dstr) > 0 Then nfg = Val(dstr)
    If ii <= slen AndAlso Asc(txt, ii) = 44 Then
        ii += 1 : dstr = "" : d = 0
        Do While ii <= slen AndAlso d < 2
            If Asc(txt, ii) >= 48 AndAlso Asc(txt, ii) <= 57 Then
                dstr &= Chr(Asc(txt, ii)) : ii += 1 : d += 1
            Else
                Exit Do
            End If
        Loop
        If Len(dstr) > 0 Then nbg = Val(dstr)
    End If
End Sub

Function mirc_visual_len(s As String) As Long
    Dim i      As Long = 1
    Dim slen   As Long = Len(s)
    Dim vlen   As Long = 0
    Dim ch     As UByte
    Dim dum_fg As Long
    Dim dum_bg As Long
    Do While i <= slen
        ch = Asc(s, i)
        Select Case ch
        Case 3
            mirc_skip_color(s, i, slen, dum_fg, dum_bg)
        Case 2, 15, 22, 31
            i += 1
        Case Else
            vlen += 1
            i    += 1
        End Select
    Loop
    Return vlen
End Function

Function mirc_wordwrap(txt As String, wid As Long) As String
    Dim result   As String
    Dim cur_line As String
    Dim cur_vis  As Long = 0
    Dim wrd      As String
    Dim wrd_vis  As Long = 0
    Dim i        As Long = 1
    Dim slen     As Long = Len(txt)
    Dim ch       As UByte
    Dim d        As Long

    Do While i <= slen
        ch = Asc(txt, i)
        Select Case ch
        Case 3
            wrd &= Chr(3) : i += 1 : d = 0
            Do While i <= slen AndAlso d < 2
                If Asc(txt, i) >= 48 AndAlso Asc(txt, i) <= 57 Then
                    wrd &= Chr(Asc(txt, i)) : i += 1 : d += 1
                Else
                    Exit Do
                End If
            Loop
            If i <= slen AndAlso Asc(txt, i) = 44 Then
                wrd &= "," : i += 1 : d = 0
                Do While i <= slen AndAlso d < 2
                    If Asc(txt, i) >= 48 AndAlso Asc(txt, i) <= 57 Then
                        wrd &= Chr(Asc(txt, i)) : i += 1 : d += 1
                    Else
                        Exit Do
                    End If
                Loop
            End If
        Case 2, 15, 22, 31
            wrd &= Chr(ch) : i += 1
        Case 32
            If cur_vis > 0 AndAlso cur_vis + wrd_vis > wid Then
                If Len(result) > 0 Then result &= Chr(10)
                result   &= cur_line
                cur_line  = wrd
                cur_vis   = wrd_vis
            Else
                cur_line &= wrd
                cur_vis  += wrd_vis
            End If
            wrd = "" : wrd_vis = 0
            If cur_vis < wid Then
                cur_line &= " " : cur_vis += 1
            End If
            i += 1
        Case Else
            wrd     &= Chr(ch)
            wrd_vis += 1
            i       += 1
        End Select
    Loop
    If Len(wrd) > 0 Then
        If cur_vis > 0 AndAlso cur_vis + wrd_vis > wid Then
            If Len(result) > 0 Then result &= Chr(10)
            result   &= cur_line
            cur_line  = wrd
        Else
            cur_line &= wrd
        End If
    End If
    If Len(cur_line) > 0 Then
        If Len(result) > 0 Then result &= Chr(10)
        result &= cur_line
    End If
    Return result
End Function

' Render one history line.  Starts at CHAT_COL, bounded by max_vis.
Sub draw_mirc_line(ln_row As Long, base_fg As UByte, base_bg As UByte, _
                   txt As String, max_vis As Long)
    Dim cur_fg  As UByte = base_fg
    Dim cur_bg  As UByte = base_bg
    Dim rev_vid As Byte  = 0
    Dim prt_buf As String
    Dim i       As Long  = 1
    Dim slen    As Long  = Len(txt)
    Dim vis     As Long  = 0
    Dim ch      As UByte
    Dim nfg     As Long
    Dim nbg     As Long

    vt_locate(ln_row, CHAT_COL)
    vt_color(cur_fg, cur_bg)

    Do While i <= slen AndAlso vis < max_vis
        ch = Asc(txt, i)
        Select Case ch
        Case 3
            If Len(prt_buf) > 0 Then vt_print(prt_buf) : prt_buf = ""
            mirc_skip_color(txt, i, slen, nfg, nbg)
            If nfg >= 0 Then
                cur_fg = mirc_to_vt(nfg)
            Else
                cur_fg = base_fg : cur_bg = base_bg
            End If
            If nbg >= 0 Then cur_bg = mirc_to_vt(nbg)
            If rev_vid Then vt_color(cur_bg, cur_fg) Else vt_color(cur_fg, cur_bg)
        Case 15
            If Len(prt_buf) > 0 Then vt_print(prt_buf) : prt_buf = ""
            cur_fg  = base_fg : cur_bg = base_bg : rev_vid = 0
            vt_color(cur_fg, cur_bg)
            i += 1
        Case 22
            If Len(prt_buf) > 0 Then vt_print(prt_buf) : prt_buf = ""
            rev_vid Xor= 1
            If rev_vid Then vt_color(cur_bg, cur_fg) Else vt_color(cur_fg, cur_bg)
            i += 1
        Case 2, 31
            i += 1
        Case Else
            prt_buf &= Chr(ch)
            vis     += 1
            i       += 1
        End Select
    Loop
    If Len(prt_buf) > 0 Then vt_print(prt_buf)
End Sub

' -----------------------------------------------------------------------------
' url_find_in_plain -- scan a colour-stripped line for the first http(s):// URL.
' Returns 1 on success; u_start and u_end are 1-based positions in plain_txt.
' -----------------------------------------------------------------------------
Function url_find_in_plain(plain_txt As String, ByRef u_start As Long, ByRef u_end As Long) As Byte
    Dim http_pos  As Long = InStr(plain_txt, "http://")
    Dim https_pos As Long = InStr(plain_txt, "https://")

    If http_pos = 0 AndAlso https_pos = 0 Then Return 0

    Dim srch As Long
    If http_pos = 0 Then
        srch = https_pos
    ElseIf https_pos = 0 Then
        srch = http_pos
    Else
        srch = IIf(http_pos < https_pos, http_pos, https_pos)
    End If

    u_start = srch
    Dim ii   As Long = srch
    Dim slen As Long = Len(plain_txt)
    Do While ii <= slen
        Dim uch As UByte = Asc(plain_txt, ii)
        If uch = 32 OrElse uch = 9 Then Exit Do   ' space or tab ends URL
        ii += 1
    Loop
    u_end = ii - 1

    If u_end < u_start Then Return 0
    Return 1
End Function

' -----------------------------------------------------------------------------
' open_url -- launch the system browser for url_txt.
'   Win32 : uses ShellExecuteEx  -- no cmd.exe spawn, no AV false-positive lag
'   Linux  : uses xdg-open &     -- detached so it never blocks the caller
' -----------------------------------------------------------------------------
Sub open_url(url_txt As String)
    If Len(url_txt) = 0 Then Exit Sub

    #Ifndef __FB_MAC__
        #Ifdef __FB_WIN32__
            Dim sei        As SHELLEXECUTEINFO
            Dim verb_z     As ZString * 5 = "open"
            Dim url_z      As String      = url_txt   ' local copy, guaranteed in scope

            sei.cbSize       = SizeOf(SHELLEXECUTEINFO)
            sei.fMask        = SEE_MASK_FLAG_NO_UI    ' suppress error dialog boxes
            sei.hwnd         = NULL
            sei.lpVerb       = @verb_z
            sei.lpFile       = StrPtr(url_z)          ' FB strings are null-terminated
            sei.lpParameters = NULL
            sei.lpDirectory  = NULL
            sei.nShow        = SW_SHOWNORMAL
            sei.hInstApp     = NULL

            ShellExecuteEx(@sei)
        #Else
            ' '&' detaches xdg-open so the call returns immediately
            Shell "xdg-open """ & url_txt & """ &"
        #Endif

    #Else 'mac
        ' '&' detaches xdg-open so the call returns immediately
        Shell "open """ & url_txt & """ &"
    #Endif
End Sub

' Flash taskbar and optionally beep on mention / new PM.
Sub notify_user()
    #ifdef __FB_WIN32__
        If cfg.beep_notify Then PlaySound(NOTIFY_SND, NULL, SND_ALIAS Or SND_ASYNC)
        Dim hwnd_self As HWND = FindWindowA(0, "VTIRC " & IRC_VERSION)
        If hwnd_self = 0 Then Exit Sub
        Dim fwi As FLASHWINFO
        fwi.cbSize    = SizeOf(FLASHWINFO)
        fwi.hwnd      = hwnd_self
        fwi.dwFlags   = FLASHW_ALL Or FLASHW_TIMERNOFG  ' flash taskbar+caption until we get focus
        fwi.uCount    = 3
        fwi.dwTimeout = 0
        FlashWindowEx(@fwi)
    #else
        #ifdef IRC_LINUX_NOTIFY
            If cfg.beep_notify Then linux_play_sound()
            x11_demand_attention("VTIRC " & IRC_VERSION)
        #else
            Beep
        #endif
    #endif
End Sub

' Re-wrap all history lines in a window to the current g_chat_wide.
' Called from screen_relayout whenever the terminal width changes.
Sub hist_reflow(win_idx As Long)
    Dim total As Long = wins(win_idx).hist_count
    If total = 0 Then Exit Sub

    ' Collect each logical message group: raw_txt + color of its first line.
    ' Continuation lines (is_cont=1) are skipped since raw_txt holds the full text.
    ReDim grp_raw(total - 1) As String
    ReDim grp_col(total - 1) As UByte
    Dim grp_count As Long = 0
    Dim i         As Long
    For i = 0 To total - 1
        Dim ri As Long = (wins(win_idx).hist_head + i) Mod HISTORY_MAX
        If wins(win_idx).history(ri).is_cont = 0 Then
            grp_raw(grp_count) = wins(win_idx).history(ri).raw_txt
            grp_col(grp_count) = wins(win_idx).history(ri).col_fg
            grp_count += 1
        End If
    Next i

    ' Reset ring buffer.
    wins(win_idx).hist_count = 0
    wins(win_idx).hist_head  = 0

    ' Re-wrap and re-push every group with the new width.
    For i = 0 To grp_count - 1
        If Len(grp_raw(i)) = 0 Then Continue For
        Dim wrapped    As String = mirc_wordwrap(grp_raw(i), g_chat_wide)
        Dim parts()    As String
        Dim part_count As Long   = vt_str_split(wrapped, Chr(10), parts())
        Dim first_pushed As Byte = 0
        Dim k As Long
        For k = 0 To part_count - 1
            If Len(parts(k)) = 0 Then Continue For
            If first_pushed = 0 Then
                win_ring_push(win_idx, parts(k), grp_col(i), 0, grp_raw(i))
                first_pushed = 1
            Else
                win_ring_push(win_idx, parts(k), grp_col(i), 1, "")
            End If
        Next k
    Next i

    ' Clamp scroll offset to the new buffer size.
    Dim max_tl As Long = wins(win_idx).hist_count - 1
    If max_tl < 0 Then max_tl = 0
    If wins(win_idx).top_line > max_tl Then wins(win_idx).top_line = max_tl
    If wins(win_idx).top_line = 0 Then wins(win_idx).new_msgs = 0
End Sub

Sub draw_history()
    Dim row      As Long
    Dim i        As Long
    Dim ri       As Long
    Dim txt_disp As String
    ' fill only the chat columns (leave pane columns untouched)
    vt_tui_rect_fill(CHAT_COL, CHAT_TOP_ROW, g_chat_wide, g_chat_rows, 32, VT_LIGHT_GREY, col_bg_main)
    Dim w_hc  As Long = wins(active_win).hist_count
    Dim w_hh  As Long = wins(active_win).hist_head
    Dim w_tl  As Long = wins(active_win).top_line
    Dim first As Long = w_hc - g_chat_rows - w_tl
    If first < 0 Then first = 0
    Dim last  As Long = w_hc - 1 - w_tl
    If last < 0 Then Return
    row = CHAT_TOP_ROW
    For i = first To last
        If row > g_chat_bot_row Then Exit For
        ri       = (w_hh + i) Mod HISTORY_MAX
        txt_disp = wins(active_win).history(ri).txt

        draw_mirc_line(row, wins(active_win).history(ri).col_fg, col_bg_main, txt_disp, g_chat_wide)

        ' --- URL hit-map update -----------------------------------------------
        Dim hm_idx As Long = row - CHAT_TOP_ROW
        url_hit_map(hm_idx).url_str   = ""
        url_hit_map(hm_idx).col_start = 0
        url_hit_map(hm_idx).col_end   = 0

        Dim plain_ln As String = irc_strip_colors(txt_disp)
        Dim pu_s     As Long
        Dim pu_e     As Long
        If url_find_in_plain(plain_ln, pu_s, pu_e) Then
            Dim sc_s As Long = CHAT_COL + pu_s - 1
            Dim sc_e As Long = CHAT_COL + pu_e - 1
            If sc_e > CHAT_COL + g_chat_wide - 1 Then sc_e = CHAT_COL + g_chat_wide - 1
            If sc_s <= sc_e Then
                url_hit_map(hm_idx).col_start = sc_s
                url_hit_map(hm_idx).col_end   = sc_e
                url_hit_map(hm_idx).url_str   = Mid(plain_ln, pu_s, pu_e - pu_s + 1)
                vt_color(col_fg_link, col_bg_main)
                vt_locate(row, sc_s)
                vt_print(Mid(plain_ln, pu_s, pu_e - pu_s + 1))
            End If
        End If

        row += 1
    Next i
End Sub

Sub draw_status()
    Dim hint     As String
    Dim uw_i     As Long
    Dim pm_alert As String = ""
    For uw_i = 0 To win_count - 1
        If uw_i <> active_win AndAlso wins(uw_i).unread Then
            If Len(pm_alert) = 0 Then pm_alert = " [Unread:"
            pm_alert &= " " & wins(uw_i).target
        End If
    Next uw_i
    If Len(pm_alert) > 0 Then
        pm_alert &= "] Ctrl+Tab"
        hint      = pm_alert
    End If
    If is_afk Then
        hint &= " [AFK: " & Left(afk_msg, 10) & "]"
    End If
    If wins(active_win).top_line > 0 AndAlso wins(active_win).new_msgs Then
        hint &= " (new messages below)  PgDn / End = Bottom  |  F1=Help"
    Else
        hint &= " F1=Help"
    End If
    Select Case focus_zone
    Case FOCUS_HISTORY : hint &= "  [HIST]"
    Case FOCUS_PANE    : hint &= "  [PANE]"
    End Select

    ' [LOG] label: fixed at left; shown only when logging applies to this window type
    Dim show_log As Byte = 0
    If win_count > 0 Then
        If wins(active_win).is_pm = 0 Then
            If cfg.log_enabled Then show_log = 1
        Else
            If cfg.log_pm Then show_log = 1
        End If
    End If
    Dim log_label As String
    If show_log Then
        log_label     = "[LOG]"
        g_log_col_end = Len(log_label)
    Else
        log_label     = ""
        g_log_col_end = 0
    End If

    vt_color(col_bar_fg, col_bar_bg)
    vt_locate(g_row_status, 1)
    vt_print(vt_str_pad_right(log_label & hint, g_screen_cols, " "))
End Sub

Sub draw_input()
    Dim prefix  As String = cfg.nick & "> "
    Dim pfx_len As Long   = Len(prefix)
    ' horizontal separator between history and input line
    vt_tui_hline(PANE_SEP+1, g_row_input-1, g_chat_wide, col_fg_sys, col_bg_main)
    vt_color(col_fg_body, col_bg_main)
    vt_locate(g_row_input, CHAT_COL)
    vt_print(prefix)
    input_form(0).x   = CHAT_COL + pfx_len
    input_form(0).y   = g_row_input
    input_form(0).wid = g_screen_cols - CHAT_COL + 1 - pfx_len
    vt_tui_form_draw(input_form(), input_focused)
End Sub

' Draw the left-side user-list pane: listbox + separator
Sub draw_pane()
    If pane_dirty Then pane_refresh()
    ' background: rows 2..ROW_INPUT-1 (listbox area + gap row screenhei-2)
    vt_tui_rect_fill(1, CHAT_TOP_ROW, PANE_W, g_row_status - CHAT_TOP_ROW, _
                     32, col_fg_body, col_bg_main)

    ' listbox (rows 2..screenhei-3, height = g_chat_rows)
    If wins(active_win).user_count > 0 Then
        vt_tui_listbox_draw(1, CHAT_TOP_ROW, PANE_W, g_chat_rows, pane_display_items(), pane_lb_st)
    Else
        vt_color(col_fg_sys, col_bg_main)
        vt_locate(CHAT_TOP_ROW, 1)
        vt_print(vt_str_pad_right(" (no users)", PANE_W, " "))
    End If

    ' horizontal separator
    vt_tui_hline(1, g_row_input-1, PANE_SEP-1, col_fg_sys, col_bg_main)

    ' vertical separator from title bar row down to ROW_INPUT
    vt_tui_vline(PANE_SEP, 2, g_row_input-1, col_fg_sys, col_bg_main)

    ' grid connecting char
    vt_set_cell(PANE_SEP, g_row_input-1, 197, col_fg_sys, col_bg_main)
End Sub

Sub draw_ui()
    If df_hist = 0 AndAlso df_pane = 0 AndAlso df_input = 0 Then Return
    ' Each draw sub fills its own region completely.  vt_cls is only needed
    ' when all three are dirty at once (startup / after resize).
    vt_color(col_fg_body, col_bg_main)
    If df_hist AndAlso df_pane AndAlso df_input Then vt_cls(col_bg_main)
    If df_hist Then
        draw_history()
        df_hist = 0
    End If
    If df_pane Then
        draw_pane()    ' draw_pane calls pane_refresh which clears pane_dirty
        df_pane = 0
    End If
    If df_input Then
        update_window_title()
        menu_draw()
        draw_status()
    End If
    draw_input()   ' always last -- repositions cursor via vt_tui_form_draw
    df_input = 0
End Sub

#Include Once "vtirc_help.bas"     ' help window (F1)
#Include Once "vtirc_svconfig.bas" ' server settings form (F2)
#Include Once "vtirc_config.bas"   ' common settings form (F3)
#Include Once "vtirc_chanbrowser.bas" ' F4 channel browser form

' -----------------------------------------------------------------------------
' do_channel_join -- open (or switch to) a channel window, replay log tail,
' persist to cfg.channel, and send JOIN to the server.
' Shared by the /join command handler and channel_browser.
' -----------------------------------------------------------------------------
Sub do_channel_join(ch_name As String)
    Dim jn_wi As Long = win_find(ch_name)
    If jn_wi < 0 Then
        jn_wi = win_open(ch_name, 0)
        If jn_wi >= 0 Then
            log_load_tail(jn_wi, LOG_TAIL_N)
            If InStr(LCase(cfg.channel), LCase(ch_name)) = 0 Then
                If Len(cfg.channel) > 0 Then cfg.channel &= ","
                cfg.channel &= ch_name
                cfg_save()
            End If
        End If
    End If
    If jn_wi >= 0 Then
        active_win = jn_wi
        wins(active_win).unread = 0
        pane_dirty = 1
        df_hist  = 1
        df_pane  = 1
        df_input = 1
    End If
    irc_send("JOIN " & ch_name)
End Sub

' -----------------------------------------------------------------------------
' IRC: send
' -----------------------------------------------------------------------------
Sub irc_send(irc_msg As String)
    If sock_valid = 0 Then Return
    If Len(irc_msg) > 510 Then irc_msg = Left(irc_msg, 510)
    Dim full_msg As String = irc_msg & Chr(13) & Chr(10)
    Dim snd_len  As Long   = Len(full_msg)
    Dim sent     As Long   = 0
    Dim nb       As Long
    Dim zbuf     As ZString * 513
    zbuf = full_msg
    Do While sent < snd_len
        nb = vt_net_send(sock, @zbuf + sent, snd_len - sent)
        If nb <= 0 Then Exit Do
        sent += nb
    Loop
End Sub

Sub irc_parse(raw_ln As String, ByRef pfx As String, ByRef cmd As String, _
              ByRef prms As String, ByRef trail As String)
    pfx = "" : cmd = "" : prms = "" : trail = ""
    Dim rst As String = raw_ln
    Dim sp1  As Long
    Dim sp2  As Long
    Dim tp   As Long
    If Left(rst, 1) = ":" Then
        sp1 = InStr(rst, " ")
        If sp1 = 0 Then pfx = Mid(rst, 2) : Return
        pfx  = Mid(rst, 2, sp1 - 2)
        rst = Mid(rst, sp1 + 1)
    End If
    sp2 = InStr(rst, " ")
    If sp2 = 0 Then cmd = rst : Return
    cmd  = Left(rst, sp2 - 1)
    rst = Mid(rst, sp2 + 1)
    tp   = InStr(rst, " :")
    If tp > 0 Then
        trail = Mid(rst, tp + 2)
        prms  = Left(rst, tp - 1)
    ElseIf Left(rst, 1) = ":" Then
        trail = Mid(rst, 2)
    Else
        prms = rst
    End If
End Sub

Function nick_from_pfx(pfx As String) As String
    Dim ex As Long = InStr(pfx, "!")
    If ex > 0 Then Return Left(pfx, ex - 1)
    Return pfx
End Function

Function irc_strip_colors(s As String) As String
    Dim result As String
    Dim i      As Long  = 1
    Dim slen   As Long  = Len(s)
    Dim ch     As UByte
    Dim dum_fg As Long
    Dim dum_bg As Long
    Do While i <= slen
        ch = Asc(s, i)
        Select Case ch
        Case 3
            mirc_skip_color(s, i, slen, dum_fg, dum_bg)
        Case 2, 15, 22, 31
            i += 1
        Case Else
            result &= Chr(ch)
            i += 1
        End Select
    Loop
    Return result
End Function

' -----------------------------------------------------------------------------
' Color input: ^n -> mIRC Chr(3)nn
' -----------------------------------------------------------------------------
Function q3_to_mirc(txt As String) As String
    Static ega_to_mirc(15) As UByte = { _
        1, 2, 3, 10, 4, 6, 7, 15, 14, 12, 9, 11, 4, 13, 8, 0 }
    Dim result    As String
    Dim slen      As Long = Len(txt)
    Dim i         As Long = 1
    Dim has_color As Byte = 0
    Do While i <= slen
        If Asc(txt, i) = Asc("^") AndAlso i < slen Then
            Dim d1 As Long = Asc(txt, i + 1) - Asc("0")
            If d1 >= 0 AndAlso d1 <= 9 Then
                Dim clr_idx As Long = d1
                Dim skip    As Long = 1
                If i + 2 <= slen Then
                    Dim d2   As Long = Asc(txt, i + 2) - Asc("0")
                    Dim try2 As Long = d1 * 10 + d2
                    If d2 >= 0 AndAlso d2 <= 9 AndAlso try2 <= 15 Then
                        clr_idx = try2
                        skip    = 2
                    End If
                End If
                result    &= Chr(3) & Right("0" & ega_to_mirc(clr_idx), 2)
                has_color  = 1
                i         += 1 + skip
                Continue Do
            End If
        End If
        result &= Chr(Asc(txt, i))
        i += 1
    Loop
    If has_color Then result &= Chr(15)
    Return result
End Function

' -----------------------------------------------------------------------------
' User list  (sorted snapshot rebuilt via pane_refresh on pane_dirty)
' -----------------------------------------------------------------------------
Sub user_list_clear(win_idx As Long)
    wins(win_idx).user_count = 0
    If win_idx = active_win Then pane_dirty = 1 : df_pane = 1
End Sub

Sub user_list_add(win_idx As Long, nick As String)
    Dim n As String = nick
    Do While Len(n) > 0
        Select Case Left(n, 1)
        Case "@", "+", "%", "&", "~"
            n = Mid(n, 2)
        Case Else
            Exit Do
        End Select
    Loop
    If Len(n) = 0 Then Return
    Dim i As Long
    For i = 0 To wins(win_idx).user_count - 1
        If LCase(wins(win_idx).user_list(i)) = LCase(n) Then Return
    Next i
    If wins(win_idx).user_count >= USER_MAX Then Return
    wins(win_idx).user_list(wins(win_idx).user_count) = n
    wins(win_idx).user_count += 1
    If win_idx = active_win Then pane_dirty = 1 : df_pane = 1
End Sub

Sub user_list_remove(win_idx As Long, nick As String)
    Dim i As Long
    For i = 0 To wins(win_idx).user_count - 1
        If LCase(wins(win_idx).user_list(i)) = LCase(nick) Then
            Dim j As Long
            For j = i To wins(win_idx).user_count - 2
                wins(win_idx).user_list(j) = wins(win_idx).user_list(j + 1)
            Next j
            wins(win_idx).user_list(wins(win_idx).user_count - 1) = ""
            wins(win_idx).user_count -= 1
            If win_idx = active_win Then pane_dirty = 1 : df_pane = 1
            Return
        End If
    Next i
End Sub

Sub user_list_rename(win_idx As Long, old_nick As String, new_nick As String)
    Dim i As Long
    For i = 0 To wins(win_idx).user_count - 1
        If LCase(wins(win_idx).user_list(i)) = LCase(old_nick) Then
            wins(win_idx).user_list(i) = new_nick
            If win_idx = active_win Then pane_dirty = 1 : df_pane = 1
            Return
        End If
    Next i
End Sub

Function user_in_win(win_idx As Long, nick As String) As Byte
    Dim i As Long
    For i = 0 To wins(win_idx).user_count - 1
        If LCase(wins(win_idx).user_list(i)) = LCase(nick) Then Return 1
    Next i
    Return 0
End Function

' -----------------------------------------------------------------------------
' Window array helpers
' -----------------------------------------------------------------------------
Function win_find(tgt As String) As Long
    Dim i As Long
    For i = 0 To win_count - 1
        If LCase(wins(i).target) = LCase(tgt) Then Return i
    Next i
    Return -1
End Function

Function win_open(tgt As String, pm As Byte) As Long
    Dim idx As Long = win_find(tgt)
    If idx >= 0 Then Return idx
    If win_count >= WIN_MAX Then Return -1
    If pm = 0 Then
        ' Channel window: insert before the first PM window
        Dim insert_at As Long = win_count
        Dim si        As Long
        For si = 0 To win_count - 1
            If wins(si).is_pm Then
                insert_at = si
                Exit For
            End If
        Next si
        ' Shift existing windows right to make room
        For si = win_count - 1 To insert_at Step -1
            wins(si + 1) = wins(si)
        Next si
        ' Adjust active_win if it sits at or after the insertion point
        If active_win >= insert_at Then active_win += 1
        idx = insert_at
    Else
        ' PM window: append at end
        idx = win_count
    End If
    wins(idx).target          = tgt
    wins(idx).is_pm           = pm
    wins(idx).unread          = 0
    wins(idx).hist_count      = 0
    wins(idx).hist_head       = 0
    wins(idx).top_line        = 0
    wins(idx).new_msgs        = 0
    wins(idx).user_count      = 0
    wins(idx).names_receiving = 0
    win_count += 1
    Return idx
End Function

' Zero out all transient fields of one window slot.
' History data is left in place; hist_count=0 makes it unreachable.
Sub win_reset(win_idx As Long)
    wins(win_idx).target          = ""
    wins(win_idx).is_pm           = 0
    wins(win_idx).unread          = 0
    wins(win_idx).hist_count      = 0
    wins(win_idx).hist_head       = 0
    wins(win_idx).top_line        = 0
    wins(win_idx).new_msgs        = 0
    wins(win_idx).user_count      = 0
    wins(win_idx).names_receiving = 0
End Sub

Sub win_close(win_idx As Long)
    If win_count <= 1 Then
        win_hist_append(0, "*** Cannot close the last window. Use /part to leave a channel.", VT_BRIGHT_RED)
        Exit Sub
    End If
    If win_idx < 0 OrElse win_idx >= win_count Then Exit Sub
    Dim i As Long
    For i = win_idx To win_count - 2
        wins(i) = wins(i + 1)
    Next i
    win_reset(win_count - 1)
    win_count -= 1
    ' Adjust active_win
    If active_win > win_idx Then active_win -= 1
    If active_win >= win_count Then active_win = win_count - 1
    If active_win < 0 Then active_win = 0
    pane_dirty = 1
    df_hist  = 1
    df_pane  = 1
    df_input = 1
End Sub

Function nick_mentioned(txt As String, nick_str As String) As Byte
    If Len(nick_str) = 0 Then Return 0
    Dim lc_txt  As String = LCase(txt)
    Dim lc_nick As String = LCase(nick_str)
    Dim p       As Long   = 1
    Dim nlen    As Long   = Len(lc_nick)
    Dim slen    As Long   = Len(lc_txt)
    Do
        p = InStr(p, lc_txt, lc_nick)
        If p = 0 Then Return 0
        Dim ok_before As Byte = 1
        Dim ok_after  As Byte = 1
        If p > 1 Then
            Dim cb As UByte = Asc(lc_txt, p - 1)
            If (cb >= Asc("a") AndAlso cb <= Asc("z")) _
               OrElse (cb >= Asc("0") AndAlso cb <= Asc("9")) _
               OrElse cb = Asc("_") OrElse cb = Asc("-") Then ok_before = 0
        End If
        If p + nlen - 1 < slen Then
            Dim ca As UByte = Asc(lc_txt, p + nlen)
            If (ca >= Asc("a") AndAlso ca <= Asc("z")) _
               OrElse (ca >= Asc("0") AndAlso ca <= Asc("9")) _
               OrElse ca = Asc("_") OrElse ca = Asc("-") Then ok_after = 0
        End If
        If ok_before AndAlso ok_after Then Return 1
        p += 1
    Loop
    Return 0
End Function

' -----------------------------------------------------------------------------
' prms_last_token -- extract the last space-delimited token from a prms string.
' Used by IRC numeric handlers 332, 353, 366 to get the target channel name.
' -----------------------------------------------------------------------------
Function prms_last_token(prms As String) As String
    Dim last_sp As Long = 0
    Dim pi      As Long
    For pi = 1 To Len(prms)
        If Mid(prms, pi, 1) = " " Then last_sp = pi
    Next pi
    If last_sp > 0 Then Return Trim(Mid(prms, last_sp + 1))
    Return Trim(prms)
End Function

' -----------------------------------------------------------------------------
' IRC: handle one complete server line
' -----------------------------------------------------------------------------
Sub irc_handle(raw_ln As String)
    Dim pfx_str   As String
    Dim cmd_str   As String
    Dim prms_str  As String
    Dim trail_str As String
    irc_parse(raw_ln, pfx_str, cmd_str, prms_str, trail_str)
    trail_str = vt_utf8_to_cp437(trail_str)  ' server sends UTF-8; convert to CP437 for display

    Dim src_nick As String = nick_from_pfx(pfx_str)
    Dim cmd_up   As String = UCase(cmd_str)

    Select Case cmd_up
    Case "PING"
        irc_send("PONG :" & trail_str)

    ' PRIVMSG handler with CTCP ACTION detection
    Case "PRIVMSG"
        Dim priv_tgt  As String = Trim(prms_str)
        Dim priv_wi   As Long   = win_find(priv_tgt)
        ' detect CTCP ACTION  (format: Chr(1) & "ACTION text" & Chr(1))
        Dim is_action  As Byte   = 0
        Dim action_txt As String
        If Left(trail_str, 8) = Chr(1) & "ACTION " Then
            Dim ctcp_end As Long = InStr(2, trail_str, Chr(1))
            If ctcp_end > 0 Then
                action_txt = Mid(trail_str, 9, ctcp_end - 9)
            Else
                action_txt = Mid(trail_str, 9)
            End If
            is_action = 1
        End If
        If priv_wi >= 0 AndAlso wins(priv_wi).is_pm = 0 Then
            Dim msg_fg    As UByte
            Dim mentioned As Byte = 0
            If LCase(src_nick) = LCase(cfg.nick) Then
                msg_fg = col_fg_own
            Else
                Dim chk_txt As String = IIf(is_action, action_txt, trail_str)
                If nick_mentioned(irc_strip_colors(chk_txt), cfg.nick) Then mentioned = 1
                msg_fg = nick_color(src_nick)
            End If
            Dim line_pfx As String = IIf(mentioned, Chr(22), "")
            Dim line_sfx As String = IIf(mentioned, Chr(15), "")
            If is_action Then
                win_hist_append(priv_wi, line_pfx & "* " & src_nick & " " & action_txt & line_sfx, msg_fg)
            Else
                win_hist_append(priv_wi, line_pfx & "<" & src_nick & "> " & trail_str & line_sfx, msg_fg)
            End If
            If mentioned AndAlso priv_wi <> active_win Then wins(priv_wi).unread = 1
            If mentioned Then notify_user()
        ElseIf LCase(priv_tgt) = LCase(cfg.nick) Then
            Dim pm_new As Byte
            pm_new     = IIf(win_find(src_nick) < 0, 1, 0)
            Dim pm_wi As Long = win_open(src_nick, 1)
            If pm_wi >= 0 Then
                If is_action Then
                    win_hist_append(pm_wi, "* " & src_nick & " " & action_txt, nick_color(src_nick))
                Else
                    win_hist_append(pm_wi, "<" & src_nick & "> " & trail_str, nick_color(src_nick))
                End If
                If pm_new Then notify_user()
            End If
        End If

    Case "NOTICE"
        Dim notice_src  As String = src_nick
        Dim notice_tgt  As String = Trim(prms_str)
        Dim notice_txt  As String = irc_strip_colors(trail_str)
        Dim notice_line As String
        Dim notice_wi   As Long   = win_find(notice_tgt)
        If notice_wi >= 0 AndAlso wins(notice_wi).is_pm = 0 Then
            notice_line = "-" & notice_src & ":" & notice_tgt & "- " & notice_txt
            win_hist_append(notice_wi, notice_line, col_fg_notice)
        Else
            notice_line = "-" & notice_src & "- " & notice_txt
            hist_append(notice_line, col_fg_notice)
        End If

    Case "JOIN"
        Dim jch As String = trail_str
        If jch = "" Then jch = prms_str
        jch = Trim(jch)
        Dim join_wi As Long = win_find(jch)
        If join_wi >= 0 Then
            win_hist_append(join_wi, "*** " & src_nick & " has joined " & jch, col_fg_sys)
            user_list_add(join_wi, src_nick)
        Else
            hist_append("*** " & src_nick & " has joined " & jch, col_fg_sys)
        End If

    Case "PART"
        Dim part_ch As String = Trim(prms_str)
        If Len(part_ch) = 0 Then part_ch = Trim(trail_str)
        Dim part_wi As Long = win_find(part_ch)
        If part_wi >= 0 Then
            win_hist_append(part_wi, "*** " & src_nick & " has left " & part_ch, col_fg_sys)
            user_list_remove(part_wi, src_nick)
        ElseIf LCase(src_nick) <> LCase(cfg.nick) Then
            ' Unknown channel and not us: show in win 0
            hist_append("*** " & src_nick & " has left " & part_ch, col_fg_sys)
        End If
        ' If it IS our own nick and win is already gone -> silently drop;
        ' we already printed the leave message and called win_close before
        ' the server echo arrived.

    Case "QUIT"
        Dim quit_msg As String = irc_strip_colors(trail_str)
        Dim qwi      As Long
        For qwi = 0 To win_count - 1
            If wins(qwi).is_pm = 0 Then
                If user_in_win(qwi, src_nick) Then
                    win_hist_append(qwi, "*** " & src_nick & " has quit (" & quit_msg & ")", col_fg_sys)
                    user_list_remove(qwi, src_nick)
                End If
            Else
                If LCase(wins(qwi).target) = LCase(src_nick) Then
                    win_hist_append(qwi, "*** " & src_nick & " has quit (" & quit_msg & ")", col_fg_sys)
                End If
            End If
        Next qwi

    Case "NICK"
        Dim new_nick As String = irc_strip_colors(trail_str)
        Dim is_self  As Byte   = IIf(LCase(src_nick) = LCase(cfg.nick), 1, 0)
        If is_self Then
            cfg.nick = new_nick
            df_input = 1   ' nick shown in the input line prefix
            hist_append("*** You are now known as " & new_nick, col_fg_sys)
        End If
        Dim nwi As Long
        For nwi = 0 To win_count - 1
            If wins(nwi).is_pm = 0 Then
                If user_in_win(nwi, src_nick) Then
                    user_list_rename(nwi, src_nick, new_nick)
                    If is_self = 0 Then
                        win_hist_append(nwi, "*** " & src_nick & " is now known as " & new_nick, col_fg_sys)
                    End If
                End If
            Else
                If LCase(wins(nwi).target) = LCase(src_nick) Then
                    wins(nwi).target = new_nick
                    win_hist_append(nwi, "*** " & src_nick & " is now known as " & new_nick, col_fg_sys)
                End If
            End If
        Next nwi

    Case "001"
        ' prms_str = the nick the server actually accepted
        Dim confirmed_nick As String = Trim(prms_str)
        If Len(confirmed_nick) > 0 Then cfg.nick = confirmed_nick
        hist_append("*** " & irc_strip_colors(trail_str), col_fg_sys)
        connected = 1
        df_input  = 1   ' nick confirmed; status may reflect it
        ' Send JOIN for every channel window that looks like a real channel
        Dim ch001_wi As Long
        For ch001_wi = 0 To win_count - 1
            If wins(ch001_wi).is_pm = 0 Then
                user_list_clear(ch001_wi)
                If Left(wins(ch001_wi).target, 1) = "#" OrElse _
                   Left(wins(ch001_wi).target, 1) = "&" Then
                    irc_send("JOIN " & wins(ch001_wi).target)
                End If
            End If
        Next ch001_wi

    Case "305"
        is_afk   = 0
        afk_msg  = ""
        df_input = 1   ' AFK badge cleared from status bar
        hist_append("*** You are no longer marked as away.", col_fg_sys)

    Case "321"
        ' RPL_LISTSTART -- silently suppress; actual entries arrive via 322

    Case "322"
        ' RPL_LIST: prms_str = "yournick #channel usercount"
        If chlist_active AndAlso chlist_count < CHLIST_MAX Then
            Dim tok322()  As String
            Dim tcnt322   As Long = vt_str_split(Trim(prms_str), " ", tok322())
            If tcnt322 >= 3 Then
                Dim ch322  As String = tok322(1)
                Dim cnt322 As Long   = Val(tok322(2))
                If Len(ch322) > 0 Then
                    chlist_names(chlist_count)  = ch322
                    chlist_users(chlist_count)  = cnt322
                    chlist_topics(chlist_count) = irc_strip_colors(trail_str)
                    chlist_count += 1
                End If
            End If
        End If

    Case "323"
        ' RPL_LISTEND
        chlist_done = 1

    Case "332"
        ' Topic reply: prms_str = "yournick #channel"  trail_str = topic text
        Dim ch332 As String = prms_last_token(prms_str)
        Dim wi332 As Long = win_find(ch332)
        If wi332 >= 0 Then
            win_hist_append(wi332, "*** Topic: " & irc_strip_colors(trail_str), col_fg_sys)
        Else
            hist_append("*** Topic for " & ch332 & ": " & irc_strip_colors(trail_str), col_fg_sys)
        End If

    Case "306"
        df_input = 1   ' AFK badge added to status bar
        hist_append("*** You are now marked as away.", col_fg_sys)

    Case "353"
        ' Extract channel: last space-delimited token in prms_str
        ' prms_str format is e.g. "mynick = #channel" or "mynick * #channel"
        Dim ch353 As String = prms_last_token(prms_str)
        Dim wi353 As Long = win_find(ch353)
        If wi353 >= 0 Then
            If wins(wi353).names_receiving = 0 Then
                user_list_clear(wi353)
                wins(wi353).names_receiving = 1
            End If
            Dim nk_parts353() As String
            Dim nk_count353   As Long = vt_str_split(trail_str, " ", nk_parts353())
            Dim ni353         As Long
            For ni353 = 0 To nk_count353 - 1
                If Len(nk_parts353(ni353)) > 0 Then user_list_add(wi353, nk_parts353(ni353))
            Next ni353
        End If

    Case "366"
        ' Extract channel: last space-delimited token in prms_str
        Dim ch366 As String = prms_last_token(prms_str)
        Dim wi366 As Long = win_find(ch366)
        If wi366 >= 0 Then
            wins(wi366).names_receiving = 0
            win_hist_append(wi366, "*** " & wins(wi366).user_count & " users in " & ch366, col_fg_sys)
        Else
            hist_append("*** End of NAMES for " & ch366, col_fg_sys)
        End If

    Case "433"
        If nick_alt_tried = 0 AndAlso Len(cfg.nick_alt) > 0 Then
            nick_alt_tried = 1
            hist_append("*** Nick in use -- trying alt: " & cfg.nick_alt, col_fg_sys)
            irc_send("NICK " & cfg.nick_alt)
        Else
            hist_append("*** Nickname in use: try /nick <newnick>", VT_BRIGHT_RED)
        End If

    Case Else
        Dim cmd_num As Long = Val(cmd_up)
        If cmd_num >= 1 AndAlso cmd_num <= 999 Then
            Select Case cmd_num
            Case 372, 375, 376
            Case Else
                If Len(trail_str) > 0 Then
                    hist_append("  " & irc_strip_colors(trail_str), VT_DARK_GREY)
                End If
            End Select
        End If
    End Select
End Sub

' -----------------------------------------------------------------------------
' IRC: disconnect
' -----------------------------------------------------------------------------
Sub irc_disconnect()
    If sock_valid = 0 Then Return
    reconnect_pending = 0
    irc_send("QUIT :VTIRC")
    vt_net_close(sock)
    vt_net_shutdown()
    sock_valid = 0
    connected  = 0
    recv_buf   = ""
    Dim di As Long
    For di = 1 To win_count - 1
        win_reset(di)
    Next di
    wins(0).unread          = 0
    wins(0).user_count      = 0
    wins(0).names_receiving = 0
    win_count  = 1
    active_win = 0
    pane_dirty = 1
    df_hist  = 1
    df_pane  = 1
    df_input = 1
    hist_append("*** Disconnected from " & cfg.server, col_fg_sys)
End Sub

' -----------------------------------------------------------------------------
' IRC: poll incoming data
' -----------------------------------------------------------------------------
Sub irc_poll()
    If sock_valid = 0 Then Return
    Dim tmp_buf  As ZString * 4097
    Dim nb       As Long
    Dim crlf_pos As Long
    Do While vt_net_ready(sock, 0, 0) = 1
        nb = vt_net_recv(sock, @tmp_buf, 4096)
        If nb <= 0 Then
            irc_on_drop()
            Return
        End If
        recv_buf &= Left(tmp_buf, nb)
        If Len(recv_buf) > 8192 Then Exit Do
    Loop
    Do
        crlf_pos = InStr(recv_buf, Chr(13) & Chr(10))
        If crlf_pos = 0 Then Exit Do
        Dim raw_line As String = Left(recv_buf, crlf_pos - 1)
        recv_buf = Mid(recv_buf, crlf_pos + 2)
        If Len(raw_line) > 0 Then irc_handle(raw_line)
    Loop
End Sub

Sub irc_on_drop()
    vt_net_close(sock)
    vt_net_shutdown()
    sock_valid = 0
    connected  = 0
    recv_buf   = ""
    If cfg.auto_reconnect Then
        reconnect_pending = 1
        reconnect_at      = Timer + RECONNECT_DELAY
        hist_append("*** Connection lost. Reconnecting in " & _
                    RECONNECT_DELAY & "s...", VT_BRIGHT_RED)
    Else
        hist_append("*** Connection closed by server.", col_fg_sys)
    End If
    df_hist  = 1
    df_pane  = 1
    df_input = 1
End Sub

' -----------------------------------------------------------------------------
' IRC: connect
' -----------------------------------------------------------------------------
Function irc_connect() As Byte
    If Len(cfg.nick) = 0 OrElse Len(cfg.server) = 0 Then
        hist_append("*** No server or nick configured", VT_BRIGHT_RED)
        Return 0
    End If

    hist_append("*** Connecting to " & cfg.server & ":" & cfg.port & "...", col_fg_sys)
    df_hist  = 1
    df_pane  = 1
    df_input = 1
    draw_ui()
    vt_present()

    If vt_net_init() <> 0 Then
        hist_append("*** Network init failed", VT_BRIGHT_RED)
        Return 0
    End If

    Dim srv_ip As Long = vt_net_resolve(StrPtr(cfg.server))
    If srv_ip = 0 Then
        hist_append("*** Could not resolve: " & cfg.server, VT_BRIGHT_RED)
        vt_net_shutdown()
        Return 0
    End If

    sock = vt_net_open()
    If sock = INVALID_SOCKET Then
        hist_append("*** Could not open socket", VT_BRIGHT_RED)
        vt_net_shutdown()
        Return 0
    End If

    If vt_net_connect(sock, srv_ip, cfg.port) = 0 Then
        hist_append("*** Connection refused: " & cfg.server, VT_BRIGHT_RED)
        vt_net_close(sock)
        vt_net_shutdown()
        Return 0
    End If

    sock_valid = 1
    vt_net_nonblocking(sock, 1)

    If is_reconnect = 0 Then
        ' Fresh connect: clear all existing windows, then open one per channel
        Dim ci_clr As Long
        For ci_clr = 0 To win_count - 1
            win_reset(ci_clr)
        Next ci_clr
        win_count = 0

        Dim ch_arr() As String
        Dim ch_cnt   As Long = vt_str_split(cfg.channel, ",", ch_arr())
        Dim ci       As Long
        For ci = 0 To ch_cnt - 1
            Dim ch_name As String = Trim(ch_arr(ci))
            If Len(ch_name) > 0 Then
                Dim new_wi As Long = win_open(ch_name, 0)
                If new_wi >= 0 Then log_load_tail(new_wi, LOG_TAIL_N)
            End If
        Next ci
        ' Ensure at least one window always exists
        If win_count = 0 Then win_open(cfg.server, 0)
    Else
        ' Reconnect: preserve history, reset per-window transient state
        Dim rwi As Long
        For rwi = 0 To win_count - 1
            wins(rwi).top_line        = 0
            wins(rwi).new_msgs        = 0
            wins(rwi).unread          = 0
            wins(rwi).user_count      = 0
            wins(rwi).names_receiving = 0
        Next rwi
    End If
    is_reconnect   = 0
    nick_alt_tried = 0
    active_win     = 0
    pane_dirty     = 1
    df_hist  = 1
    df_pane  = 1
    df_input = 1

    If Len(cfg.password) > 0 Then irc_send("PASS " & cfg.password)
    irc_send("NICK " & cfg.nick)
    irc_send("USER " & cfg.nick & " 0 * :VTIRC")

    Return 1
End Function

' -----------------------------------------------------------------------------
' Main
' -----------------------------------------------------------------------------
cfg_file = ExePath() & "/.vtirc"
cfg_defaults()
cfg_load()

' Apply saved screen size with clamping; keep defaults when config is new.
If cfg.screen_cols >= MIN_SCREEN_COLS Then g_screen_cols = cfg.screen_cols
If cfg.screen_rows >= MIN_SCREEN_ROWS Then g_screen_rows = cfg.screen_rows

vt_title("VTIRC " & IRC_VERSION)
Dim fnt_w As Long = IIf(cfg.font_size = 1, 16, 8)
Dim fnt_h As Long = IIf(cfg.font_size = 1, 24, 16)
Dim flags As Long = IIf(cfg.renderer  = 1, VT_RENDERER_HW, 0)

If vt_screen(VT_SCREENPARAM(g_screen_cols, g_screen_rows, fnt_w, fnt_h), VT_WINDOWED Or flags) <> 0 Then End 1

#ifndef __FB_WIN32__
#ifdef IRC_LINUX_NOTIFY
linux_sound_init()
#endif
#endif

g_screen_cols = vt_cols()
g_screen_rows = vt_rows()
screen_relayout()
vt_screen_minimum(MIN_SCREEN_COLS, MIN_SCREEN_ROWS)

vt_scroll_enable(0)
vt_mouse(1)
vt_locate(,,,95) ' underscore cursor
vt_on_close(@on_close)
vt_copypaste(VT_ENABLED)
scheme_apply()

' chat input line
input_form(0).kind    = VT_FORM_INPUT
input_form(0).max_len = 510
input_form(0).val     = ""
input_form(0).cpos    = 0
input_focused         = 0

' initialise pane listbox state
pane_lb_st.sel             = 0
pane_lb_st.top_item        = 0
pane_lb_st.last_click_item = -1
pane_lb_st.last_click_time = 0.0
pane_lb_st.prev_btns       = 0

If vt_file_exists(cfg_file) = 0 Then
    If settings_server_form() = 1 Then irc_connect()
Else
    irc_connect()
End If

' -- main loop ----------------------------------------------------------------
Dim k        As ULong
Dim menu_r   As Long = 0
Dim max_scr  As Long
Dim mx       As Long
Dim my       As Long
Dim mb       As Long
Dim whl      As Long
Dim prev_mb  As Long = 0   ' previous frame buttons for PM click edge-detect
Dim prev_inp_val As String = ""

' -- nick tab-completion state ------------------------------------------------
Dim tab_active      As Byte   = 0
Dim tab_idx         As Long   = 0
Dim tab_word_start  As Long   = 0   ' byte offset of the space before the word (or 0)
Dim tab_after_cur   As String = ""  ' text after cursor when TAB was first pressed
Dim tab_is_first    As Byte   = 0   ' 1 = first word on line (add ": " suffix)
Dim tab_match_count As Long   = 0
ReDim tab_matches(0) As String

Do
    ' -- auto-reconnect tick --------------------------------------------------
    If reconnect_pending AndAlso Timer >= reconnect_at Then
        reconnect_pending = 0
        hist_append("*** Reconnecting...", col_fg_sys)
        is_reconnect = 1
        If irc_connect() = 0 AndAlso cfg.auto_reconnect Then
            reconnect_pending = 1
            reconnect_at      = Timer + RECONNECT_DELAY
            hist_append("*** Reconnect failed. Retrying in " & _
                        RECONNECT_DELAY & "s...", VT_BRIGHT_RED)
        End If
        df_hist  = 1 : df_pane  = 1 : df_input = 1
    End If

    k = vt_inkey()
    If k <> 0 Then df_input = 1   ' any key may change input line or status

    menu_rebuild()
    menu_r = menu_handle(k)
    If menu_r <> 0 Then k = 0   ' menu consumed this key

    ' -- window resize check --------------------------------------------------
    check_resize()

    ' -- mouse state ----------------------------------------------------------
    vt_getmouse(@mx, @my, @mb, @whl)
    If mb <> prev_mb OrElse whl <> 0 Then df_input = 1

    ' -- pane listbox: mouse-only (k=0 so keyboard goes to chat input) --------
    Dim pane_ret As Long = VT_FORM_PENDING
    If wins(active_win).user_count > 0 Then
        pane_ret = vt_tui_listbox_handle(1, CHAT_TOP_ROW, PANE_W, g_chat_rows, _
                                         pane_display_items(), pane_lb_st, 0)
        ' listbox_handle owns wheel + click internally; mark pane dirty when it acts
        If pane_ret >= 0 Then
            df_pane = 1  ' confirmed (double-click or Enter)
        ElseIf whl <> 0 AndAlso mx >= 1 AndAlso mx <= PANE_W Then
            df_pane = 1  ' wheel scrolled inside pane
        ElseIf (mb And VT_MOUSE_BTN_LEFT) <> 0 AndAlso mx >= 1 AndAlso mx <= PANE_W Then
            df_pane = 1  ' click changed selection
        End If
    End If

    ' -- listbox double-click -----
    Dim pm_fire As Byte = 0

    If pane_ret >= 0 Then pm_fire = 1   ' double-click in listbox

    If pm_fire AndAlso wins(active_win).user_count > 0 Then
        Dim sel_nick As String = pane_items(pane_lb_st.sel)
        If LCase(sel_nick) <> LCase(cfg.nick) Then
            Dim pm_wi As Long = win_open(sel_nick, 1)
            If pm_wi >= 0 Then
                active_win              = pm_wi
                wins(active_win).unread = 0
                df_hist  = 1
                df_pane  = 1
                df_input = 1
            Else
                hist_append("*** Too many windows open (max " & WIN_MAX & ")", VT_BRIGHT_RED)
            End If
        End If
    End If

    ' -- left-click edge: focus zone switch + URL detection -------------------
    Dim url_lclick As Byte = (mb And VT_MOUSE_BTN_LEFT) And _
                             Not (prev_mb And VT_MOUSE_BTN_LEFT)
    If url_lclick Then
        If my = g_row_input AndAlso mx >= CHAT_COL Then
            focus_zone = FOCUS_INPUT
        ElseIf my >= CHAT_TOP_ROW AndAlso my <= g_chat_bot_row AndAlso mx >= CHAT_COL Then
            focus_zone = FOCUS_HISTORY
        ElseIf mx >= 1 AndAlso mx <= PANE_W Then
            focus_zone = FOCUS_PANE
        End If
    End If

    If url_lclick AndAlso my >= CHAT_TOP_ROW AndAlso my <= g_chat_bot_row _
                  AndAlso mx >= CHAT_COL Then
        Dim uc_idx As Long = my - CHAT_TOP_ROW
        If Len(url_hit_map(uc_idx).url_str) > 0 Then
            If mx >= url_hit_map(uc_idx).col_start AndAlso _
               mx <= url_hit_map(uc_idx).col_end Then
                open_url(url_hit_map(uc_idx).url_str)
            End If
        End If
    End If

    ' -- [LOG] label click on status bar: open log file in default editor ------
    If url_lclick AndAlso my = g_row_status AndAlso g_log_col_end > 0 Then
        If mx >= 1 AndAlso mx <= g_log_col_end Then
            Dim lp As String = log_path_active()
            If Len(lp) > 0 Then open_url(lp)
        End If
    End If
    ' --------------------------------------------------------------------------

    prev_mb = mb

    ' -- any non-plain-TAB key cancels nick completion -------------------------
    If k <> 0 AndAlso Not (VT_SCAN(k) = VT_KEY_TAB AndAlso VT_CTRL(k) = 0 AndAlso VT_ALT(k) = 0) Then
        tab_active = 0
    End If

    ' -- Ctrl+Tab / Ctrl+W window management ----------------------------------
    If VT_SCAN(k) = VT_KEY_TAB AndAlso VT_CTRL(k) Then
        If win_count > 1 Then
            active_win = (active_win + 1) Mod win_count
            wins(active_win).unread = 0
            pane_dirty = 1
            df_hist  = 1
            df_pane  = 1
            df_input = 1
        End If
    ElseIf VT_CHAR(k) = 23 Then
        ' Close active window only if it is a PM; channels are closed via /part
        If active_win >= 0 AndAlso wins(active_win).is_pm Then
            win_close(active_win)
        End If
    Else
        ' intercept Up/Down for command history before passing to form
        Select Case VT_SCAN(k)
        Case VT_KEY_PGUP, VT_KEY_PGDN
            ' handled in scroll section below

         Case VT_KEY_HOME, VT_KEY_END
            If focus_zone = FOCUS_INPUT Then
                vt_tui_form_handle(input_form(), input_focused, k, VT_FORM_NO_ESC)
            End If
            ' else: handled in scroll section below

        Case VT_KEY_UP
            If cmd_hist_count > 0 Then
                If cmd_hist_pos = -1 Then
                    cmd_hist_pos = cmd_hist_count - 1
                ElseIf cmd_hist_pos > 0 Then
                    cmd_hist_pos -= 1
                End If
                Dim up_ridx As Long = (cmd_hist_head + cmd_hist_pos) Mod CMD_HIST_MAX
                input_form(0).val      = cmd_hist_buf(up_ridx)
                input_form(0).cpos     = Len(input_form(0).val)
                input_form(0).view_off = 0
            End If

        Case VT_KEY_DOWN
            If cmd_hist_pos >= 0 Then
                cmd_hist_pos += 1
                If cmd_hist_pos >= cmd_hist_count Then
                    cmd_hist_pos = -1
                    input_form(0).val      = ""
                    input_form(0).cpos     = 0
                    input_form(0).view_off = 0
                Else
                    Dim dn_ridx As Long = (cmd_hist_head + cmd_hist_pos) Mod CMD_HIST_MAX
                    input_form(0).val      = cmd_hist_buf(dn_ridx)
                    input_form(0).cpos     = Len(input_form(0).val)
                    input_form(0).view_off = 0
                End If
            End If

        Case VT_KEY_TAB
            ' Nick completion -- only in channel windows with a user list
            If wins(active_win).user_count > 0 Then
                Dim tc_val  As String = input_form(0).val
                Dim tc_cpos As Long   = input_form(0).cpos

                If tab_active = 0 Then
                    ' First TAB: build match list from text before cursor
                    Dim tc_before As String = Left(tc_val, tc_cpos)
                    Dim tc_sp     As Long   = 0
                    Dim tc_ci     As Long
                    For tc_ci = Len(tc_before) To 1 Step -1
                        If tc_before[tc_ci - 1] = 32 Then tc_sp = tc_ci : Exit For
                    Next tc_ci
                    Dim tc_prefix As String
                    If tc_sp = 0 Then
                        tc_prefix = tc_before
                    Else
                        tc_prefix = Mid(tc_before, tc_sp + 1)
                    End If

                    If Len(tc_prefix) > 0 Then
                        ReDim tab_matches(wins(active_win).user_count - 1)
                        tab_match_count = 0
                        Dim tc_ui As Long
                        For tc_ui = 0 To wins(active_win).user_count - 1
                            Dim tc_un As String = wins(active_win).user_list(tc_ui)
                            If LCase(Left(tc_un, Len(tc_prefix))) = LCase(tc_prefix) Then
                                tab_matches(tab_match_count) = tc_un
                                tab_match_count += 1
                            End If
                        Next tc_ui

                        If tab_match_count > 0 Then
                            tab_active     = 1
                            tab_idx        = 0
                            tab_word_start = tc_sp
                            tab_after_cur  = Mid(tc_val, tc_cpos + 1)
                            tab_is_first   = (tc_sp = 0)
                        End If
                    End If
                Else
                    ' Subsequent TAB: cycle to next match
                    tab_idx = (tab_idx + 1) Mod tab_match_count
                End If

                If tab_active Then
                    Dim tc_compl As String = tab_matches(tab_idx)
                    If tab_is_first Then tc_compl &= ": "
                    input_form(0).val      = Left(tc_val, tab_word_start) & tc_compl & tab_after_cur
                    input_form(0).cpos     = tab_word_start + Len(tc_compl)
                    input_form(0).view_off = 0
                    df_input = 1
                End If
            End If

        Case Else
            If VT_ALT(k) = 0 Then   ' Alt+letter is reserved for the menu bar
                If VT_CHAR(k) <> 0 Then focus_zone = FOCUS_INPUT
                prev_inp_val = input_form(0).val
                vt_tui_form_handle(input_form(), input_focused, k, VT_FORM_NO_ESC)
                If input_form(0).val <> prev_inp_val Then df_input = 1
            End If
        End Select
    End If

    ' -- mouse wheel scroll (split by region) ---------------------------------
    If whl <> 0 Then
        If mx >= CHAT_COL Then
            ' -- chat history scroll ------------------------------------------
            df_hist = 1
            max_scr = wins(active_win).hist_count - g_chat_rows
            If whl > 0 Then
                If max_scr > 0 AndAlso wins(active_win).top_line < max_scr Then
                    wins(active_win).top_line += whl
                    If wins(active_win).top_line > max_scr Then wins(active_win).top_line = max_scr
                End If
            Else
                wins(active_win).top_line += whl
                If wins(active_win).top_line < 0 Then wins(active_win).top_line = 0
                If wins(active_win).top_line = 0  Then wins(active_win).new_msgs = 0
            End If
        ElseIf mx >= 1 AndAlso mx <= PANE_W Then
            ' -- user list pane scroll ----------------------------------------
            ' listbox_handle cannot see the wheel: vt_getmouse resets whl on read.
            ' whl > 0 = wheel up   -> top_item decreases (show earlier nicks)
            ' whl < 0 = wheel down -> top_item increases (show later nicks)
            If wins(active_win).user_count > 0 Then
                Dim max_pane_top As Long = wins(active_win).user_count - g_chat_rows
                If max_pane_top < 0 Then max_pane_top = 0
                pane_lb_st.top_item -= whl
                If pane_lb_st.top_item < 0            Then pane_lb_st.top_item = 0
                If pane_lb_st.top_item > max_pane_top Then pane_lb_st.top_item = max_pane_top
                df_pane = 1
            End If
        End If
    End If

    ' -- scroll keys, function keys, enter ------------------------------------
    Select Case VT_SCAN(k)
    Case VT_KEY_PGUP
        df_hist = 1
        max_scr = wins(active_win).hist_count - g_chat_rows
        If max_scr > 0 AndAlso wins(active_win).top_line < max_scr Then
            wins(active_win).top_line += 3
            If wins(active_win).top_line > max_scr Then wins(active_win).top_line = max_scr
        End If
    Case VT_KEY_PGDN
        df_hist = 1
        If wins(active_win).top_line > 3 Then
            wins(active_win).top_line -= 3
        Else
            wins(active_win).top_line = 0
            wins(active_win).new_msgs = 0
        End If
    Case VT_KEY_END
        If focus_zone <> FOCUS_INPUT Then
            wins(active_win).top_line = 0
            wins(active_win).new_msgs = 0
            df_hist = 1
        End If
    Case VT_KEY_HOME
        If focus_zone <> FOCUS_INPUT Then
            max_scr = wins(active_win).hist_count - g_chat_rows
            If max_scr > 0 Then
                wins(active_win).top_line = max_scr
                df_hist = 1
            End If
        End If

    ' -- function keys --------------------------------------------------------
    Case VT_KEY_F1
        help_window()
        df_hist  = 1
        df_pane  = 1
        df_input = 1

    Case VT_KEY_F2
        If connected Then
            vt_tui_dialog("Settings", "Disconnect first before changing server settings.", VT_DLG_OK)
        Else
            If settings_server_form() = 1 Then irc_connect()
        End If
        df_hist  = 1
        df_pane  = 1
        df_input = 1

    Case VT_KEY_F3
        settings_common_form()
        df_hist  = 1
        df_pane  = 1
        df_input = 1

    Case VT_KEY_F4
        If connected Then
            channel_browser()
        Else
            hist_append("*** Connect to a server first to browse channels.", VT_BRIGHT_RED)
        End If
        df_hist  = 1
        df_pane  = 1
        df_input = 1

    Case VT_KEY_F10
        If sock_valid Then irc_disconnect()

    ' -- send on Enter --------------------------------------------------------
    Case VT_KEY_ENTER
        If Len(input_form(0).val) > 0 Then
            ' save to command history ring before processing
            Dim ch_slot As Long
            If cmd_hist_count < CMD_HIST_MAX Then
                ch_slot = (cmd_hist_head + cmd_hist_count) Mod CMD_HIST_MAX
                cmd_hist_count += 1
            Else
                ch_slot = cmd_hist_head
                cmd_hist_head = (cmd_hist_head + 1) Mod CMD_HIST_MAX
            End If
            cmd_hist_buf(ch_slot) = input_form(0).val
            cmd_hist_pos = -1

            If Left(input_form(0).val, 1) = "/" Then
                Dim cmd_raw  As String = Mid(input_form(0).val, 2)
                Dim sp_pos   As Long   = InStr(cmd_raw, " ")
                Dim cmd_word As String
                Dim cmd_arg  As String
                If sp_pos > 0 Then
                    cmd_word = UCase(Left(cmd_raw, sp_pos - 1))
                    cmd_arg  = Mid(cmd_raw, sp_pos + 1)
                Else
                    cmd_word = UCase(cmd_raw)
                    cmd_arg  = ""
                End If

                Select Case cmd_word
                Case "QUIT"
                    irc_disconnect()

                Case "ME"
                    If connected AndAlso Len(cmd_arg) > 0 Then
                        Dim me_cp437 As String = q3_to_mirc(cmd_arg)
                        irc_send("PRIVMSG " & wins(active_win).target & " :" & _
                                 Chr(1) & "ACTION " & vt_cp437_to_utf8(me_cp437) & Chr(1))
                        win_hist_append(active_win, "* " & cfg.nick & " " & me_cp437, col_fg_own)
                    ElseIf Len(cmd_arg) = 0 Then
                        hist_append("*** Usage: /me <action text>", VT_BRIGHT_RED)
                    Else
                        hist_append("*** Not connected.", VT_BRIGHT_RED)
                    End If

                Case "NICK"
                    If Len(cmd_arg) > 0 Then irc_send("NICK " & cmd_arg)

                Case "JOIN"
                    Dim join_ch As String = Trim(cmd_arg)
                    If Len(join_ch) > 0 AndAlso connected Then
                        do_channel_join(join_ch)
                    ElseIf Len(join_ch) = 0 Then
                        hist_append("*** Usage: /join <#channel>", VT_BRIGHT_RED)
                    Else
                        hist_append("*** Not connected.", VT_BRIGHT_RED)
                    End If

                Case "PART"
                    If wins(active_win).is_pm = 0 Then
                        Dim part_tgt As String = wins(active_win).target
                        irc_send("PART " & part_tgt)
                        win_hist_append(active_win, "*** You left " & part_tgt, col_fg_sys)
                        ' Remove from cfg.channel list and save
                        Dim part_arr()  As String
                        Dim part_cnt    As Long = vt_str_split(cfg.channel, ",", part_arr())
                        Dim part_new    As String
                        Dim pi          As Long
                        For pi = 0 To part_cnt - 1
                            If LCase(Trim(part_arr(pi))) <> LCase(part_tgt) Then
                                If Len(part_new) > 0 Then part_new &= ","
                                part_new &= Trim(part_arr(pi))
                            End If
                        Next pi
                        cfg.channel = part_new
                        cfg_save()
                        win_close(active_win)
                    Else
                        win_hist_append(active_win, "*** /part: active window is a PM. Use Ctrl+W to close.", VT_BRIGHT_RED)
                    End If

                Case "AFK"
                    If connected Then
                        If Len(cmd_arg) = 0 Then cmd_arg = "AFK"
                        irc_send("AWAY :" & cmd_arg)
                        is_afk  = 1
                        afk_msg = cmd_arg
                    Else
                        hist_append("*** Not connected.", VT_BRIGHT_RED)
                    End If

                Case "BACK"
                    If connected Then
                        irc_send("AWAY")
                        is_afk  = 0
                        afk_msg = ""
                    Else
                        hist_append("*** Not connected.", VT_BRIGHT_RED)
                    End If

                Case "MSG"
                    If connected AndAlso Len(cmd_arg) > 0 Then
                        Dim msg_sp  As Long   = InStr(cmd_arg, " ")
                        Dim msg_tgt As String
                        Dim msg_txt As String
                        If msg_sp > 0 Then
                            msg_tgt = Left(cmd_arg, msg_sp - 1)
                            msg_txt = Mid(cmd_arg, msg_sp + 1)
                        Else
                            msg_tgt = cmd_arg
                            msg_txt = ""
                        End If
                        If LCase(msg_tgt) = LCase(cfg.nick) Then
                            hist_append("*** Cannot open a PM with yourself.", VT_BRIGHT_RED)
                        Else
                            Dim msg_wi As Long = win_open(msg_tgt, 1)
                            If msg_wi >= 0 Then
                                active_win              = msg_wi
                                wins(active_win).unread = 0
                                df_hist  = 1
                                df_pane  = 1
                                df_input = 1
                                If Len(msg_txt) > 0 Then
                                    Dim msg_cp437 As String = q3_to_mirc(msg_txt)
                                    irc_send("PRIVMSG " & msg_tgt & " :" & vt_cp437_to_utf8(msg_cp437))
                                    win_hist_append(msg_wi, "<" & cfg.nick & "> " & msg_cp437, col_fg_own)
                                End If
                            Else
                                hist_append("*** Too many windows open (max " & WIN_MAX & ")", VT_BRIGHT_RED)
                            End If
                        End If
                    End If

                Case "CLEAR"
                    wins(active_win).hist_count = 0
                    wins(active_win).hist_head  = 0
                    wins(active_win).top_line   = 0
                    wins(active_win).new_msgs   = 0
                    df_hist = 1

                Case Else
                    hist_append("*** Unknown command: /" & cmd_word, VT_BRIGHT_RED)
                End Select
            ElseIf connected Then
                Dim wire_cp437 As String = q3_to_mirc(input_form(0).val)
                irc_send("PRIVMSG " & wins(active_win).target & " :" & vt_cp437_to_utf8(wire_cp437))
                win_hist_append(active_win, "<" & cfg.nick & "> " & wire_cp437, col_fg_own)
                wins(active_win).top_line = 0
                wins(active_win).new_msgs = 0
            End If
            input_form(0).val      = ""
            input_form(0).cpos     = 0
            input_form(0).view_off = 0
        End If
    End Select

    irc_poll()

    draw_ui()
    vt_sleep(IDLE_MS)
Loop Until quit_flag

' Persist the final window size so next launch opens at the same size.
cfg.screen_cols = g_screen_cols
cfg.screen_rows = g_screen_rows
cfg_save()
If sock_valid Then irc_disconnect()
vt_shutdown()
