' tests/uni_demo.bas -- visual check of the libvt Unicode extension.
' Renders sample text and writes BMP snapshots (run with SDL_VIDEODRIVER=offscreen).
'   fbc tests/uni_demo.bas -exx -x build/out/linux64/uni_demo
#Define VT_USE_TUI
#Include Once "../vt/vt.bi"
#Include Once "../src/fonts/unifont_embed.bi"

Sub snap(fname As String)
    vt_present()
    Dim w As Long = vt_internal.scr_cols * vt_internal.glyph_w
    Dim h As Long = vt_internal.scr_rows * vt_internal.glyph_h
    SDL_SetRenderTarget(vt_internal.sdl_renderer, vt_internal.sdl_buffer)
    Dim surf As SDL_Surface Ptr = SDL_CreateRGBSurfaceWithFormat(0, w, h, 32, SDL_PIXELFORMAT_ARGB8888)
    SDL_RenderReadPixels(vt_internal.sdl_renderer, 0, SDL_PIXELFORMAT_ARGB8888, surf->pixels, surf->pitch)
    SDL_SaveBMP_RW(surf, SDL_RWFromFile(fname, "wb"), 1)
    SDL_FreeSurface(surf)
    SDL_SetRenderTarget(vt_internal.sdl_renderer, 0)
End Sub

' Decode UTF-8 and draw it at (col,row); wide glyphs take two cells.
Sub put_utf8(col As Long, row As Long, s As String, fg As UByte, bg As UByte, attr As UByte = 0)
    Dim i As Long = 0
    Dim c As Long = col
    Dim n As Long = Len(s)
    Do While i < n
        Dim b  As ULong = s[i]
        Dim cp As ULong
        Dim l  As Long
        If b < &h80 Then
            cp = b : l = 1
        ElseIf (b And &hE0) = &hC0 Then
            cp = ((b And &h1F) Shl 6) Or (s[i + 1] And &h3F) : l = 2
        ElseIf (b And &hF0) = &hE0 Then
            cp = ((b And &h0F) Shl 12) Or ((s[i + 1] And &h3F) Shl 6) Or (s[i + 2] And &h3F) : l = 3
        Else
            cp = ((b And &h07) Shl 18) Or ((s[i + 1] And &h3F) Shl 12) Or ((s[i + 2] And &h3F) Shl 6) Or (s[i + 3] And &h3F) : l = 4
        End If
        i += l
        If vt_uni_glyph_width(cp) = 2 Then
            vt_set_cell_ex(c, row, cp, fg, bg, attr Or VT_ATTR_WIDE)
            vt_set_cell_ex(c + 1, row, cp, fg, bg, attr Or VT_ATTR_WIDE_CONT)
            c += 2
        Else
            vt_set_cell_ex(c, row, cp, fg, bg, attr)
            c += 1
        End If
    Loop
End Sub

vt_screen(VT_SCREENPARAM(60, 14, 8, 16), VT_WINDOWED)
Print "embed:", vt_font_unicode_embed(vtirc_unifont_embed_blob(), VTIRC_UNIFONT_EMBED_LEN)
vt_color(VT_LIGHT_GREY, VT_BLACK)
vt_cls()

put_utf8(2, 1,  "Hebrew : " & !"שלום עולם", VT_WHITE, VT_BLACK)
put_utf8(2, 2,  "Russian: " & !"Привет мир", VT_YELLOW, VT_BLACK)
put_utf8(2, 3,  "Greek  : " & !"Καλημέρα", VT_BRIGHT_CYAN, VT_BLACK)
put_utf8(2, 4,  "Arabic : " & !"مرحبا", VT_BRIGHT_GREEN, VT_BLACK)
put_utf8(2, 5,  "Emoji  : " & Chr(&hF0, &h9F, &h98, &h80) & " " & Chr(&hF0, &h9F, &h8E, &h89) & " " & Chr(&hF0, &h9F, &h91, &h8D) & " " & !"❤ ★ ☺", VT_BRIGHT_MAGENTA, VT_BLACK)
put_utf8(2, 6,  "CJK    : " & !"日本語 中文 한국어", VT_BRIGHT_RED, VT_BLACK)
put_utf8(2, 7,  "Box    : " & !"┌──┐ ╔═╗ éèü", VT_LIGHT_GREY, VT_BLUE)
put_utf8(2, 8,  "bold",      VT_WHITE, VT_BLACK, VT_ATTR_BOLD)
put_utf8(8, 8,  "underline", VT_WHITE, VT_BLACK, VT_ATTR_UNDERLINE)
put_utf8(19, 8, "strike",    VT_WHITE, VT_BLACK, VT_ATTR_STRIKE)
put_utf8(27, 8, !"בולד", VT_WHITE, VT_BLACK, VT_ATTR_BOLD Or VT_ATTR_UNDERLINE)
' a TUI write over a Unicode cell must hide the Unicode glyph
put_utf8(2, 10, "overwrite: " & !"אבג", VT_WHITE, VT_BLACK)
vt_set_cell(13, 10, Asc("X"), VT_BRIGHT_RED, VT_BLACK)
snap("build/out/uni_embedded.bmp")

Print "load:", vt_font_unicode_load("fonts/vtirc-ng.vtuf")
' widths change once CJK glyphs exist, so the row has to be laid out again
put_utf8(2, 6,  "CJK    : " & !"日本語 中文 한국어", VT_BRIGHT_RED, VT_BLACK)
snap("build/out/uni_fullfont.bmp")
Print "width(U+65E5) =", vt_uni_glyph_width(&h65E5), " width(U+05D0) =", vt_uni_glyph_width(&h5D0)
vt_shutdown()
