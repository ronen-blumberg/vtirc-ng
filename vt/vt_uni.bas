' =============================================================================
' vt_uni.bas - vtirc-ng extension to libvt 1.11.0
'
' Unicode cells, text attributes, Unicode keyboard input and UTF-8 clipboard.
'
' Design
'   Every page has a parallel "extension" plane (vt_internal.ext_buf) with one
'   vt_ext_cell per character cell. An extension entry is only honoured while
'   the base cell still holds exactly the ch/fg/bg recorded when the entry was
'   written (chk_* fields). Any other writer -- vt_print, the TUI widgets,
'   dialogs -- therefore invalidates the entry automatically just by drawing
'   over the cell, without having to know the extension exists.
'
'   Glyphs come from fonts in VTUF format (GNU Unifont converted by
'   tools/mkfont.py): an embedded subset registered with vt_font_unicode_embed
'   and an optional complete file loaded with vt_font_unicode_load. Glyphs are
'   rasterised on demand at the current cell size into a texture cache.
'
'   Codepoints that have an exact CP437 glyph are drawn with the normal font;
'   only the rest go through the Unicode glyph cache.
' =============================================================================

Const _VT_UNI_HASH    = 4096   ' cache hash table size (power of two)
Const _VT_UNI_SLOTS_X = 32     ' glyph cache texture: slots per row
Const _VT_UNI_SLOTS_Y = 32     ' glyph cache texture: slot rows

Type vt_uni_font
    dat   As UByte Ptr         ' VTUF blob (header + index + bitmaps)
    count As Long              ' glyphs in the index
    bmp   As UByte Ptr         ' start of the bitmap area
End Type

Type vt_uni_state
    fonts(1)  As vt_uni_font   ' 0 = loaded file (searched first), 1 = embedded
    file_buf  As UByte Ptr     ' allocation owned by fonts(0)
    tex       As Any Ptr       ' SDL_Texture Ptr: glyph cache
    tex_gw    As Long          ' cell size the cache texture was built for
    tex_gh    As Long
    next_slot As Long          ' next free cache slot
    used      As Long          ' occupied hash entries
    hkey(_VT_UNI_HASH - 1)  As ULong   ' codepoint + 1, 0 = empty
    hslot(_VT_UNI_HASH - 1) As Long    ' cache slot, -1 = no glyph in any font
    hwid(_VT_UNI_HASH - 1)  As UByte   ' glyph width in cells
End Type

Dim Shared vt_uni As vt_uni_state

' CP437 128..255 -> Unicode (exact glyph identity; used to decide whether a
' codepoint can use the built-in CP437 font)
Dim Shared vt_uni_cp437_ucp(127) As UShort = { _
    &h00C7, &h00FC, &h00E9, &h00E2, &h00E4, &h00E0, &h00E5, &h00E7, _
    &h00EA, &h00EB, &h00E8, &h00EF, &h00EE, &h00EC, &h00C4, &h00C5, _
    &h00C9, &h00E6, &h00C6, &h00F4, &h00F6, &h00F2, &h00FB, &h00F9, _
    &h00FF, &h00D6, &h00DC, &h00A2, &h00A3, &h00A5, &h20A7, &h0192, _
    &h00E1, &h00ED, &h00F3, &h00FA, &h00F1, &h00D1, &h00AA, &h00BA, _
    &h00BF, &h2310, &h00AC, &h00BD, &h00BC, &h00A1, &h00AB, &h00BB, _
    &h2591, &h2592, &h2593, &h2502, &h2524, &h2561, &h2562, &h2556, _
    &h2555, &h2563, &h2551, &h2557, &h255D, &h255C, &h255B, &h2510, _
    &h2514, &h2534, &h252C, &h251C, &h2500, &h253C, &h255E, &h255F, _
    &h255A, &h2554, &h2569, &h2566, &h2560, &h2550, &h256C, &h2567, _
    &h2568, &h2564, &h2565, &h2559, &h2558, &h2552, &h2553, &h256B, _
    &h256A, &h2518, &h250C, &h2588, &h2584, &h258C, &h2590, &h2580, _
    &h03B1, &h00DF, &h0393, &h03C0, &h03A3, &h03C3, &h00B5, &h03C4, _
    &h03A6, &h0398, &h03A9, &h03B4, &h221E, &h03C6, &h03B5, &h2229, _
    &h2261, &h00B1, &h2265, &h2264, &h2320, &h2321, &h00F7, &h2248, _
    &h00B0, &h2219, &h00B7, &h221A, &h207F, &h00B2, &h25A0, &h00A0 }

' -----------------------------------------------------------------------------
' Exact CP437 glyph for a codepoint, or 0 when CP437 has no identical glyph.
' -----------------------------------------------------------------------------
Function vt_uni_to_cp437(cp As ULong) As UByte
    If cp >= 32 AndAlso cp < 127 Then Return cp
    If cp < &hA0 OrElse cp > &h25A0 Then Return 0
    Dim i As Long
    For i = 0 To 127
        If vt_uni_cp437_ucp(i) = cp Then Return 128 + i
    Next i
    Return 0
End Function

' UTF-8 encoding of one codepoint.
Function vt_uni_utf8(cp As ULong) As String
    If cp < &h80 Then
        Return Chr(cp)
    ElseIf cp < &h800 Then
        Return Chr(&hC0 Or (cp Shr 6), &h80 Or (cp And &h3F))
    ElseIf cp < &h10000 Then
        Return Chr(&hE0 Or (cp Shr 12), &h80 Or ((cp Shr 6) And &h3F), &h80 Or (cp And &h3F))
    Else
        Return Chr(&hF0 Or (cp Shr 18), &h80 Or ((cp Shr 12) And &h3F), _
                   &h80 Or ((cp Shr 6) And &h3F), &h80 Or (cp And &h3F))
    End If
End Function

' -----------------------------------------------------------------------------
' Fonts
' -----------------------------------------------------------------------------
Private Function vt_uni_font_init(ByRef f As vt_uni_font, p As UByte Ptr, n As Long) As Long
    f.dat = 0 : f.count = 0 : f.bmp = 0
    If p = 0 OrElse n < 12 Then Return -1
    If p[0] <> Asc("V") OrElse p[1] <> Asc("T") OrElse p[2] <> Asc("U") OrElse p[3] <> Asc("F") Then Return -1
    Dim cnt As Long = *CPtr(Long Ptr, p + 8)
    If cnt <= 0 OrElse 12 + CLngInt(cnt) * 8 > n Then Return -1
    f.dat   = p
    f.count = cnt
    f.bmp   = p + 12 + cnt * 8
    Return 0
End Function

Private Function vt_uni_font_find(ByRef f As vt_uni_font, cp As ULong, ByRef wid As Long) As UByte Ptr
    If f.dat = 0 Then Return 0
    Dim idx As ULong Ptr = CPtr(ULong Ptr, f.dat + 12)
    Dim lo  As Long = 0
    Dim hi  As Long = f.count - 1
    Dim md  As Long
    Dim key As ULong
    While lo <= hi
        md  = (lo + hi) Shr 1
        key = idx[md * 2] And &hFFFFFF
        If key = cp Then
            wid = idx[md * 2] Shr 24
            Return f.bmp + idx[md * 2 + 1]
        ElseIf key < cp Then
            lo = md + 1
        Else
            hi = md - 1
        End If
    Wend
    Return 0
End Function

Private Function vt_uni_glyph_lookup(cp As ULong, ByRef wid As Long) As UByte Ptr
    Dim gp As UByte Ptr = vt_uni_font_find(vt_uni.fonts(0), cp, wid)
    If gp = 0 Then gp = vt_uni_font_find(vt_uni.fonts(1), cp, wid)
    Return gp
End Function

Private Sub vt_uni_cache_flush()
    Dim i As Long
    For i = 0 To _VT_UNI_HASH - 1
        vt_uni.hkey(i) = 0
    Next i
    vt_uni.next_slot = 0
    vt_uni.used      = 0
    vt_internal.dirty = 1
End Sub

'>>>
':topic vt_font_unicode_embed
':short Register a compiled-in Unicode (VTUF) font
':group Font
'Register a VTUF glyph blob that lives in program
'memory (for example a generated byte array). The
'data is not copied and must stay valid. Glyphs in
'a file loaded with vt_font_unicode_load take
'precedence over this font.
':syntax
Function vt_font_unicode_embed(p As UByte Ptr, n As Long) As Long
        ':notes
        'Return: 0 = ok, -1 = not a VTUF blob.
    '<<<
    Dim r As Long = vt_uni_font_init(vt_uni.fonts(1), p, n)
    vt_uni_cache_flush()
    Return r
End Function

'>>>
':topic vt_font_unicode_load
':short Load a Unicode (VTUF) font file
':group Font
'Load a complete VTUF glyph file (see
'tools/mkfont.py). It is searched before the
'embedded font.
':syntax
Function vt_font_unicode_load(fname As String) As Long
        ':notes
        'Return: 0 = ok, -1 = cannot open, -2 = bad file.
    '<<<
    Dim f As Long = FreeFile()
    If Open(fname For Binary Access Read As #f) <> 0 Then Return -1
    Dim n As LongInt = Lof(f)
    If n < 12 OrElse n > &h7FFFFFFF Then Close #f : Return -2
    Dim buf As UByte Ptr = Allocate(n)
    If buf = 0 Then Close #f : Return -2
    Get #f, , *buf, n
    Close #f
    Dim nf As vt_uni_font
    If vt_uni_font_init(nf, buf, n) <> 0 Then
        Deallocate buf
        Return -2
    End If
    If vt_uni.file_buf <> 0 Then Deallocate vt_uni.file_buf
    vt_uni.file_buf = buf
    vt_uni.fonts(0) = nf
    vt_uni_cache_flush()
    Return 0
End Function

'>>>
':topic vt_uni_glyph_width
':short Cell width of a codepoint's Unicode glyph
':group Font
'Returns 1 or 2 when a registered Unicode font has
'a glyph for cp, 0 when no font has one. Codepoints
'with an exact CP437 glyph return 1.
':syntax
Function vt_uni_glyph_width(cp As ULong) As Long
    '<<<
    If vt_uni_to_cp437(cp) <> 0 Then Return 1
    Dim wid As Long
    If vt_uni_glyph_lookup(cp, wid) = 0 Then Return 0
    Return wid
End Function

' -----------------------------------------------------------------------------
' Extension planes -- allocated alongside the page buffers
' -----------------------------------------------------------------------------
Private Sub vt_uni_ext_free()
    Dim pg As Long
    For pg = 0 To _VT_PAGE_SLOTS - 1
        If vt_internal.ext_buf(pg) <> 0 Then
            Deallocate vt_internal.ext_buf(pg)
            vt_internal.ext_buf(pg) = 0
        End If
    Next pg
End Sub

Private Sub vt_uni_ext_alloc(cols As Long, rows As Long, pages As Long)
    vt_uni_ext_free()
    Dim pg As Long
    For pg = 0 To pages - 1
        vt_internal.ext_buf(pg) = CAllocate(cols * rows, SizeOf(vt_ext_cell))
    Next pg
End Sub

' Pointer to the extension entry of a work-page cell (0-based), or 0.
Private Function vt_uni_ext_at(col0 As Long, row0 As Long) As vt_ext_cell Ptr
    Dim eb As vt_ext_cell Ptr = vt_internal.ext_buf(vt_internal.work_page)
    If eb = 0 Then Return 0
    Return eb + (row0 * vt_internal.scr_cols + col0)
End Function

' Clear the extension of one work-page cell (0-based).
Private Sub vt_uni_ext_clear(col0 As Long, row0 As Long)
    Dim ep As vt_ext_cell Ptr = vt_uni_ext_at(col0, row0)
    If ep <> 0 Then ep->cp = 0 : ep->attr = 0
End Sub

'>>>
':topic vt_set_cell_ex
':short Write a Unicode character cell with attributes
':group Cells
'Write one cell on the work page from a Unicode
'codepoint, with optional text attributes. Double-
'width glyphs occupy two cells: write the same
'codepoint to col with VT_ATTR_WIDE and to col+1
'with VT_ATTR_WIDE_CONT. Does not call vt_present.
':syntax
Sub vt_set_cell_ex(col As Long, row As Long, cp As ULong, _
                   fg As UByte, bg As UByte, attr As UByte = 0)
        ':params
        'col, row  1-based cell position.
        'cp        Unicode codepoint.
        'fg, bg    Colour indices (fg may include VT_BLINK).
        'attr      VT_ATTR_* flags.
    '<<<
    If vt_internal.ready = 0 Then Exit Sub
    If col < 1 OrElse col > vt_internal.scr_cols Then Exit Sub
    If row < 1 OrElse row > vt_internal.scr_rows Then Exit Sub

    Dim ch      As UByte
    Dim need_cp As Byte = 0
    If attr And (VT_ATTR_WIDE Or VT_ATTR_WIDE_CONT) Then
        ch      = IIf(attr And VT_ATTR_WIDE_CONT, 32, 63)
        need_cp = 1
    Else
        ch = vt_uni_to_cp437(cp)
        If ch = 0 Then
            If cp < 32 Then
                ch = 32
            Else
                ch      = 63           ' '?' shown if no font has the glyph
                need_cp = 1
            End If
        End If
    End If

    Dim idx     As Long = (row - 1) * vt_internal.scr_cols + (col - 1)
    Dim cellptr As vt_cell Ptr = vt_internal.cells + idx
    cellptr->ch = ch
    cellptr->fg = fg
    cellptr->bg = bg

    Dim ep As vt_ext_cell Ptr = vt_uni_ext_at(col - 1, row - 1)
    If ep <> 0 Then
        If need_cp OrElse attr <> 0 Then
            ep->cp     = IIf(need_cp, cp, 0)
            ep->attr   = attr
            ep->chk_ch = ch
            ep->chk_fg = fg
            ep->chk_bg = bg
        Else
            ep->cp   = 0
            ep->attr = 0
        End If
    End If
    vt_internal.dirty = 1
End Sub

' True when the extension entry still belongs to the base cell.
#Define _VT_UNI_EXT_VALID(_ep, _cell) (((_ep)->attr <> 0 OrElse (_ep)->cp <> 0) AndAlso (_ep)->chk_ch = (_cell)->ch AndAlso (_ep)->chk_fg = (_cell)->fg AndAlso (_ep)->chk_bg = (_cell)->bg)

' -----------------------------------------------------------------------------
' Rendering (SDL2 backend only)
' -----------------------------------------------------------------------------
#Ifndef BACKEND_VT

Private Sub vt_uni_tex_release()
    If vt_uni.tex <> 0 Then
        SDL_DestroyTexture(CPtr(SDL_Texture Ptr, vt_uni.tex))
        vt_uni.tex = 0
    End If
    vt_uni_cache_flush()
End Sub

Private Function vt_uni_tex_ready() As Byte
    Dim gw As Long = vt_internal.glyph_w
    Dim gh As Long = vt_internal.glyph_h
    If vt_uni.tex <> 0 AndAlso vt_uni.tex_gw = gw AndAlso vt_uni.tex_gh = gh Then Return 1
    vt_uni_tex_release()
    Dim t As SDL_Texture Ptr = SDL_CreateTexture(vt_internal.sdl_renderer, SDL_PIXELFORMAT_ARGB8888, _
        SDL_TEXTUREACCESS_STATIC, _VT_UNI_SLOTS_X * 2 * gw, _VT_UNI_SLOTS_Y * gh)
    If t = 0 Then Return 0
    SDL_SetTextureBlendMode(t, SDL_BLENDMODE_BLEND)
    vt_uni.tex    = t
    vt_uni.tex_gw = gw
    vt_uni.tex_gh = gh
    Return 1
End Function

' Rasterise a 16-row Unifont bitmap (wid cells wide) into cache slot `slot`.
Private Sub vt_uni_upload(slot As Long, gp As UByte Ptr, wid As Long)
    Dim gw As Long = vt_internal.glyph_w
    Dim gh As Long = vt_internal.glyph_h
    Dim pw As Long = gw * wid
    Dim pix As ULong Ptr = Allocate(pw * gh * SizeOf(ULong))
    If pix = 0 Then Exit Sub
    Dim x  As Long
    Dim y  As Long
    Dim sx As Long
    Dim sy As Long
    Dim b  As UByte
    For y = 0 To gh - 1
        sy = (y * 16) \ gh
        For x = 0 To pw - 1
            sx = (x * 8) \ gw
            b  = gp[sy * wid + (sx Shr 3)]
            pix[y * pw + x] = IIf((b Shr (7 - (sx And 7))) And 1, &hFFFFFFFFul, 0)
        Next x
    Next y
    Dim r As SDL_Rect
    r.x = (slot Mod _VT_UNI_SLOTS_X) * 2 * gw
    r.y = (slot \ _VT_UNI_SLOTS_X) * gh
    r.w = pw
    r.h = gh
    SDL_UpdateTexture(CPtr(SDL_Texture Ptr, vt_uni.tex), @r, pix, pw * SizeOf(ULong))
    Deallocate pix
End Sub

' Cache slot for cp (uploading on first use), -1 if no glyph. wid receives width.
Private Function vt_uni_cache_get(cp As ULong, ByRef wid As Long) As Long
    If vt_uni_tex_ready() = 0 Then Return -1
    Dim h As Long = (cp Xor (cp Shr 9) Xor (cp Shr 17)) And (_VT_UNI_HASH - 1)
    While vt_uni.hkey(h) <> 0
        If vt_uni.hkey(h) = cp + 1 Then
            wid = vt_uni.hwid(h)
            Return vt_uni.hslot(h)
        End If
        h = (h + 1) And (_VT_UNI_HASH - 1)
    Wend

    Dim gp As UByte Ptr = vt_uni_glyph_lookup(cp, wid)
    If gp <> 0 AndAlso (wid < 1 OrElse wid > 2) Then gp = 0
    ' table or texture full: start over (glyphs already drawn this frame stay put;
    ' SDL flushes queued copies before a texture update)
    If vt_uni.used >= (_VT_UNI_HASH * 3) \ 4 OrElse _
       (gp <> 0 AndAlso vt_uni.next_slot >= _VT_UNI_SLOTS_X * _VT_UNI_SLOTS_Y) Then
        vt_uni_cache_flush()
        h = (cp Xor (cp Shr 9) Xor (cp Shr 17)) And (_VT_UNI_HASH - 1)
    End If

    vt_uni.hkey(h) = cp + 1
    vt_uni.used   += 1
    If gp = 0 Then
        vt_uni.hslot(h) = -1
        vt_uni.hwid(h)  = 1
        wid = 1
        Return -1
    End If
    vt_uni.hslot(h) = vt_uni.next_slot
    vt_uni.hwid(h)  = wid
    vt_uni_upload(vt_uni.next_slot, gp, wid)
    vt_uni.next_slot += 1
    Return vt_uni.hslot(h)
End Function

' Draw cp's glyph at pixel (x, y) spanning `cells` cells. Returns 0 if no glyph.
Private Function vt_uni_blit(cp As ULong, x As Long, y As Long, cells As Long, _
                             r As UByte, g As UByte, b As UByte, bold As Byte) As Byte
    Dim wid  As Long
    Dim slot As Long = vt_uni_cache_get(cp, wid)
    If slot < 0 Then Return 0
    Dim gw As Long = vt_internal.glyph_w
    Dim gh As Long = vt_internal.glyph_h
    Dim s  As SDL_Rect
    Dim d  As SDL_Rect
    s.x = (slot Mod _VT_UNI_SLOTS_X) * 2 * gw
    s.y = (slot \ _VT_UNI_SLOTS_X) * gh
    s.w = gw * wid
    s.h = gh
    d.x = x : d.y = y : d.w = gw * cells : d.h = gh
    If cells <> wid Then s.w = gw * IIf(wid < cells, wid, cells) : d.w = s.w
    SDL_SetTextureColorMod(CPtr(SDL_Texture Ptr, vt_uni.tex), r, g, b)
    SDL_RenderCopy(vt_internal.sdl_renderer, CPtr(SDL_Texture Ptr, vt_uni.tex), @s, @d)
    If bold Then
        d.x += IIf(gw >= 16, gw \ 8, 1)
        SDL_RenderCopy(vt_internal.sdl_renderer, CPtr(SDL_Texture Ptr, vt_uni.tex), @s, @d)
    End If
    Return 1
End Function

' Underline / strikethrough lines for one cell.
Private Sub vt_uni_lines(attr As UByte, x As Long, y As Long, r As UByte, g As UByte, b As UByte)
    If (attr And (VT_ATTR_UNDERLINE Or VT_ATTR_STRIKE)) = 0 Then Exit Sub
    Dim gw As Long = vt_internal.glyph_w
    Dim gh As Long = vt_internal.glyph_h
    Dim th As Long = IIf(gh >= 32, gh \ 16, 1)
    Dim rc As SDL_Rect
    SDL_SetRenderDrawColor(vt_internal.sdl_renderer, r, g, b, 255)
    rc.x = x : rc.w = gw : rc.h = th
    If attr And VT_ATTR_UNDERLINE Then
        rc.y = y + gh - 2 * th
        SDL_RenderFillRect(vt_internal.sdl_renderer, @rc)
    End If
    If attr And VT_ATTR_STRIKE Then
        rc.y = y + gh \ 2
        SDL_RenderFillRect(vt_internal.sdl_renderer, @rc)
    End If
End Sub

' -----------------------------------------------------------------------------
' Called by vt_present for a cell whose extension entry is valid, after the
' cell background was filled and with sdl_texture already colour-modded to the
' cell foreground. Returns 1 when the glyph was drawn (caller skips the normal
' CP437 copy), 0 to let the caller draw the CP437 fallback glyph.
' -----------------------------------------------------------------------------
Private Function vt_uni_draw_cell(cellptr As vt_cell Ptr, ep As vt_ext_cell Ptr, _
                                  col0 As Long, row0 As Long, _
                                  r As UByte, g As UByte, b As UByte) As Byte
    Dim gw   As Long  = vt_internal.glyph_w
    Dim gh   As Long  = vt_internal.glyph_h
    Dim x    As Long  = col0 * gw
    Dim y    As Long  = row0 * gh
    Dim attr As UByte = ep->attr
    Dim bold As Byte  = IIf(attr And VT_ATTR_BOLD, 1, 0)

    If attr And VT_ATTR_WIDE Then
        ' glyph is drawn by the continuation cell so its background does not
        ' paint over the right half
        vt_uni_lines(attr, x, y, r, g, b)
        Return 1
    End If

    If attr And VT_ATTR_WIDE_CONT Then
        If col0 > 0 Then
            Dim lp As vt_ext_cell Ptr = ep - 1
            Dim lc As vt_cell Ptr     = cellptr - 1
            If (lp->attr And VT_ATTR_WIDE) <> 0 AndAlso lp->cp = ep->cp AndAlso _
               lp->chk_ch = lc->ch AndAlso lp->chk_fg = lc->fg AndAlso lp->chk_bg = lc->bg Then
                vt_uni_blit(ep->cp, x - gw, y, 2, r, g, b, bold)
            End If
        End If
        vt_uni_lines(attr, x, y, r, g, b)
        Return 1
    End If

    If ep->cp <> 0 Then
        If vt_uni_blit(ep->cp, x, y, 1, r, g, b, bold) = 0 Then Return 0
        vt_uni_lines(attr, x, y, r, g, b)
        Return 1
    End If

    ' attributes on a plain CP437 glyph
    Dim s As SDL_Rect
    Dim d As SDL_Rect
    s.x = (cellptr->ch Mod 16) * gw : s.y = (cellptr->ch \ 16) * gh : s.w = gw : s.h = gh
    d.x = x : d.y = y : d.w = gw : d.h = gh
    SDL_RenderCopy(vt_internal.sdl_renderer, vt_internal.sdl_texture, @s, @d)
    If bold Then
        d.x += IIf(gw >= 16, gw \ 8, 1)
        SDL_RenderCopy(vt_internal.sdl_renderer, vt_internal.sdl_texture, @s, @d)
    End If
    vt_uni_lines(attr, x, y, r, g, b)
    Return 1
End Function

#Else

Private Sub vt_uni_tex_release()
    vt_uni_cache_flush()
End Sub

#Endif

' -----------------------------------------------------------------------------
' Unicode keyboard input and UTF-8 clipboard
' -----------------------------------------------------------------------------

'>>>
':topic vt_key_cp
':short Unicode codepoint of the last key read
':group Keyboard
'Returns the Unicode codepoint of the character key
'most recently returned by vt_inkey / vt_getkey,
'or 0 for special keys. Text without a CP437
'equivalent arrives as a key with
'VT_SCAN(k) = VT_KEY_UNICODE and VT_CHAR(k) = 0;
'vt_key_cp gives its codepoint.
':syntax
Function vt_key_cp() As ULong
    '<<<
    Return vt_internal.last_key_cp
End Function

'>>>
':topic vt_paste_requested
':short Consume a pending paste request
':group Copy/Paste
'Returns 1 (once) when the user pressed Shift+Ins,
'Ctrl+V or the middle mouse button since the last
'call. Use vt_clipboard_get to fetch the text.
':syntax
Function vt_paste_requested() As Byte
    '<<<
    If vt_internal.cp_paste_pend = 0 Then Return 0
    vt_internal.cp_paste_pend = 0
    Return 1
End Function

'>>>
':topic vt_clipboard_get
':short Clipboard text as UTF-8
':group Copy/Paste
':syntax
Function vt_clipboard_get() As String
    '<<<
    #Ifndef BACKEND_VT
        If SDL_HasClipboardText() = SDL_FALSE Then Return ""
        Dim zp As ZString Ptr = SDL_GetClipboardText()
        If zp = 0 Then Return ""
        Dim s As String = *zp
        SDL_free(zp)
        Return s
    #Else
        Return ""
    #Endif
End Function

'>>>
':topic vt_clipboard_set
':short Put UTF-8 text on the clipboard
':group Copy/Paste
':syntax
Sub vt_clipboard_set(utf8 As String)
    '<<<
    #Ifndef BACKEND_VT
        SDL_SetClipboardText(StrPtr(utf8))
    #Endif
End Sub
