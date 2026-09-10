' =============================================================================
' src/ui/text.bas -- formatted text -> screen cells, wrapping, bidi, URLs
' =============================================================================

Type ucell
    cp   As ULong
    fg   As UByte
    bg   As UByte
    attr As UByte
    w    As UByte          ' display width 1 or 2
    src  As Long           ' byte offset of the character in the source text
    url  As Long           ' 1-based index into the URL list, 0 = none
End Type

' Build cells from UTF-8 text with mIRC formatting codes. Returns the count.
' strip = 1 ignores colours (keeps bold/underline/etc. off too).
Function text_cells(ByRef s As String, base_fg As UByte, base_bg As UByte, cells() As ucell, _
                    strip As Byte = 0) As Long
    Dim n As Long = 0
    Dim p As Long = 0
    Dim slen As Long = Len(s)
    Dim fg As UByte = base_fg
    Dim bg As UByte = base_bg
    Dim attr As UByte = 0
    Dim rev As Byte = 0
    If UBound(cells) < slen Then ReDim cells(0 To slen + 16)
    While p < slen
        Dim b As UByte = s[p]
        Select Case b
        Case 2  : p += 1 : If strip = 0 Then attr Xor= VT_ATTR_BOLD
        Case 29 : p += 1 : If strip = 0 Then attr Xor= VT_ATTR_ITALIC
        Case 30 : p += 1 : If strip = 0 Then attr Xor= VT_ATTR_STRIKE
        Case 31 : p += 1 : If strip = 0 Then attr Xor= VT_ATTR_UNDERLINE
        Case 22 : p += 1 : If strip = 0 Then rev Xor= 1
        Case 17 : p += 1                                    ' monospace: no-op
        Case 15 : p += 1 : fg = base_fg : bg = base_bg : attr = 0 : rev = 0
        Case 3
            p += 1
            Dim d1 As Long = -1
            Dim d2 As Long = -1
            Dim k As Long = 0
            While k < 2 AndAlso p < slen AndAlso s[p] >= 48 AndAlso s[p] <= 57
                d1 = IIf(d1 < 0, 0, d1) * 10 + (s[p] - 48) : p += 1 : k += 1
            Wend
            If d1 >= 0 AndAlso p + 1 < slen AndAlso s[p] = Asc(",") AndAlso s[p + 1] >= 48 AndAlso s[p + 1] <= 57 Then
                p += 1 : k = 0
                While k < 2 AndAlso p < slen AndAlso s[p] >= 48 AndAlso s[p] <= 57
                    d2 = IIf(d2 < 0, 0, d2) * 10 + (s[p] - 48) : p += 1 : k += 1
                Wend
            End If
            If strip = 0 Then
                If d1 < 0 Then
                    fg = base_fg : bg = base_bg
                Else
                    If d1 <> 99 Then fg = mirc_to_vga(d1, base_fg) Else fg = base_fg
                    If d2 >= 0 Then
                        If d2 <> 99 Then bg = mirc_to_vga(d2, base_bg) Else bg = base_bg
                    End If
                End If
            End If
        Case 4
            ' hex colour ^DRRGGBB[,RRGGBB]
            p += 1
            Dim hx As String = ""
            While Len(hx) < 6 AndAlso p < slen AndAlso ((s[p] >= 48 AndAlso s[p] <= 57) OrElse _
                  ((s[p] Or 32) >= 97 AndAlso (s[p] Or 32) <= 102))
                hx &= Chr(s[p]) : p += 1
            Wend
            If Len(hx) = 6 Then
                If strip = 0 Then fg = rgb_to_vga(ValUInt("&h" & hx))
                If p + 6 < slen AndAlso s[p] = Asc(",") Then
                    If strip = 0 Then bg = rgb_to_vga(ValUInt("&h" & Mid(s, p + 2, 6)))
                    p += 7
                End If
            ElseIf strip = 0 Then
                fg = base_fg : bg = base_bg
            End If
        Case 9
            ' tab -> space
            If n > UBound(cells) Then ReDim Preserve cells(0 To n * 2 + 16)
            cells(n).cp = 32 : cells(n).fg = IIf(rev, bg, fg) : cells(n).bg = IIf(rev, fg, bg)
            cells(n).attr = attr : cells(n).w = 1 : cells(n).src = p : cells(n).url = 0
            n += 1 : p += 1
        Case 0 To 31, 127
            p += 1
        Case Else
            Dim st As Long = p
            Dim cp As ULong = utf8_decode(s, p)
            Dim w As Long = utf8_cp_width(cp)
            If w > 0 Then
                If n > UBound(cells) Then ReDim Preserve cells(0 To n * 2 + 16)
                cells(n).cp = cp
                cells(n).fg = IIf(rev, bg, fg)
                cells(n).bg = IIf(rev, fg, bg)
                cells(n).attr = attr
                cells(n).w = w
                cells(n).src = st
                cells(n).url = 0
                n += 1
            End If
        End Select
    Wend
    Return n
End Function

' Plain text (UTF-8) of cells a..b-1.
Function cells_text(cells() As ucell, a As Long, b As Long) As String
    Dim r As String
    Dim i As Long
    For i = a To b - 1
        r &= utf8_encode(cells(i).cp)
    Next i
    Return r
End Function

' Mark URLs in the cells; their texts go into urls() (1-based via ucell.url).
Function text_find_urls(cells() As ucell, n As Long, urls() As String) As Long
    Dim cnt As Long = 0
    Dim i As Long = 0
    While i < n
        ' start of a word?
        If i = 0 OrElse cells(i - 1).cp = 32 OrElse cells(i - 1).cp = Asc("(") OrElse cells(i - 1).cp = Asc("<") OrElse _
           cells(i - 1).cp = Asc("""") OrElse cells(i - 1).cp = Asc("'") Then
            ' #channel names: clicking joins the channel
            If cells(i).cp = Asc("#") AndAlso i + 1 < n AndAlso cells(i + 1).cp > 32 AndAlso cells(i + 1).cp <> Asc("#") _
               AndAlso InStr(",.;:!?)", Chr(IIf(cells(i + 1).cp < 128, cells(i + 1).cp, 65))) = 0 Then
                Dim cj As Long = i + 1
                While cj < n AndAlso cells(cj).cp > 32 AndAlso cells(cj).cp <> Asc(",") AndAlso cells(cj).cp <> 7
                    cj += 1
                Wend
                While cj > i + 1 AndAlso cells(cj - 1).cp < 128 AndAlso InStr(".;:!?)'" & Chr(34), Chr(cells(cj - 1).cp)) > 0
                    cj -= 1
                Wend
                If cj - i >= 2 Then
                    cnt += 1
                    If cnt > UBound(urls) Then ReDim Preserve urls(0 To cnt * 2 + 3)
                    urls(cnt) = cells_text(cells(), i, cj)
                    Dim ck As Long
                    For ck = i To cj - 1
                        cells(ck).url = cnt
                    Next ck
                    i = cj
                    Continue While
                End If
            End If
            Dim pre As String = LCase(cells_text(cells(), i, IIf(i + 8 < n, i + 8, n)))
            If Left(pre, 7) = "http://" OrElse Left(pre, 8) = "https://" OrElse Left(pre, 4) = "www." OrElse _
               Left(pre, 6) = "ftp://" OrElse Left(pre, 6) = "irc://" OrElse Left(pre, 7) = "ircs://" Then
                Dim j As Long = i
                Dim parens As Long = 0
                While j < n AndAlso cells(j).cp > 32 AndAlso cells(j).cp <> Asc(">") AndAlso cells(j).cp <> Asc("""")
                    If cells(j).cp = Asc("(") Then parens += 1
                    If cells(j).cp = Asc(")") Then
                        If parens = 0 Then Exit While
                        parens -= 1
                    End If
                    j += 1
                Wend
                ' trailing punctuation is not part of the URL
                While j > i AndAlso InStr(".,;:!?'", Chr(cells(j - 1).cp)) > 0 AndAlso cells(j - 1).cp < 128
                    j -= 1
                Wend
                If j - i >= 5 Then
                    cnt += 1
                    If cnt > UBound(urls) Then ReDim Preserve urls(0 To cnt * 2 + 3)
                    urls(cnt) = cells_text(cells(), i, j)
                    Dim k As Long
                    For k = i To j - 1
                        cells(k).url = cnt
                    Next k
                    i = j
                    Continue While
                End If
            End If
        End If
        i += 1
    Wend
    Return cnt
End Function

' Word-wrap cells to `width` columns. row_start(r) = first cell of row r;
' row_start(rows) = n. Returns the number of rows (at least 1).
Function text_wrap(cells() As ucell, n As Long, wid As Long, row_start() As Long) As Long
    Dim rows As Long = 0
    Dim i As Long = 0
    If wid < 1 Then wid = 1
    If UBound(row_start) < 4 Then ReDim row_start(0 To 15)
    If n = 0 Then
        row_start(0) = 0 : row_start(1) = 0
        Return 1
    End If
    While i < n
        If rows + 1 > UBound(row_start) Then ReDim Preserve row_start(0 To rows * 2 + 16)
        row_start(rows) = i
        Dim w As Long = 0
        Dim j As Long = i
        Dim last_sp As Long = -1
        While j < n AndAlso w + cells(j).w <= wid
            If cells(j).cp = 32 Then last_sp = j
            w += cells(j).w
            j += 1
        Wend
        If j < n AndAlso last_sp > i AndAlso cells(j).cp <> 32 Then j = last_sp + 1
        If j = i Then j = i + 1
        rows += 1
        i = j
        ' the next row does not start with the space the line broke at
        ' (that space stays at the end of the previous row)
        If i < n AndAlso cells(i).cp = 32 Then i += 1
    Wend
    If rows + 1 > UBound(row_start) Then ReDim Preserve row_start(0 To rows + 1)
    row_start(rows) = n
    Return rows
End Function

' Visual order of cells a..b-1 (bidi). vis(k) = logical index shown at visual
' position k (0-based within the row). Mirrored glyphs are applied in place
' to the cells of odd levels (on a copy the caller provides).
Function text_row_visual(cells() As ucell, a As Long, b As Long, vis() As Long) As Byte
    Dim n As Long = b - a
    If n <= 0 Then Return 0
    ReDim vis(0 To n - 1)
    Dim cps() As ULong
    ReDim cps(0 To n - 1)
    Dim i As Long
    For i = 0 To n - 1
        cps(i) = cells(a + i).cp
        vis(i) = a + i
    Next i
    If bidi_needed(cps(), n) = 0 Then Return 0
    Dim ord() As Long
    Dim lv() As UByte
    bidi_reorder(cps(), n, ord(), lv())
    For i = 0 To n - 1
        vis(i) = a + ord(i)
        If lv(ord(i)) And 1 Then cells(a + ord(i)).cp = bidi_mirror(cells(a + ord(i)).cp)
    Next i
    Return 1
End Function

' ---------------------------------------------------------------- drawing
' Draw one cell (wide glyphs take two columns). Returns columns used.
Function ui_put(col As Long, row As Long, cp As ULong, fg As UByte, bg As UByte, attr As UByte, w As Long) As Long
    If w = 2 Then
        vt_set_cell_ex(col, row, cp, fg, bg, attr Or VT_ATTR_WIDE)
        vt_set_cell_ex(col + 1, row, cp, fg, bg, attr Or VT_ATTR_WIDE_CONT)
        Return 2
    End If
    vt_set_cell_ex(col, row, cp, fg, bg, attr)
    Return 1
End Function

Sub ui_fill(x1 As Long, y1 As Long, x2 As Long, y2 As Long, fg As UByte, bg As UByte, ch As ULong = 32)
    Dim x As Long
    Dim y As Long
    For y = y1 To y2
        For x = x1 To x2
            vt_set_cell(x, y, ch, fg, bg)
        Next x
    Next y
End Sub

' Draw plain UTF-8 text clipped to maxw columns (bidi-ordered). Returns the
' number of columns used.
Function ui_text(col As Long, row As Long, maxw As Long, ByRef s As String, fg As UByte, bg As UByte, _
                 attr As UByte = 0) As Long
    If maxw <= 0 Then Return 0
    Static cells() As ucell
    Static vis() As Long
    Dim n As Long = text_cells(s, fg, bg, cells(), 1)
    ' clip logically first
    Dim w As Long = 0
    Dim m As Long = 0
    While m < n AndAlso w + cells(m).w <= maxw
        w += cells(m).w
        m += 1
    Wend
    Dim x As Long = col
    If m = 0 Then Return 0
    text_row_visual(cells(), 0, m, vis())
    Dim i As Long
    For i = 0 To m - 1
        Dim ci As Long = vis(i)
        x += ui_put(x, row, cells(ci).cp, fg, bg, attr, cells(ci).w)
    Next i
    Return x - col
End Function

' Display width of plain UTF-8 text.
Function ui_text_width(ByRef s As String) As Long
    Return utf8_width(irc_strip_format(s))
End Function
