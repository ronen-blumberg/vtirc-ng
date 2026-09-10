' =============================================================================
' src/ui/dialogs.bas -- modal dialogs (libvt TUI widgets)
'
' Dialogs run their own loops; network I/O continues through the vt_on_idle
' callback. libvt widgets draw CP437, so strings are converted on the way in
' (vt_utf8_to_cp437) and out (vt_cp437_to_utf8).
' =============================================================================

Private Function to437(ByRef s As String) As String
    Return vt_utf8_to_cp437(s)
End Function

Private Function from437(ByRef s As String) As String
    Return vt_cp437_to_utf8(s)
End Function

Sub dlg_begin()
    vt_tui_theme_default()
    sel_on = 0
End Sub

Sub dlg_end()
    theme_apply(cfg.theme)
    ui_dirty = 1
    render_all()
End Sub


' Unicode-capable replacement for vt_tui_listbox_draw (same geometry, colours
' and scrollbar); items are UTF-8. vt_tui_listbox_handle is still used for
' input -- it only needs the item count.
Sub ui_listbox_draw(x As Long, y As Long, wid As Long, hei As Long, items() As String, ByRef st As vt_tui_listbox_state)
    Dim n As Long = UBound(items) - LBound(items) + 1
    If n <= 0 Then Exit Sub
    Dim base_ As Long = LBound(items)
    Dim max_top As Long = n - hei
    If max_top < 0 Then max_top = 0
    Dim need_scroll As Byte = IIf(n > hei, 1, 0)
    Dim iw As Long = IIf(need_scroll, wid - 1, wid)
    If st.sel < 0 Then st.sel = 0
    If st.sel >= n Then st.sel = n - 1
    If st.top_item < 0 Then st.top_item = 0
    If st.top_item > max_top Then st.top_item = max_top
    Dim wfg As UByte = vt_internal_tui_theme.win_fg
    Dim wbg As UByte = vt_internal_tui_theme.win_bg
    Dim r As Long
    For r = 0 To hei - 1
        Dim idx As Long = st.top_item + r
        Dim fg As UByte = IIf(idx = st.sel, wfg Xor 15, wfg)
        Dim bg As UByte = IIf(idx = st.sel, wbg Xor 15, wbg)
        ui_fill(x, y + r, x + iw - 1, y + r, fg, bg)
        If idx < n Then
            ' Chr(1) separates columns: each column gets its own bidi ordering so
            ' right-to-left text cannot pull neighbouring columns across
            Dim seg() As String
            Dim ns As Long = str_split(items(base_ + idx), Chr(1), seg())
            Dim cx As Long = x
            Dim si As Long
            For si = 0 To ns - 1
                If cx > x + iw - 1 Then Exit For
                Dim sw As Long = utf8_width(seg(si))
                ui_text(cx, y + r, x + iw - cx, seg(si), fg, bg)
                cx += sw
            Next si
        End If
    Next r
    If need_scroll Then
        Dim thumb As Long = st.top_item * (hei - 1) \ (n - hei)
        For r = 0 To hei - 1
            vt_set_cell(x + wid - 1, y + r, IIf(r = thumb, 219, 177), wfg, wbg)
        Next r
    End If
End Sub

' form item helpers
Private Sub fi_label(items() As vt_tui_form_item, i As Long, x As Long, y As Long, w As Long, ByRef txt As String)
    items(i).kind = VT_FORM_LABEL : items(i).x = x : items(i).y = y : items(i).wid = w
    items(i).val = txt : items(i).align = VT_ALIGN_LEFT
    items(i).lbl_fg = VT_BLACK : items(i).lbl_bg = VT_LIGHT_GREY
End Sub

Private Sub fi_input(items() As vt_tui_form_item, i As Long, x As Long, y As Long, w As Long, maxlen As Long, ByRef v As String)
    items(i).kind = VT_FORM_INPUT : items(i).x = x : items(i).y = y : items(i).wid = w
    items(i).max_len = maxlen : items(i).val = to437(v) : items(i).cpos = Len(items(i).val) : items(i).view_off = 0
End Sub

Private Sub fi_button(items() As vt_tui_form_item, i As Long, x As Long, y As Long, ByRef txt As String, ret As Long)
    items(i).kind = VT_FORM_BUTTON : items(i).x = x : items(i).y = y : items(i).val = txt : items(i).ret = ret
End Sub

Private Sub fi_check(items() As vt_tui_form_item, i As Long, x As Long, y As Long, ByRef txt As String, chk As Long)
    items(i).kind = VT_FORM_CHECKBOX : items(i).x = x : items(i).y = y : items(i).val = txt
    items(i).checked = IIf(chk, 1, 0)
End Sub

Private Sub fi_radio(items() As vt_tui_form_item, i As Long, x As Long, y As Long, ByRef txt As String, grp As Long, chk As Long)
    items(i).kind = VT_FORM_RADIO : items(i).x = x : items(i).y = y : items(i).val = txt
    items(i).group_id = grp : items(i).checked = IIf(chk, 1, 0)
End Sub

Private Function fi_val(items() As vt_tui_form_item, i As Long) As String
    Return from437(Trim(items(i).val))
End Function

' Centered box origin.
Private Sub dlg_origin(w As Long, h As Long, ByRef x As Long, ByRef y As Long)
    x = (vt_cols() - w) \ 2 + 1
    y = (vt_rows() - h) \ 2 + 1
    If x < 1 Then x = 1
    If y < 1 Then y = 1
End Sub

Function dlg_confirm(ByRef title As String, ByRef text As String) As Byte
    dlg_begin()
    Dim r As Long = vt_tui_dialog(to437(title), to437(text), VT_DLG_YESNO)
    dlg_end()
    Return IIf(r = VT_RET_YES, 1, 0)
End Function

Sub dlg_message(ByRef title As String, ByRef text As String)
    dlg_begin()
    vt_tui_dialog(to437(title), to437(text), VT_DLG_OK)
    dlg_end()
End Sub

' One-line text input. Returns 1 on OK.
Function dlg_input(ByRef title As String, ByRef prompt As String, ByRef value As String, w As Long = 60) As Byte
    Dim fw As Long = w
    Dim fh As Long = 7
    Dim fx As Long, fy As Long
    dlg_origin(fw, fh, fx, fy)
    Dim items(0 To 3) As vt_tui_form_item
    fi_label(items(), 0, 2, 1, fw - 4, prompt)
    fi_input(items(), 1, 2, 2, fw - 4, 400, value)
    fi_button(items(), 2, fw \ 2 - 10, 4, "OK", 1)
    fi_button(items(), 3, fw \ 2 + 2, 4, "Cancel", 2)
    vt_tui_form_offset(items(), fx, fy)
    Dim focused As Long = 1
    Dim result As Long = 0
    dlg_begin()
    Do
        Dim k As ULong = vt_inkey()
        If VT_SCAN(k) = VT_KEY_ENTER AndAlso focused = 1 Then result = 1 : Exit Do
        Dim r As Long = vt_tui_form_handle(items(), focused, k)
        If r = 1 Then result = 1 : Exit Do
        If r = 2 OrElse r = VT_FORM_CANCEL Then Exit Do
        vt_tui_rect_fill(fx + 1, fy + 1, fw - 2, fh - 2, 32, VT_BLACK, VT_LIGHT_GREY)
        vt_tui_window(fx, fy, fw, fh, " " & to437(title) & " ", VT_TUI_WIN_SHADOW)
        vt_tui_form_draw(items(), focused)
        vt_sleep(10)
    Loop
    If result = 1 Then value = fi_val(items(), 1)
    dlg_end()
    Return result
End Function

' Popup menu at (x, y). Returns the chosen index or -1.
Function dlg_popup(px As Long, py As Long, items() As String, n As Long) As Long
    If n <= 0 Then Return -1
    Dim w As Long = 4
    Dim i As Long
    For i = 0 To n - 1
        If Len(items(i)) + 4 > w Then w = Len(items(i)) + 4
    Next i
    Dim h As Long = n + 2
    Dim x As Long = px
    Dim y As Long = py
    If x + w - 1 > vt_cols() Then x = vt_cols() - w + 1
    If y + h - 1 > vt_rows() Then y = vt_rows() - h + 1
    If x < 1 Then x = 1
    If y < 1 Then y = 1
    Dim sel As Long = 0
    Dim mx As Long, my As Long, mb As Long, wh As Long
    Dim prev_mb As Long = -1
    Dim result As Long = -1
    dlg_begin()
    Do
        vt_getmouse(@mx, @my, @mb, @wh)
        If prev_mb = -1 Then prev_mb = mb
        If mx > x AndAlso mx < x + w - 1 AndAlso my > y AndAlso my < y + h - 1 Then sel = my - y - 1
        Dim k As ULong = vt_inkey()
        Select Case VT_SCAN(k)
        Case VT_KEY_UP   : sel = (sel + n - 1) Mod n
        Case VT_KEY_DOWN : sel = (sel + 1) Mod n
        Case VT_KEY_ENTER : result = sel : Exit Do
        Case VT_KEY_ESC  : Exit Do
        End Select
        ' click (button released)
        If (prev_mb And 3) <> 0 AndAlso (mb And 3) = 0 Then
            If mx > x AndAlso mx < x + w - 1 AndAlso my > y AndAlso my < y + h - 1 Then result = my - y - 1
            Exit Do
        End If
        prev_mb = mb
        vt_tui_rect_fill(x + 1, y + 1, w - 2, h - 2, 32, VT_BLACK, VT_LIGHT_GREY)
        vt_tui_window(x, y, w, h, "", 0)
        For i = 0 To n - 1
            Dim fg As UByte = IIf(i = sel, VT_WHITE, VT_BLACK)
            Dim bg As UByte = IIf(i = sel, VT_BLUE, VT_LIGHT_GREY)
            vt_tui_rect_fill(x + 1, y + 1 + i, w - 2, 1, 32, fg, bg)
            vt_color(fg, bg)
            vt_locate(y + 1 + i, x + 2)
            vt_print(items(i))
        Next i
        vt_sleep(10)
    Loop
    ' swallow the release so the click does not reach the window below
    Do
        vt_getmouse(@mx, @my, @mb, @wh)
        If (mb And 7) = 0 Then Exit Do
        vt_sleep(10)
    Loop
    dlg_end()
    Return result
End Function

' Generic list editor: add / edit / remove strings. Returns 1 if changed.
Function dlg_list_edit(ByRef title As String, ByRef hint As String, lst() As String, ByRef n As Long) As Byte
    Dim fw As Long = 70
    Dim fh As Long = 20
    Dim fx As Long, fy As Long
    dlg_origin(fw, fh, fx, fy)
    Dim items(0 To 4) As vt_tui_form_item
    fi_label(items(), 0, 2, 1, fw - 4, hint)
    fi_button(items(), 1, 2, fh - 3, "Add", 1)
    fi_button(items(), 2, 12, fh - 3, "Edit", 2)
    fi_button(items(), 3, 23, fh - 3, "Remove", 3)
    fi_button(items(), 4, fw - 12, fh - 3, "Close", 4)
    vt_tui_form_offset(items(), fx, fy)
    Dim st As vt_tui_listbox_state
    st.last_click_item = -1
    Dim focused As Long = 1
    Dim changed As Byte = 0
    Dim lbx As Long = fx + 2, lby As Long = fy + 3, lbw As Long = fw - 4, lbh As Long = fh - 7
    Dim shown() As String
    Do
        Dim i As Long
        ReDim shown(0 To IIf(n > 0, n - 1, 0))
        For i = 0 To n - 1
            shown(i) = lst(i)
        Next i
        If n = 0 Then shown(0) = "(empty)"
        dlg_begin()
        Dim action As Long = 0
        Do
            Dim k As ULong = vt_inkey()
            Dim r As Long = vt_tui_form_handle(items(), focused, IIf(VT_SCAN(k) = VT_KEY_UP OrElse VT_SCAN(k) = VT_KEY_DOWN, 0, k))
            Dim lr As Long = vt_tui_listbox_handle(lbx, lby, lbw, lbh, shown(), st, IIf(VT_SCAN(k) = VT_KEY_UP OrElse VT_SCAN(k) = VT_KEY_DOWN OrElse VT_SCAN(k) = VT_KEY_ENTER, k, 0))
            If lr >= 0 Then action = 2 : Exit Do
            If r >= 1 AndAlso r <= 4 Then action = r : Exit Do
            If r = VT_FORM_CANCEL Then action = 4 : Exit Do
            If VT_SCAN(k) = VT_KEY_DEL Then action = 3 : Exit Do
            vt_tui_rect_fill(fx + 1, fy + 1, fw - 2, fh - 2, 32, VT_BLACK, VT_LIGHT_GREY)
            vt_tui_window(fx, fy, fw, fh, " " & to437(title) & " ", VT_TUI_WIN_SHADOW)
            ui_listbox_draw(lbx, lby, lbw, lbh, shown(), st)
            vt_tui_form_draw(items(), focused)
            vt_sleep(10)
        Loop
        dlg_end()
        Dim cur As String
        Select Case action
        Case 1
            cur = ""
            If dlg_input("Add", hint, cur) AndAlso Len(cur) > 0 Then
                ReDim Preserve lst(0 To n)
                lst(n) = cur
                n += 1
                changed = 1
            End If
        Case 2
            If n > 0 AndAlso st.sel >= 0 AndAlso st.sel < n Then
                cur = lst(st.sel)
                If dlg_input("Edit", hint, cur) Then
                    If Len(cur) > 0 Then lst(st.sel) = cur Else action = 3
                    changed = 1
                End If
            End If
            If action <> 3 Then Continue Do
            If n > 0 AndAlso st.sel >= 0 AndAlso st.sel < n Then
                For i = st.sel To n - 2
                    lst(i) = lst(i + 1)
                Next i
                n -= 1
                changed = 1
            End If
        Case 3
            If n > 0 AndAlso st.sel >= 0 AndAlso st.sel < n Then
                For i = st.sel To n - 2
                    lst(i) = lst(i + 1)
                Next i
                n -= 1
                If st.sel >= n AndAlso st.sel > 0 Then st.sel -= 1
                changed = 1
            End If
        Case Else
            Exit Do
        End Select
    Loop
    Return changed
End Function

' ---------------------------------------------------------------- networks
Function dlg_network_edit(ni As Long) As Byte
    Dim fw As Long = 74
    Dim fh As Long = 22
    Dim fx As Long, fy As Long
    dlg_origin(fw, fh, fx, fy)
    Const NI_N = 30
    Dim items(0 To NI_N - 1) As vt_tui_form_item
    Dim srvs As String = ""
    Dim k As Long
    For k = 0 To nets(ni).srv_count - 1
        srvs &= IIf(k > 0, ", ", "") & srv_format(nets(ni).servers(k))
    Next k
    Dim aj As String = ""
    For k = 0 To nets(ni).aj_count - 1
        aj &= IIf(k > 0, ", ", "") & nets(ni).autojoin(k)
    Next k
    With nets(ni)
        fi_label(items(), 0, 2, 1, 11, "Name:")
        fi_input(items(), 1, 14, 1, 30, 60, .name)
        fi_label(items(), 2, 2, 3, 11, "Servers:")
        fi_input(items(), 3, 14, 3, fw - 17, 600, srvs)
        fi_label(items(), 4, 14, 4, fw - 17, "host/port[/tls][/password], separate several with commas")
        fi_label(items(), 5, 2, 6, 11, "Nick:")
        fi_input(items(), 6, 14, 6, 18, 60, .nick)
        fi_label(items(), 7, 35, 6, 11, "Alt nicks:")
        fi_input(items(), 8, 47, 6, fw - 50, 200, .altnicks)
        fi_label(items(), 9, 2, 7, 11, "Username:")
        fi_input(items(), 10, 14, 7, 18, 60, .username)
        fi_label(items(), 11, 35, 7, 11, "Real name:")
        fi_input(items(), 12, 47, 7, fw - 50, 200, .realname)
        fi_label(items(), 13, 2, 9, 11, "Login:")
        fi_radio(items(), 14, 14, 9, "None", 1, IIf(.login = LOGIN_NONE, 1, 0))
        fi_radio(items(), 15, 24, 9, "SASL", 1, IIf(.login = LOGIN_SASL, 1, 0))
        fi_radio(items(), 16, 34, 9, "NickServ", 1, IIf(.login = LOGIN_NICKSERV, 1, 0))
        fi_radio(items(), 17, 48, 9, "Server password", 1, IIf(.login = LOGIN_SERVERPASS, 1, 0))
        fi_label(items(), 18, 2, 10, 11, "Account:")
        fi_input(items(), 19, 14, 10, 18, 100, .login_user)
        fi_label(items(), 20, 35, 10, 11, "Password:")
        fi_input(items(), 21, 47, 10, fw - 50, 200, .login_pass)
        fi_label(items(), 22, 2, 12, 11, "Autojoin:")
        fi_input(items(), 23, 14, 12, fw - 17, 1000, aj)
        fi_label(items(), 24, 2, 13, 11, "Charset:")
        fi_input(items(), 25, 14, 13, 12, 20, IIf(Len(.charset) > 0, .charset, "utf-8"))
        fi_check(items(), 26, 14, 15, "Connect at startup", .autoconnect)
        fi_check(items(), 27, 40, 15, "Accept any TLS certificate", .accept_invalid_cert)
        fi_button(items(), 28, fw \ 2 - 12, fh - 3, "OK", 1)
        fi_button(items(), 29, fw \ 2 + 2, fh - 3, "Cancel", 2)
    End With
    vt_tui_form_offset(items(), fx, fy)
    Dim focused As Long = 1
    Dim result As Long = 0
    dlg_begin()
    Do
        Dim kk As ULong = vt_inkey()
        Dim r As Long = vt_tui_form_handle(items(), focused, kk)
        If r = 1 Then result = 1 : Exit Do
        If r = 2 OrElse r = VT_FORM_CANCEL Then Exit Do
        vt_tui_rect_fill(fx + 1, fy + 1, fw - 2, fh - 2, 32, VT_BLACK, VT_LIGHT_GREY)
        vt_tui_window(fx, fy, fw, fh, " Network ", VT_TUI_WIN_SHADOW)
        vt_tui_form_draw(items(), focused)
        vt_color(VT_DARK_GREY, VT_LIGHT_GREY)
        vt_locate(fy + 17, fx + 2)
        vt_print("Autojoin: #chan key, #other   Perform commands: /perform in the server window")
        vt_sleep(10)
    Loop
    If result = 1 Then
        Dim nm As String = fi_val(items(), 1)
        If Len(nm) > 0 AndAlso (LCase(nm) = LCase(nets(ni).name) OrElse net_find(nm) < 0) Then nets(ni).name = nm
        nets(ni).srv_count = 0
        Dim a() As String
        Dim na As Long = str_split(fi_val(items(), 3), ",", a())
        For k = 0 To na - 1
            Dim e As srv_entry
            If srv_parse(Trim(a(k)), e) AndAlso nets(ni).srv_count < SRV_MAX Then
                nets(ni).servers(nets(ni).srv_count) = e
                nets(ni).srv_count += 1
            End If
        Next k
        nets(ni).nick = fi_val(items(), 6)
        nets(ni).altnicks = fi_val(items(), 8)
        nets(ni).username = fi_val(items(), 10)
        nets(ni).realname = fi_val(items(), 12)
        If items(15).checked Then
            nets(ni).login = LOGIN_SASL
        ElseIf items(16).checked Then
            nets(ni).login = LOGIN_NICKSERV
        ElseIf items(17).checked Then
            nets(ni).login = LOGIN_SERVERPASS
        Else
            nets(ni).login = LOGIN_NONE
        End If
        nets(ni).login_user = fi_val(items(), 19)
        nets(ni).login_pass = from437(items(21).val)
        nets(ni).aj_count = 0
        na = str_split(fi_val(items(), 23), ",", a())
        For k = 0 To na - 1
            If Len(Trim(a(k))) > 0 Then net_add_autojoin(ni, Trim(a(k)))
        Next k
        nets(ni).charset = LCase(fi_val(items(), 25))
        nets(ni).autoconnect = items(26).checked
        nets(ni).accept_invalid_cert = items(27).checked
        config_save()
    End If
    dlg_end()
    Return result
End Function

Sub dlg_networks()
    Dim fw As Long = 72
    Dim fh As Long = 22
    Dim fx As Long, fy As Long
    dlg_origin(fw, fh, fx, fy)
    Dim items(0 To 5) As vt_tui_form_item
    fi_button(items(), 0, 2, fh - 3, "Connect", 1)
    fi_button(items(), 1, 14, fh - 3, "Add", 2)
    fi_button(items(), 2, 22, fh - 3, "Edit", 3)
    fi_button(items(), 3, 31, fh - 3, "Remove", 4)
    fi_button(items(), 4, 42, fh - 3, "Perform", 5)
    fi_button(items(), 5, fw - 11, fh - 3, "Close", 6)
    vt_tui_form_offset(items(), fx, fy)
    Dim st As vt_tui_listbox_state
    st.last_click_item = -1
    Dim focused As Long = 0
    Do
        Dim shown() As String
        Dim i As Long
        ReDim shown(0 To IIf(net_count > 0, net_count - 1, 0))
        For i = 0 To net_count - 1
            Dim srv As String = IIf(nets(i).srv_count > 0, srv_format(nets(i).servers(0)), "(no server)")
            If InStr(srv, "/") > 0 Then
                ' hide passwords: host/port/tls only
                Dim sp() As String
                Dim ns As Long = str_split(srv, "/", sp())
                srv = sp(0) & "/" & IIf(ns > 1, sp(1), "") & IIf(ns > 2, "/" & sp(2), "")
            End If
            Dim c As Long = conn_find(nets(i).name)
            Dim flag As String = IIf(conn_online(c), "* ", "  ")
            shown(i) = flag & utf8_pad(nets(i).name, 22) & Chr(1) & " " & utf8_pad(srv, 32) & Chr(1) & IIf(nets(i).autoconnect, " auto", "")
        Next i
        If net_count = 0 Then shown(0) = "(no networks -- press Add)"
        dlg_begin()
        Dim action As Long = 0
        Do
            Dim k As ULong = vt_inkey()
            Dim nav As Byte = IIf(VT_SCAN(k) = VT_KEY_UP OrElse VT_SCAN(k) = VT_KEY_DOWN OrElse _
                                  VT_SCAN(k) = VT_KEY_PGUP OrElse VT_SCAN(k) = VT_KEY_PGDN, 1, 0)
            Dim lr As Long = vt_tui_listbox_handle(fx + 2, fy + 3, fw - 4, fh - 7, shown(), st, IIf(nav OrElse VT_SCAN(k) = VT_KEY_ENTER, k, 0))
            If lr >= 0 Then action = 1 : Exit Do
            Dim r As Long = vt_tui_form_handle(items(), focused, IIf(nav OrElse VT_SCAN(k) = VT_KEY_ENTER, 0, k))
            If r >= 1 AndAlso r <= 6 Then action = r : Exit Do
            If r = VT_FORM_CANCEL Then action = 6 : Exit Do
            If VT_SCAN(k) = VT_KEY_DEL Then action = 4 : Exit Do
            vt_tui_rect_fill(fx + 1, fy + 1, fw - 2, fh - 2, 32, VT_BLACK, VT_LIGHT_GREY)
            vt_tui_window(fx, fy, fw, fh, " Networks ", VT_TUI_WIN_SHADOW)
            vt_color(VT_DARK_GREY, VT_LIGHT_GREY)
            vt_locate(fy + 1, fx + 2)
            vt_print("Enter / double-click connects.  * = connected")
            ui_listbox_draw(fx + 2, fy + 3, fw - 4, fh - 7, shown(), st)
            vt_tui_form_draw(items(), focused)
            vt_sleep(10)
        Loop
        dlg_end()
        Dim sel As Long = st.sel
        Select Case action
        Case 1
            If sel >= 0 AndAlso sel < net_count Then
                Dim c As Long = conn_find(nets(sel).name)
                If c < 0 Then c = conn_new(sel, nets(sel).name)
                If c >= 0 Then
                    ui_switch(conns(c).status_buf)
                    conn_connect(c)
                End If
                Exit Do
            End If
        Case 2
            Dim nm As String = "New network"
            If dlg_input("Add network", "Name of the network:", nm) AndAlso Len(nm) > 0 Then
                Dim ni As Long = net_add(nm)
                If ni < 0 Then
                    dlg_message("Add network", "A network with that name already exists.")
                ElseIf dlg_network_edit(ni) = 0 Then
                    net_remove(ni)
                Else
                    st.sel = ni
                End If
                config_save()
            End If
        Case 3
            If sel >= 0 AndAlso sel < net_count Then dlg_network_edit(sel)
        Case 4
            If sel >= 0 AndAlso sel < net_count Then
                If dlg_confirm("Remove network", "Remove " & nets(sel).name & " from the list?") Then
                    net_remove(sel)
                    config_save()
                    If st.sel >= net_count AndAlso st.sel > 0 Then st.sel -= 1
                End If
            End If
        Case 5
            If sel >= 0 AndAlso sel < net_count Then
                Dim pl() As String
                Dim pn As Long = nets(sel).pf_count
                ReDim pl(0 To IIf(pn > 0, pn - 1, 0))
                For i = 0 To pn - 1
                    pl(i) = nets(sel).perform(i)
                Next i
                If dlg_list_edit("Perform: " & nets(sel).name, "Command run after connecting, e.g. /mode $nick +x", pl(), pn) Then
                    With nets(sel)
                        ReDim .perform(0 To IIf(pn > 0, pn - 1, 0))
                        For i = 0 To pn - 1
                            .perform(i) = pl(i)
                        Next i
                        .pf_count = pn
                    End With
                    config_save()
                End If
            End If
        Case Else
            Exit Do
        End Select
    Loop
End Sub

' ---------------------------------------------------------------- settings
Type set_meta
    key  As String
    kind As Long        ' 0 = on/off, 1 = number, 2 = text, 3 = choice
    desc As String
    ch   As String      ' choices "a|b|c" (value = index)
End Type

Dim Shared smeta(0 To 79) As set_meta
Dim Shared smeta_n As Long

Private Sub sm(ByRef k As String, kind As Long, ByRef d As String, ByRef ch As String = "")
    smeta(smeta_n).key = k : smeta(smeta_n).kind = kind : smeta(smeta_n).desc = d : smeta(smeta_n).ch = ch
    smeta_n += 1
End Sub

Private Sub smeta_init()
    If smeta_n > 0 Then Exit Sub
    sm("nick", 2, "Default nick (networks can override it)")
    sm("altnicks", 2, "Alternative nicks, comma separated")
    sm("username", 2, "User name (ident)")
    sm("realname", 2, "Real name shown in WHOIS")
    sm("quit_msg", 2, "Quit message")
    sm("part_msg", 2, "Part message")
    sm("away_msg", 2, "Default away message")
    sm("theme", 3, "Colour theme", "dark|classic|light")
    sm("font_size", 3, "Font size (restart needed)", "normal 8x16|large 16x32|huge 24x48")
    sm("renderer_hw", 0, "Hardware accelerated rendering (restart needed)")
    sm("show_time", 0, "Show timestamps")
    sm("time_fmt", 2, "Timestamp format (%H %M %S %d %m %Y)")
    sm("nick_width", 1, "Width of the nick column (0 = no alignment)")
    sm("show_tree", 0, "Show the window tree (F7)")
    sm("show_nicklist", 0, "Show the nick list (F8)")
    sm("tree_width", 1, "Width of the window tree")
    sm("nicklist_width", 1, "Width of the nick list")
    sm("show_topic", 0, "Show the topic bar")
    sm("colored_nicks", 0, "Colour nicks")
    sm("strip_colors", 0, "Ignore mIRC colours and formatting in messages")
    sm("hide_joinpart", 3, "Join / part / quit messages", "show all|hide inactive users|hide all")
    sm("smart_minutes", 1, "Users who spoke within this many minutes are never hidden")
    sm("whois_to_active", 0, "Show WHOIS replies in the current window")
    sm("scrollback", 1, "Lines kept per window")
    sm("unicode_font", 0, "Load the full Unicode font file (CJK etc.) if present")
    sm("reconnect", 0, "Reconnect automatically")
    sm("reconnect_max_s", 1, "Longest wait between reconnect attempts (seconds)")
    sm("rejoin_on_kick", 0, "Rejoin a channel after being kicked")
    sm("ping_timeout_s", 1, "Seconds without server reply before reconnecting")
    sm("flood_burst", 1, "Lines sent at once before flood control starts")
    sm("flood_rate_ms", 1, "Milliseconds between lines under flood control")
    sm("ctcp_reply", 0, "Answer CTCP VERSION / PING / TIME")
    sm("raw_unknown", 0, "Send unknown /commands to the server")
    sm("remember_chans", 0, "/join and /part update the network's autojoin list")
    sm("confirm_paste", 1, "Ask before pasting more than this many lines (0 = never)")
    sm("auto_away_min", 1, "Set away after this many idle minutes (0 = off)")
    sm("beep", 0, "Sound on highlights and private messages")
    sm("flash", 0, "Flash the taskbar on highlights")
    sm("notify_send", 0, "Desktop notifications (Linux notify-send)")
    sm("notify_pm", 0, "Notify on private messages")
    sm("log_enabled", 0, "Log channels and server windows")
    sm("log_pm", 0, "Log private conversations")
    sm("log_replay", 1, "Log lines replayed when a window opens")
    sm("dcc_dir", 2, "Folder for received DCC files (empty = downloads folder)")
    sm("dcc_auto_accept", 0, "Accept DCC file offers automatically")
    sm("dcc_port_lo", 1, "Lowest port for DCC listening (0 = any)")
    sm("dcc_port_hi", 1, "Highest port for DCC listening")
    sm("dcc_ip", 2, "IP address announced for DCC (empty = automatic)")
    sm("dcc_passive", 0, "Use passive (reverse) DCC for sending")
    sm("proxy_kind", 3, "Proxy for all networks", "none|SOCKS5|HTTP CONNECT")
    sm("proxy_host", 2, "Proxy host")
    sm("proxy_port", 1, "Proxy port")
    sm("proxy_user", 2, "Proxy user")
    sm("proxy_pass", 2, "Proxy password")
End Sub

Private Function smeta_value_text(i As Long) As String
    Dim v As String = ini_get(cfg_ini, "global", smeta(i).key)
    Select Case smeta(i).kind
    Case 0 : Return IIf(str_to_int(v, 0) <> 0, "on", "off")
    Case 3
        Dim a() As String
        Dim n As Long = str_split(smeta(i).ch, "|", a())
        Dim k As Long = str_to_int(v, 0)
        If k >= 0 AndAlso k < n Then Return a(k)
    End Select
    If InStr(smeta(i).key, "pass") > 0 AndAlso Len(v) > 0 Then Return "********"
    Return v
End Function

Sub dlg_settings()
    smeta_init()
    Dim fw As Long = 76
    Dim fh As Long = 24
    If fh > vt_rows() - 2 Then fh = vt_rows() - 2
    Dim fx As Long, fy As Long
    dlg_origin(fw, fh, fx, fy)
    Dim items(0 To 1) As vt_tui_form_item
    fi_button(items(), 0, 2, fh - 3, "Change", 1)
    fi_button(items(), 1, fw - 11, fh - 3, "Close", 2)
    vt_tui_form_offset(items(), fx, fy)
    Dim st As vt_tui_listbox_state
    st.last_click_item = -1
    Dim focused As Long = 0
    Do
        settings_to_ini()
        Dim shown(0 To smeta_n - 1) As String
        Dim i As Long
        For i = 0 To smeta_n - 1
            shown(i) = utf8_pad(smeta(i).key, 18) & Chr(1) & " " & Chr(1) & utf8_truncate_width(smeta_value_text(i), 50)
        Next i
        dlg_begin()
        Dim action As Long = 0
        Do
            Dim k As ULong = vt_inkey()
            Dim nav As Byte = IIf(VT_SCAN(k) = VT_KEY_UP OrElse VT_SCAN(k) = VT_KEY_DOWN OrElse _
                                  VT_SCAN(k) = VT_KEY_PGUP OrElse VT_SCAN(k) = VT_KEY_PGDN OrElse _
                                  VT_SCAN(k) = VT_KEY_HOME OrElse VT_SCAN(k) = VT_KEY_END, 1, 0)
            Dim lr As Long = vt_tui_listbox_handle(fx + 2, fy + 1, fw - 4, fh - 7, shown(), st, IIf(nav OrElse VT_SCAN(k) = VT_KEY_ENTER, k, 0))
            If lr >= 0 Then action = 1 : Exit Do
            Dim r As Long = vt_tui_form_handle(items(), focused, IIf(nav OrElse VT_SCAN(k) = VT_KEY_ENTER, 0, k))
            If r = 1 Then action = 1 : Exit Do
            If r = 2 OrElse r = VT_FORM_CANCEL Then action = 2 : Exit Do
            vt_tui_rect_fill(fx + 1, fy + 1, fw - 2, fh - 2, 32, VT_BLACK, VT_LIGHT_GREY)
            vt_tui_window(fx, fy, fw, fh, " Preferences ", VT_TUI_WIN_SHADOW)
            ui_listbox_draw(fx + 2, fy + 1, fw - 4, fh - 7, shown(), st)
            vt_color(VT_BLUE, VT_LIGHT_GREY)
            vt_locate(fy + fh - 5, fx + 2)
            If st.sel >= 0 AndAlso st.sel < smeta_n Then vt_print(Left(smeta(st.sel).desc & Space(fw - 4), fw - 4))
            vt_tui_form_draw(items(), focused)
            vt_sleep(10)
        Loop
        dlg_end()
        If action <> 1 Then Exit Do
        Dim si As Long = st.sel
        If si < 0 OrElse si >= smeta_n Then Continue Do
        Dim key As String = smeta(si).key
        Dim cur As String = ini_get(cfg_ini, "global", key)
        Select Case smeta(si).kind
        Case 0
            ini_set(cfg_ini, "global", key, IIf(str_to_int(cur, 0) <> 0, "0", "1"))
        Case 3
            Dim a() As String
            Dim n As Long = str_split(smeta(si).ch, "|", a())
            Dim pick As Long = dlg_popup(fx + 20, fy + 3 + (si - st.top_item), a(), n)
            If pick >= 0 Then ini_set(cfg_ini, "global", key, int_str(pick))
        Case Else
            Dim v As String = cur
            If dlg_input(key, smeta(si).desc, v) Then
                If smeta(si).kind = 1 AndAlso str_to_int(v, -999999) = -999999 Then
                    dlg_message(key, "Please enter a number.")
                Else
                    ini_set(cfg_ini, "global", key, v)
                End If
            End If
        End Select
        settings_from_ini()
        buf_default_hist = cfg.scrollback
        config_save()
        If key = "font_size" OrElse key = "renderer_hw" Then app_need_restart = 1
        ui_settings_changed()
    Loop
    If app_need_restart Then dlg_message("Preferences", "Font and renderer changes take effect after restarting vtirc-ng.")
End Sub

' ---------------------------------------------------------------- channel list
Sub dlg_chanlist(c As Long)
    If conn_online(c) = 0 Then dlg_message("Channel list", "Connect to a network first.") : Exit Sub
    If conns(c).ls_count = 0 AndAlso conns(c).ls_active = 0 Then
        conns(c).ls_active = 1
        conn_send(c, "LIST")
    End If
    Dim fw As Long = vt_cols() - 6
    Dim fh As Long = vt_rows() - 4
    If fw > 110 Then fw = 110
    Dim fx As Long, fy As Long
    dlg_origin(fw, fh, fx, fy)
    Dim items(0 To 5) As vt_tui_form_item
    fi_label(items(), 0, 2, 1, 8, "Filter:")
    fi_input(items(), 1, 10, 1, 30, 60, "")
    fi_button(items(), 2, 2, fh - 3, "Join", 1)
    fi_button(items(), 3, 11, fh - 3, "Refresh", 2)
    fi_button(items(), 4, 23, fh - 3, "Sort", 3)
    fi_button(items(), 5, fw - 11, fh - 3, "Close", 4)
    vt_tui_form_offset(items(), fx, fy)
    Dim st As vt_tui_listbox_state
    st.last_click_item = -1
    Dim focused As Long = 1
    Dim shown() As String
    Dim idx() As Long
    Dim nshown As Long = 0
    Dim last_count As Long = -1
    Dim last_filter As String = Chr(1)
    Dim by_name As Byte = 0
    Dim join_ch As String = ""
    dlg_begin()
    Do
        Dim k As ULong = vt_inkey()
        If conns(c).ls_count <> last_count OrElse items(1).val <> last_filter Then
            last_count = conns(c).ls_count
            last_filter = items(1).val
            Dim f As String = utf8_lcase(from437(last_filter))
            ReDim idx(0 To IIf(last_count > 0, last_count - 1, 0))
            nshown = 0
            Dim i As Long
            For i = 0 To last_count - 1
                If Len(f) = 0 OrElse InStr(utf8_lcase(conns(c).ls_name(i)), f) > 0 OrElse _
                   InStr(utf8_lcase(conns(c).ls_topic(i)), f) > 0 Then
                    idx(nshown) = i
                    nshown += 1
                End If
            Next i
            ' sort: users (descending) or name
            Dim gap As Long = nshown \ 2
            While gap > 0
                For i = gap To nshown - 1
                    Dim t As Long = idx(i)
                    Dim j As Long = i
                    While j >= gap
                        Dim a As Long = idx(j - gap)
                        Dim bigger As Byte
                        If by_name Then
                            bigger = IIf(LCase(conns(c).ls_name(a)) > LCase(conns(c).ls_name(t)), 1, 0)
                        Else
                            bigger = IIf(conns(c).ls_users(a) < conns(c).ls_users(t), 1, 0)
                        End If
                        If bigger = 0 Then Exit While
                        idx(j) = a
                        j -= gap
                    Wend
                    idx(j) = t
                Next i
                gap \= 2
            Wend
            ReDim shown(0 To IIf(nshown > 0, nshown - 1, 0))
            For i = 0 To nshown - 1
                Dim ri As Long = idx(i)
                shown(i) = utf8_pad(conns(c).ls_name(ri), 24) & Chr(1) & " " & Right(Space(6) & conns(c).ls_users(ri), 6) & "  " & Chr(1) & conns(c).ls_topic(ri)
            Next i
            If nshown = 0 Then shown(0) = IIf(conns(c).ls_active, "(receiving the list...)", "(no channels match)")
            If st.sel >= nshown Then st.sel = 0 : st.top_item = 0
        End If
        Dim nav As Byte = IIf(VT_SCAN(k) = VT_KEY_UP OrElse VT_SCAN(k) = VT_KEY_DOWN OrElse _
                              VT_SCAN(k) = VT_KEY_PGUP OrElse VT_SCAN(k) = VT_KEY_PGDN, 1, 0)
        Dim lr As Long = vt_tui_listbox_handle(fx + 2, fy + 4, fw - 4, fh - 8, shown(), st, IIf(nav, k, 0))
        If VT_SCAN(k) = VT_KEY_ENTER OrElse lr >= 0 Then
            If nshown > 0 Then join_ch = conns(c).ls_name(idx(st.sel))
            Exit Do
        End If
        Dim r As Long = vt_tui_form_handle(items(), focused, IIf(nav, 0, k))
        Select Case r
        Case 1
            If nshown > 0 Then join_ch = conns(c).ls_name(idx(st.sel))
            Exit Do
        Case 2
            conns(c).ls_count = 0
            conns(c).ls_active = 1
            conn_send(c, "LIST")
            last_count = -1
        Case 3
            by_name = 1 - by_name
            last_count = -1
        Case 4, VT_FORM_CANCEL
            Exit Do
        End Select
        vt_tui_rect_fill(fx + 1, fy + 1, fw - 2, fh - 2, 32, VT_BLACK, VT_LIGHT_GREY)
        vt_tui_window(fx, fy, fw, fh, " Channels on " & to437(conns(c).name) & ": " & conns(c).ls_count & _
                      IIf(conns(c).ls_active, " (loading)", "") & " ", VT_TUI_WIN_SHADOW)
        vt_color(VT_DARK_GREY, VT_LIGHT_GREY)
        vt_locate(fy + 3, fx + 2)
        vt_print(Left("Channel" & Space(25), 25) & " Users  Topic" & IIf(by_name, "   (sorted by name)", "   (sorted by users)"))
        ui_listbox_draw(fx + 2, fy + 4, fw - 4, fh - 8, shown(), st)
        vt_tui_form_draw(items(), focused)
        vt_sleep(10)
    Loop
    dlg_end()
    If Len(join_ch) > 0 Then cmd_execute(conns(c).status_buf, "/join " & join_ch)
End Sub

' ---------------------------------------------------------------- help, about
Function help_text() As String
    Dim t As String
    t = " vtirc-ng " & VTIRC_VERSION & " -- quick manual" & VT_LF & VT_LF
    t &= " WINDOWS" & VT_LF
    t &= "  Alt+1..9, Alt+0     window 1..10 (numbers in the tree)" & VT_LF
    t &= "  Alt+Left/Right      previous / next window (also Ctrl+PgUp/PgDn)" & VT_LF
    t &= "  Ctrl+Tab            next window" & VT_LF
    t &= "  Alt+A               next window with activity" & VT_LF
    t &= "  Ctrl+W              close window (parts channels)" & VT_LF
    t &= "  F7 / F8             show or hide window tree / nick list" & VT_LF & VT_LF
    t &= " KEYS" & VT_LF
    t &= "  F1 help  F2 networks  F3 preferences  F4 channel list  F10 menu" & VT_LF
    t &= "  PgUp/PgDn           scroll history, Ctrl+Home/End top/bottom" & VT_LF
    t &= "  Up/Down             input history" & VT_LF
    t &= "  Tab / Shift+Tab     complete nicks, #channels, /commands" & VT_LF
    t &= "  Ctrl+F              search the window (/lastlog)" & VT_LF
    t &= "  Ctrl+B bold  Ctrl+U underline  Ctrl+I italic  Ctrl+K colour" & VT_LF
    t &= "  Ctrl+R reverse  Ctrl+T strike  Ctrl+O reset formatting" & VT_LF
    t &= "  Shift+Ins / Ctrl+V / middle click   paste" & VT_LF & VT_LF
    t &= " MOUSE" & VT_LF
    t &= "  Drag in the chat to select text (copied when you release)." & VT_LF
    t &= "  Click a URL to open it. Double-click a nick to open a query." & VT_LF
    t &= "  Right-click a nick, a window or the chat for a menu." & VT_LF & VT_LF
    t &= " COMMANDS (type /help <command> for details)" & VT_LF
    Dim names() As String
    Dim n As Long = cmd_names(names())
    Dim i As Long, j As Long
    For i = 1 To n - 1
        Dim tmp As String = names(i)
        j = i - 1
        While j >= 0 AndAlso names(j) > tmp
            names(j + 1) = names(j)
            j -= 1
        Wend
        names(j + 1) = tmp
    Next i
    For i = 0 To n - 1
        Dim ci As Long = cmd_find(names(i))
        If ci >= 0 Then t &= "  " & Left(cmds(ci).usage & Space(40), 40) & " " & cmds(ci).help & VT_LF
    Next i
    t &= VT_LF & " FILES" & VT_LF
    t &= "  Settings: " & cfg_path & VT_LF
    t &= "  Logs    : " & path_log_dir & VT_LF
    t &= "  Put an empty file named 'portable' next to the program to keep" & VT_LF
    t &= "  everything in the program's folder." & VT_LF
    Return t
End Function

Sub dlg_help()
    Dim fw As Long = vt_cols() - 4
    Dim fh As Long = vt_rows() - 3
    If fw > 120 Then fw = 120
    Dim fx As Long, fy As Long
    dlg_origin(fw, fh, fx, fy)
    Dim ed As vt_tui_editor_state
    ed.work = help_text()
    ed.cpos = 0
    ed.top_ln = 0
    ed.flags = VT_TUI_ED_READONLY
    dlg_begin()
    Do
        Dim k As ULong = vt_inkey()
        If VT_SCAN(k) = VT_KEY_ESC OrElse VT_SCAN(k) = VT_KEY_F1 OrElse VT_SCAN(k) = VT_KEY_ENTER Then Exit Do
        vt_tui_editor_handle(fx + 1, fy + 1, fw - 2, fh - 3, ed, k)
        vt_tui_rect_fill(fx + 1, fy + 1, fw - 2, fh - 2, 32, VT_BLACK, VT_LIGHT_GREY)
        vt_tui_window(fx, fy, fw, fh, " Help -- Esc closes ", VT_TUI_WIN_SHADOW)
        vt_tui_editor_draw(fx + 1, fy + 1, fw - 2, fh - 3, ed)
        vt_sleep(10)
    Loop
    dlg_end()
End Sub

Sub dlg_about()
    dlg_message("About", VTIRC_NAME & " " & VTIRC_VERSION & VT_LF & _
                "A full-featured IRC client written in FreeBASIC on libvt." & VT_LF & VT_LF & _
                "Based on VTIRC by Rene Breitinger (MIT licence)." & VT_LF & _
                "Glyphs: GNU Unifont (SIL OFL 1.1)." & VT_LF & _
                "Config: " & path_cfg_dir)
End Sub
