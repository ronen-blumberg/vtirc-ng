' =============================================================================
' src/ui/input.bas -- the input line: UTF-8 editing, history, completion
' =============================================================================

Dim Shared in_text As String          ' UTF-8, may contain mIRC formatting codes
Dim Shared in_pos As Long             ' cursor as a byte offset
Dim Shared in_view As Long            ' first visible display column
Const IN_HIST_MAX = 200
Dim Shared in_hist(0 To IN_HIST_MAX - 1) As String
Dim Shared in_hist_n As Long
Dim Shared in_hist_pos As Long = -1   ' -1 = editing a new line
Dim Shared in_saved As String

' tab completion
Dim Shared tc_on As Byte
Dim Shared tc_list() As String
Dim Shared tc_n As Long
Dim Shared tc_i As Long
Dim Shared tc_start As Long           ' byte offset where the completed word starts
Dim Shared tc_after As String         ' text after the cursor when completion began
Dim Shared tc_first As Byte           ' completing the first word of the line

Sub input_set(ByRef s As String)
    in_text = s
    in_pos = Len(s)
    in_view = 0
    tc_on = 0
    ui_dirty = 1
End Sub

Sub input_insert(ByRef s As String)
    If Len(in_text) + Len(s) > 4000 Then Exit Sub
    in_text = Left(in_text, in_pos) & s & Mid(in_text, in_pos + 1)
    in_pos += Len(s)
    tc_on = 0
    ui_dirty = 1
End Sub

Private Function in_is_space(p As Long) As Byte
    Return IIf(p >= 0 AndAlso p < Len(in_text) AndAlso in_text[p] = 32, 1, 0)
End Function

Private Sub in_word_left()
    While in_pos > 0 AndAlso in_is_space(in_pos - 1)
        in_pos -= 1
    Wend
    While in_pos > 0 AndAlso in_is_space(in_pos - 1) = 0
        in_pos = utf8_prev(in_text, in_pos)
    Wend
End Sub

Private Sub in_word_right()
    While in_pos < Len(in_text) AndAlso in_is_space(in_pos) = 0
        in_pos = utf8_next(in_text, in_pos)
    Wend
    While in_pos < Len(in_text) AndAlso in_is_space(in_pos)
        in_pos += 1
    Wend
End Sub

Sub input_history_add(ByRef s As String)
    If Len(s) = 0 Then Exit Sub
    If in_hist_n > 0 AndAlso in_hist(in_hist_n - 1) = s Then Exit Sub
    If in_hist_n = IN_HIST_MAX Then
        Dim i As Long
        For i = 1 To IN_HIST_MAX - 1
            in_hist(i - 1) = in_hist(i)
        Next i
        in_hist_n -= 1
    End If
    in_hist(in_hist_n) = s
    in_hist_n += 1
End Sub

' ---------------------------------------------------------------- completion
Private Sub tc_add(ByRef s As String)
    If tc_n > UBound(tc_list) Then ReDim Preserve tc_list(0 To tc_n * 2 + 15)
    tc_list(tc_n) = s
    tc_n += 1
End Sub

Private Sub tc_build()
    tc_n = 0
    ReDim tc_list(0 To 31)
    Dim word As String = Mid(in_text, tc_start + 1, in_pos - tc_start)
    Dim lw As String = LCase(word)
    Dim id As Long = ui_active
    Dim c As Long = IIf(buf_valid(id), bufs(id).conn_id, -1)
    Dim i As Long
    If tc_first AndAlso Left(word, 1) = "/" Then
        Dim names() As String
        Dim n As Long = cmd_names(names())
        For i = 0 To n - 1
            If Left("/" & names(i), Len(lw)) = lw Then tc_add("/" & names(i))
        Next i
        ' sort alphabetically
        Dim j As Long
        For i = 1 To tc_n - 1
            Dim t As String = tc_list(i)
            j = i - 1
            While j >= 0 AndAlso tc_list(j) > t
                tc_list(j + 1) = tc_list(j)
                j -= 1
            Wend
            tc_list(j + 1) = t
        Next i
        Exit Sub
    End If
    If LCase(str_word(in_text, 0)) = "/set" AndAlso tc_start > 0 AndAlso InStr(Left(in_text, tc_start), " ") = tc_start Then
        settings_to_ini()
        For i = 0 To cfg_ini.cnt - 1
            If LCase(cfg_ini.ents(i).sec) = "global" AndAlso Left(LCase(cfg_ini.ents(i).key), Len(lw)) = lw Then tc_add(cfg_ini.ents(i).key)
        Next i
        Exit Sub
    End If
    If conn_valid(c) AndAlso conn_is_channel(c, word) Then
        For i = 0 To BUF_MAX - 1
            If bufs(i).alive AndAlso bufs(i).conn_id = c AndAlso bufs(i).kind = BK_CHANNEL Then
                If Left(LCase(bufs(i).name), Len(lw)) = lw Then tc_add(bufs(i).name)
            End If
        Next i
        Exit Sub
    End If
    If buf_valid(id) = 0 Then Exit Sub
    If bufs(id).kind = BK_QUERY Then
        If Left(LCase(bufs(id).name), Len(lw)) = lw Then tc_add(bufs(id).name)
        Exit Sub
    End If
    If bufs(id).kind <> BK_CHANNEL Then Exit Sub
    ' nicks: most recent speakers first, then alphabetical
    Dim idx() As Long
    Dim n2 As Long = 0
    ReDim idx(0 To IIf(bufs(id).user_count > 0, bufs(id).user_count - 1, 0))
    For i = 0 To bufs(id).user_count - 1
        If Left(LCase(bufs(id).users(i).nick), Len(lw)) = lw AndAlso conn_is_me(c, bufs(id).users(i).nick) = 0 Then
            idx(n2) = i
            n2 += 1
        End If
    Next i
    Dim a As Long
    Dim b As Long
    For a = 1 To n2 - 1
        Dim ti As Long = idx(a)
        b = a - 1
        While b >= 0
            Dim ub As irc_user = bufs(id).users(idx(b))
            Dim ut As irc_user = bufs(id).users(ti)
            Dim later As Byte
            If ub.last_spoke <> ut.last_spoke Then
                later = IIf(ub.last_spoke < ut.last_spoke, 1, 0)
            Else
                later = IIf(LCase(ub.nick) > LCase(ut.nick), 1, 0)
            End If
            If later = 0 Then Exit While
            idx(b + 1) = idx(b)
            b -= 1
        Wend
        idx(b + 1) = ti
    Next a
    For a = 0 To n2 - 1
        tc_add(bufs(id).users(idx(a)).nick)
    Next a
End Sub

Private Sub input_complete(backwards As Byte)
    If tc_on = 0 Then
        ' word before the cursor
        tc_start = in_pos
        While tc_start > 0 AndAlso in_text[tc_start - 1] <> 32
            tc_start -= 1
        Wend
        tc_first = IIf(tc_start = 0, 1, 0)
        tc_after = Mid(in_text, in_pos + 1)
        tc_build()
        If tc_n = 0 Then Exit Sub
        tc_on = 1
        tc_i = IIf(backwards, tc_n - 1, 0)
    Else
        If tc_n = 0 Then Exit Sub
        If backwards Then tc_i = (tc_i + tc_n - 1) Mod tc_n Else tc_i = (tc_i + 1) Mod tc_n
    End If
    Dim w As String = tc_list(tc_i)
    Dim is_nick As Byte = IIf(Left(w, 1) <> "/" AndAlso conn_is_channel(bufs(ui_active).conn_id, w) = 0, 1, 0)
    If tc_first AndAlso is_nick AndAlso buf_valid(ui_active) AndAlso bufs(ui_active).kind = BK_CHANNEL Then
        w &= ": "
    ElseIf Left(tc_after, 1) <> " " Then
        w &= " "
    End If
    in_text = Left(in_text, tc_start) & w & tc_after
    in_pos = tc_start + Len(w)
    ui_dirty = 1
End Sub

' ---------------------------------------------------------------- keys
' Handle an editing key. Returns 1 when the key was used.
Function input_key(k As ULong, cp As ULong) As Byte
    Dim sc As Long = VT_SCAN(k)
    Dim ch As Long = VT_CHAR(k)
    Dim ctl As Long = VT_CTRL(k)
    If VT_ALT(k) Then Return 0
    If sc <> VT_KEY_TAB Then tc_on = 0
    Select Case sc
    Case VT_KEY_LEFT
        If ctl Then in_word_left() Else in_pos = utf8_prev(in_text, in_pos)
    Case VT_KEY_RIGHT
        If ctl Then in_word_right() Else in_pos = utf8_next(in_text, in_pos)
    Case VT_KEY_HOME
        If ctl Then Return 0
        in_pos = 0
    Case VT_KEY_END
        If ctl Then Return 0
        in_pos = Len(in_text)
    Case VT_KEY_BKSP
        If in_pos = 0 Then Return 1
        Dim np As Long
        If ctl Then
            np = in_pos
            Dim save As Long = in_pos
            in_word_left()
            np = in_pos
            in_pos = save
        Else
            np = utf8_prev(in_text, in_pos)
        End If
        in_text = Left(in_text, np) & Mid(in_text, in_pos + 1)
        in_pos = np
    Case VT_KEY_DEL
        If in_pos >= Len(in_text) Then Return 1
        Dim nx As Long = utf8_next(in_text, in_pos)
        in_text = Left(in_text, in_pos) & Mid(in_text, nx + 1)
    Case VT_KEY_UP
        If in_hist_n = 0 Then Return 1
        If in_hist_pos = -1 Then
            in_saved = in_text
            in_hist_pos = in_hist_n - 1
        ElseIf in_hist_pos > 0 Then
            in_hist_pos -= 1
        End If
        in_text = in_hist(in_hist_pos) : in_pos = Len(in_text)
    Case VT_KEY_DOWN
        If in_hist_pos = -1 Then Return 1
        in_hist_pos += 1
        If in_hist_pos >= in_hist_n Then
            in_hist_pos = -1
            in_text = in_saved
        Else
            in_text = in_hist(in_hist_pos)
        End If
        in_pos = Len(in_text)
    Case VT_KEY_TAB
        If ctl Then Return 0
        input_complete(VT_SHIFT(k))
    Case VT_KEY_UNICODE
        If cp >= 32 Then input_insert(utf8_encode(cp))
    Case VT_KEY_ENTER, VT_KEY_ESC, VT_KEY_PGUP, VT_KEY_PGDN, VT_KEY_INS
        Return 0
    Case 0, VT_KEY_SPACE
        If ctl Then
            ' mIRC-style formatting keys and a few editing keys
            Select Case ch
            Case 2  : input_insert(Chr(2))          ' Ctrl+B bold
            Case 11 : input_insert(Chr(3))          ' Ctrl+K colour
            Case 21 : input_insert(Chr(31))         ' Ctrl+U underline
            Case 9  : input_insert(Chr(29))         ' Ctrl+I italic
            Case 18 : input_insert(Chr(22))         ' Ctrl+R reverse
            Case 15 : input_insert(Chr(15))         ' Ctrl+O reset
            Case 20 : input_insert(Chr(30))         ' Ctrl+T strikethrough
            Case 1  : in_pos = 0                    ' Ctrl+A start of line
            Case 5  : in_pos = Len(in_text)         ' Ctrl+E end of line
            Case 12 : input_set("")                 ' Ctrl+L clear the line
            Case Else : Return 0
            End Select
        ElseIf ch >= 32 Then
            Dim ucp As ULong = cp
            If ucp = 0 Then ucp = ch
            input_insert(utf8_encode(ucp))
        ElseIf sc = VT_KEY_SPACE Then
            input_insert(" ")
        Else
            Return 0
        End If
    Case Else
        Return 0
    End Select
    ui_dirty = 1
    Return 1
End Function

' ---------------------------------------------------------------- drawing
' Formatting control characters are shown as reversed letters (B, C, U ...).
Private Function in_ctl_glyph(b As UByte) As ULong
    Select Case b
    Case 2  : Return Asc("B")
    Case 3  : Return Asc("C")
    Case 4  : Return Asc("D")
    Case 15 : Return Asc("O")
    Case 22 : Return Asc("R")
    Case 29 : Return Asc("I")
    Case 30 : Return Asc("S")
    Case 31 : Return Asc("U")
    End Select
    Return Asc("?")
End Function

Sub input_render()
    Dim row As Long = lay.input_row
    ui_fill(1, row, lay.w, row, th.input_fg, th.input_bg)
    Dim id As Long = ui_active
    Dim pre As String = ""
    If buf_valid(id) AndAlso conn_valid(bufs(id).conn_id) Then pre = conns(bufs(id).conn_id).nick
    If Len(pre) > 20 Then pre = Left(pre, 20)
    Dim x As Long = 1
    If Len(pre) > 0 Then
        x += ui_text(x, row, 22, "[" & pre & "] ", th.own, th.input_bg)
    End If
    Dim avail As Long = lay.w - x
    If avail < 5 Then Exit Sub
    ' cells of the whole line (control codes as single glyph cells)
    Static cps() As ULong
    Static wid() As UByte
    Static ctl() As UByte
    Static src() As Long
    Dim n As Long = 0
    Dim p As Long = 0
    If UBound(cps) < Len(in_text) + 2 Then
        ReDim cps(0 To Len(in_text) + 16) : ReDim wid(0 To Len(in_text) + 16)
        ReDim ctl(0 To Len(in_text) + 16) : ReDim src(0 To Len(in_text) + 16)
    End If
    Dim cur_cell As Long = -1
    While p < Len(in_text)
        If p = in_pos Then cur_cell = n
        src(n) = p
        Dim b As UByte = in_text[p]
        If b < 32 Then
            cps(n) = in_ctl_glyph(b) : wid(n) = 1 : ctl(n) = 1 : p += 1
        Else
            cps(n) = utf8_decode(in_text, p)
            wid(n) = utf8_cp_width(cps(n))
            ctl(n) = 0
            If wid(n) = 0 Then Continue While
        End If
        n += 1
    Wend
    If cur_cell < 0 Then cur_cell = n
    If n > 0 AndAlso arabic_present(cps(), n) Then
        Static akeep() As Byte
        arabic_shape(cps(), n, akeep())
        For i As Long = 0 To n - 1
            If akeep(i) = 0 Then wid(i) = 0
        Next i
    End If
    ' column of the cursor in logical layout
    Dim ccol As Long = 0
    Dim i As Long
    For i = 0 To cur_cell - 1
        ccol += wid(i)
    Next i
    If ccol < in_view Then in_view = ccol
    If ccol - in_view > avail - 1 Then in_view = ccol - avail + 1
    If in_view < 0 Then in_view = 0
    ' visible logical cells
    Dim col As Long = 0
    Dim a As Long = -1
    Dim e As Long = n
    For i = 0 To n - 1
        If col >= in_view AndAlso a < 0 Then a = i
        If col + wid(i) - in_view > avail Then e = i : Exit For
        col += wid(i)
    Next i
    If a < 0 Then a = n
    ' bidi over the visible part (control glyphs stay neutral)
    Dim m As Long = e - a
    Dim cursor_x As Long = x + (ccol - in_view)
    If m > 0 Then
        Dim vcps() As ULong
        ReDim vcps(0 To m - 1)
        For i = 0 To m - 1
            vcps(i) = IIf(ctl(a + i), 32, cps(a + i))
        Next i
        Dim ord() As Long
        Dim lv() As UByte
        Dim use_bidi As Byte = bidi_needed(vcps(), m)
        If use_bidi Then bidi_reorder(vcps(), m, ord(), lv())
        Dim cx As Long = x
        For i = 0 To m - 1
            Dim li As Long = IIf(use_bidi, ord(i), i)
            Dim c2 As ULong = cps(a + li)
            If use_bidi AndAlso (lv(li) And 1) AndAlso ctl(a + li) = 0 Then c2 = bidi_mirror(c2)
            If a + li = cur_cell Then cursor_x = cx
            If ctl(a + li) Then
                vt_set_cell(cx, row, c2, th.input_bg, th.input_fg)
                cx += 1
            Else
                cx += ui_put(cx, row, c2, th.input_fg, th.input_bg, 0, wid(a + li))
            End If
        Next i
        If cur_cell >= e Then cursor_x = cx
    End If
    If cursor_x > lay.w Then cursor_x = lay.w
    vt_locate(row, cursor_x, 1)
End Sub
