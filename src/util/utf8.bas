' =============================================================================
' src/util/utf8.bas -- UTF-8 strings, display width, legacy charset decoding
'
' All text inside vtirc-ng is UTF-8 in ordinary FreeBASIC Strings. Conversion
' to screen glyphs happens only in the renderer.
' =============================================================================
#Include Once "../fonts/unicode_width.bi"

Const UTF8_REPLACEMENT = &hFFFD

' Optional glyph-width provider (the UI sets it to libvt's vt_uni_glyph_width).
' Returns 1/2 when a font has the glyph, 0 when no font has it.
Dim Shared utf8_font_width As Function(cp As ULong) As Long

' -----------------------------------------------------------------------------
' Decode the codepoint starting at byte offset p (0-based) and advance p past
' it. Malformed input yields U+FFFD and advances by one byte.
' -----------------------------------------------------------------------------
Function utf8_decode(ByRef s As String, ByRef p As Long) As ULong
    Dim n  As Long  = Len(s)
    If p >= n Then p = n : Return 0
    Dim b0 As ULong = s[p]
    If b0 < &h80 Then p += 1 : Return b0

    Dim need As Long
    Dim cp   As ULong
    Dim mn   As ULong
    If (b0 And &hE0) = &hC0 Then
        need = 1 : cp = b0 And &h1F : mn = &h80
    ElseIf (b0 And &hF0) = &hE0 Then
        need = 2 : cp = b0 And &h0F : mn = &h800
    ElseIf (b0 And &hF8) = &hF0 Then
        need = 3 : cp = b0 And &h07 : mn = &h10000
    Else
        p += 1 : Return UTF8_REPLACEMENT
    End If
    ' the continuation bytes s[p+1 .. p+need] must exist
    If p + need >= n Then p += 1 : Return UTF8_REPLACEMENT
    Dim i As Long
    For i = 1 To need
        Dim bc As ULong = s[p + i]
        If (bc And &hC0) <> &h80 Then p += 1 : Return UTF8_REPLACEMENT
        cp = (cp Shl 6) Or (bc And &h3F)
    Next i
    If cp < mn OrElse cp > &h10FFFF OrElse (cp >= &hD800 AndAlso cp <= &hDFFF) Then
        p += 1 : Return UTF8_REPLACEMENT
    End If
    p += need + 1
    Return cp
End Function

Function utf8_encode(cp As ULong) As String
    If cp < &h80 Then
        Return Chr(cp)
    ElseIf cp < &h800 Then
        Return Chr(&hC0 Or (cp Shr 6), &h80 Or (cp And &h3F))
    ElseIf cp < &h10000 Then
        Return Chr(&hE0 Or (cp Shr 12), &h80 Or ((cp Shr 6) And &h3F), &h80 Or (cp And &h3F))
    ElseIf cp <= &h10FFFF Then
        Return Chr(&hF0 Or (cp Shr 18), &h80 Or ((cp Shr 12) And &h3F), _
                   &h80 Or ((cp Shr 6) And &h3F), &h80 Or (cp And &h3F))
    End If
    Return Chr(&hEF, &hBF, &hBD)
End Function

' True when s is well-formed UTF-8.
Function utf8_valid(ByRef s As String) As Byte
    Dim p As Long = 0
    Dim n As Long = Len(s)
    While p < n
        If s[p] < &h80 Then
            p += 1
        Else
            Dim q  As Long = p
            Dim cp As ULong = utf8_decode(s, q)
            If cp = UTF8_REPLACEMENT Then
                ' a literal U+FFFD (EF BF BD) is valid
                If q - p <> 3 OrElse s[p] <> &hEF OrElse s[p + 1] <> &hBF OrElse s[p + 2] <> &hBD Then Return 0
            End If
            p = q
        End If
    Wend
    Return 1
End Function

' Number of codepoints.
Function utf8_len(ByRef s As String) As Long
    Dim p As Long = 0
    Dim c As Long = 0
    While p < Len(s)
        utf8_decode(s, p)
        c += 1
    Wend
    Return c
End Function

' Byte offset of the codepoint before byte offset p.
Function utf8_prev(ByRef s As String, p As Long) As Long
    If p <= 0 Then Return 0
    Dim q As Long = p - 1
    While q > 0 AndAlso (s[q] And &hC0) = &h80 AndAlso p - q < 4
        q -= 1
    Wend
    Return q
End Function

' Byte offset of the codepoint after byte offset p.
Function utf8_next(ByRef s As String, p As Long) As Long
    If p >= Len(s) Then Return Len(s)
    Dim q As Long = p
    utf8_decode(s, q)
    Return q
End Function

' -----------------------------------------------------------------------------
' Display width (terminal cells) of one codepoint.
' -----------------------------------------------------------------------------
Private Function uw_in(tbl() As ULong, cnt As Long, cp As ULong) As Byte
    Dim lo As Long = 0
    Dim hi As Long = cnt - 1
    Dim md As Long
    While lo <= hi
        md = (lo + hi) Shr 1
        If cp < tbl(md * 2) Then
            hi = md - 1
        ElseIf cp > tbl(md * 2 + 1) Then
            lo = md + 1
        Else
            Return 1
        End If
    Wend
    Return 0
End Function

Function utf8_cp_width(cp As ULong) As Long
    If cp < &h20 OrElse cp = &h7F Then Return 0
    If cp < &h300 Then Return 1
    If uw_in(uw_zero(), UW_ZERO_N, cp) Then Return 0
    If utf8_font_width <> 0 Then
        Dim fw As Long = utf8_font_width(cp)
        If fw > 0 Then Return fw
        Return 1                      ' drawn as a one-cell placeholder
    End If
    If cp >= &h1100 AndAlso uw_in(uw_wide(), UW_WIDE_N, cp) Then Return 2
    Return 1
End Function

' Display width of a whole string (formatting codes must be stripped first).
Function utf8_width(ByRef s As String) As Long
    Dim p As Long = 0
    Dim w As Long = 0
    While p < Len(s)
        w += utf8_cp_width(utf8_decode(s, p))
    Wend
    Return w
End Function

' Longest prefix of s whose display width is <= maxw.
Function utf8_truncate_width(ByRef s As String, maxw As Long) As String
    Dim p As Long = 0
    Dim w As Long = 0
    Dim q As Long
    While p < Len(s)
        q = p
        Dim cw As Long = utf8_cp_width(utf8_decode(s, q))
        If w + cw > maxw Then Exit While
        w += cw
        p = q
    Wend
    Return Left(s, p)
End Function

' Largest byte count <= maxbytes that does not cut a UTF-8 sequence.
Function utf8_safe_cut(ByRef s As String, maxbytes As Long) As Long
    If maxbytes >= Len(s) Then Return Len(s)
    If maxbytes <= 0 Then Return 0
    Dim p As Long = maxbytes
    ' back up while s[p] is a continuation byte (it would start mid-sequence)
    While p > 0 AndAlso (s[p] And &hC0) = &h80
        p -= 1
    Wend
    Return p
End Function

Function utf8_lcase_cp(cp As ULong) As ULong
    If cp >= 65 AndAlso cp <= 90 Then Return cp + 32
    If cp < &hC0 Then Return cp
    ' Latin-1
    If cp >= &hC0 AndAlso cp <= &hDE AndAlso cp <> &hD7 Then Return cp + 32
    ' Greek
    If cp >= &h391 AndAlso cp <= &h3AB AndAlso cp <> &h3A2 Then Return cp + 32
    ' Cyrillic
    If cp >= &h410 AndAlso cp <= &h42F Then Return cp + 32
    If cp >= &h400 AndAlso cp <= &h40F Then Return cp + 80
    ' Latin extended-A pairs
    If cp >= &h100 AndAlso cp <= &h17F AndAlso (cp And 1) = 0 AndAlso cp <> &h130 Then Return cp + 1
    Return cp
End Function

' Case-folded copy (ASCII, Latin-1, Latin ext-A, Greek, Cyrillic). Used for
' case-insensitive search / highlight matching of arbitrary text.
Function utf8_lcase(ByRef s As String) As String
    Dim r As String
    Dim p As Long = 0
    Dim ascii As Byte = 1
    Dim i As Long
    For i = 0 To Len(s) - 1
        If s[i] >= &h80 Then ascii = 0 : Exit For
    Next i
    If ascii Then Return LCase(s)
    While p < Len(s)
        r &= utf8_encode(utf8_lcase_cp(utf8_decode(s, p)))
    Wend
    Return r
End Function

' -----------------------------------------------------------------------------
' Legacy 8-bit charsets. IRC is supposed to be UTF-8, but older clients still
' send Latin-1 / Windows code pages. Lines that are not valid UTF-8 are decoded
' with the network's fallback charset.
' -----------------------------------------------------------------------------
Enum CHARSET_ID
    CHARSET_LATIN1 = 0
    CHARSET_CP1252
    CHARSET_CP1255     ' Hebrew
    CHARSET_CP1251     ' Cyrillic
    CHARSET_CP1253     ' Greek
    CHARSET_CP1256     ' Arabic
End Enum

' 0x80..0xFF -> Unicode. 0 = undefined byte.
Dim Shared cs_1252(127) As UShort = { _
    &h20AC,0,&h201A,&h0192,&h201E,&h2026,&h2020,&h2021,&h02C6,&h2030,&h0160,&h2039,&h0152,0,&h017D,0, _
    0,&h2018,&h2019,&h201C,&h201D,&h2022,&h2013,&h2014,&h02DC,&h2122,&h0161,&h203A,&h0153,0,&h017E,&h0178, _
    &hA0,&hA1,&hA2,&hA3,&hA4,&hA5,&hA6,&hA7,&hA8,&hA9,&hAA,&hAB,&hAC,&hAD,&hAE,&hAF, _
    &hB0,&hB1,&hB2,&hB3,&hB4,&hB5,&hB6,&hB7,&hB8,&hB9,&hBA,&hBB,&hBC,&hBD,&hBE,&hBF, _
    &hC0,&hC1,&hC2,&hC3,&hC4,&hC5,&hC6,&hC7,&hC8,&hC9,&hCA,&hCB,&hCC,&hCD,&hCE,&hCF, _
    &hD0,&hD1,&hD2,&hD3,&hD4,&hD5,&hD6,&hD7,&hD8,&hD9,&hDA,&hDB,&hDC,&hDD,&hDE,&hDF, _
    &hE0,&hE1,&hE2,&hE3,&hE4,&hE5,&hE6,&hE7,&hE8,&hE9,&hEA,&hEB,&hEC,&hED,&hEE,&hEF, _
    &hF0,&hF1,&hF2,&hF3,&hF4,&hF5,&hF6,&hF7,&hF8,&hF9,&hFA,&hFB,&hFC,&hFD,&hFE,&hFF }

Dim Shared cs_1255(127) As UShort = { _
    &h20AC,0,&h201A,&h0192,&h201E,&h2026,&h2020,&h2021,&h02C6,&h2030,0,&h2039,0,0,0,0, _
    0,&h2018,&h2019,&h201C,&h201D,&h2022,&h2013,&h2014,&h02DC,&h2122,0,&h203A,0,0,0,0, _
    &hA0,&hA1,&hA2,&hA3,&h20AA,&hA5,&hA6,&hA7,&hA8,&hA9,&hD7,&hAB,&hAC,&hAD,&hAE,&hAF, _
    &hB0,&hB1,&hB2,&hB3,&hB4,&hB5,&hB6,&hB7,&hB8,&hB9,&hF7,&hBB,&hBC,&hBD,&hBE,&hBF, _
    &h05B0,&h05B1,&h05B2,&h05B3,&h05B4,&h05B5,&h05B6,&h05B7,&h05B8,&h05B9,&h05BA,&h05BB,&h05BC,&h05BD,&h05BE,&h05BF, _
    &h05C0,&h05C1,&h05C2,&h05C3,&h05F0,&h05F1,&h05F2,&h05F3,&h05F4,0,0,0,0,0,0,0, _
    &h05D0,&h05D1,&h05D2,&h05D3,&h05D4,&h05D5,&h05D6,&h05D7,&h05D8,&h05D9,&h05DA,&h05DB,&h05DC,&h05DD,&h05DE,&h05DF, _
    &h05E0,&h05E1,&h05E2,&h05E3,&h05E4,&h05E5,&h05E6,&h05E7,&h05E8,&h05E9,&h05EA,0,0,&h200E,&h200F,0 }

Dim Shared cs_1251(127) As UShort = { _
    &h0402,&h0403,&h201A,&h0453,&h201E,&h2026,&h2020,&h2021,&h20AC,&h2030,&h0409,&h2039,&h040A,&h040C,&h040B,&h040F, _
    &h0452,&h2018,&h2019,&h201C,&h201D,&h2022,&h2013,&h2014,0,&h2122,&h0459,&h203A,&h045A,&h045C,&h045B,&h045F, _
    &hA0,&h040E,&h045E,&h0408,&hA4,&h0490,&hA6,&hA7,&h0401,&hA9,&h0404,&hAB,&hAC,&hAD,&hAE,&h0407, _
    &hB0,&hB1,&h0406,&h0456,&h0491,&hB5,&hB6,&hB7,&h0451,&h2116,&h0454,&hBB,&h0458,&h0405,&h0455,&h0457, _
    &h0410,&h0411,&h0412,&h0413,&h0414,&h0415,&h0416,&h0417,&h0418,&h0419,&h041A,&h041B,&h041C,&h041D,&h041E,&h041F, _
    &h0420,&h0421,&h0422,&h0423,&h0424,&h0425,&h0426,&h0427,&h0428,&h0429,&h042A,&h042B,&h042C,&h042D,&h042E,&h042F, _
    &h0430,&h0431,&h0432,&h0433,&h0434,&h0435,&h0436,&h0437,&h0438,&h0439,&h043A,&h043B,&h043C,&h043D,&h043E,&h043F, _
    &h0440,&h0441,&h0442,&h0443,&h0444,&h0445,&h0446,&h0447,&h0448,&h0449,&h044A,&h044B,&h044C,&h044D,&h044E,&h044F }

Dim Shared cs_1253(127) As UShort = { _
    &h20AC,0,&h201A,&h0192,&h201E,&h2026,&h2020,&h2021,0,&h2030,0,&h2039,0,0,0,0, _
    0,&h2018,&h2019,&h201C,&h201D,&h2022,&h2013,&h2014,0,&h2122,0,&h203A,0,0,0,0, _
    &hA0,&h0385,&h0386,&hA3,&hA4,&hA5,&hA6,&hA7,&hA8,&hA9,0,&hAB,&hAC,&hAD,&hAE,&h2015, _
    &hB0,&hB1,&hB2,&hB3,&h0384,&hB5,&hB6,&hB7,&h0388,&h0389,&h038A,&hBB,&h038C,&hBD,&h038E,&h038F, _
    &h0390,&h0391,&h0392,&h0393,&h0394,&h0395,&h0396,&h0397,&h0398,&h0399,&h039A,&h039B,&h039C,&h039D,&h039E,&h039F, _
    &h03A0,&h03A1,0,&h03A3,&h03A4,&h03A5,&h03A6,&h03A7,&h03A8,&h03A9,&h03AA,&h03AB,&h03AC,&h03AD,&h03AE,&h03AF, _
    &h03B0,&h03B1,&h03B2,&h03B3,&h03B4,&h03B5,&h03B6,&h03B7,&h03B8,&h03B9,&h03BA,&h03BB,&h03BC,&h03BD,&h03BE,&h03BF, _
    &h03C0,&h03C1,&h03C2,&h03C3,&h03C4,&h03C5,&h03C6,&h03C7,&h03C8,&h03C9,&h03CA,&h03CB,&h03CC,&h03CD,&h03CE,0 }

Dim Shared cs_1256(127) As UShort = { _
    &h20AC,&h067E,&h201A,&h0192,&h201E,&h2026,&h2020,&h2021,&h02C6,&h2030,&h0679,&h2039,&h0152,&h0686,&h0698,&h0688, _
    &h06AF,&h2018,&h2019,&h201C,&h201D,&h2022,&h2013,&h2014,&h06A9,&h2122,&h0691,&h203A,&h0153,&h200C,&h200D,&h06BA, _
    &hA0,&h060C,&hA2,&hA3,&hA4,&hA5,&hA6,&hA7,&hA8,&hA9,&h06BE,&hAB,&hAC,&hAD,&hAE,&hAF, _
    &hB0,&hB1,&hB2,&hB3,&hB4,&hB5,&hB6,&hB7,&hB8,&hB9,&h061B,&hBB,&hBC,&hBD,&hBE,&h061F, _
    &h06C1,&h0621,&h0622,&h0623,&h0624,&h0625,&h0626,&h0627,&h0628,&h0629,&h062A,&h062B,&h062C,&h062D,&h062E,&h062F, _
    &h0630,&h0631,&h0632,&h0633,&h0634,&h0635,&h0636,&hD7,&h0637,&h0638,&h0639,&h063A,&h0640,&h0641,&h0642,&h0643, _
    &hE0,&h0644,&hE2,&h0645,&h0646,&h0647,&h0648,&hE7,&hE8,&hE9,&hEA,&hEB,&h0649,&h064A,&hEE,&hEF, _
    &h064B,&h064C,&h064D,&h064E,&hF4,&h064F,&h0650,&hF7,&h0651,&hF9,&h0652,&hFB,&hFC,&h200E,&h200F,&h06D2 }

Function charset_from_name(nm As String) As Long
    Select Case LCase(Trim(nm))
    Case "cp1252", "windows-1252"                 : Return CHARSET_CP1252
    Case "cp1255", "windows-1255", "hebrew"       : Return CHARSET_CP1255
    Case "cp1251", "windows-1251", "cyrillic"     : Return CHARSET_CP1251
    Case "cp1253", "windows-1253", "greek"        : Return CHARSET_CP1253
    Case "cp1256", "windows-1256", "arabic"       : Return CHARSET_CP1256
    End Select
    Return CHARSET_LATIN1
End Function

Function charset_name(cs As Long) As String
    Select Case cs
    Case CHARSET_CP1252 : Return "cp1252"
    Case CHARSET_CP1255 : Return "cp1255"
    Case CHARSET_CP1251 : Return "cp1251"
    Case CHARSET_CP1253 : Return "cp1253"
    Case CHARSET_CP1256 : Return "cp1256"
    End Select
    Return "latin1"
End Function

' Decode an 8-bit string in charset cs to UTF-8.
Function charset_to_utf8(ByRef s As String, cs As Long) As String
    Dim r As String
    Dim i As Long
    Dim b As ULong
    Dim u As ULong
    For i = 0 To Len(s) - 1
        b = s[i]
        If b < &h80 Then
            r &= Chr(b)
        Else
            Select Case cs
            Case CHARSET_CP1252 : u = cs_1252(b - 128)
            Case CHARSET_CP1255 : u = cs_1255(b - 128)
            Case CHARSET_CP1251 : u = cs_1251(b - 128)
            Case CHARSET_CP1253 : u = cs_1253(b - 128)
            Case CHARSET_CP1256 : u = cs_1256(b - 128)
            Case Else           : u = b
            End Select
            If u = 0 Then u = UTF8_REPLACEMENT
            r &= utf8_encode(u)
        End If
    Next i
    Return r
End Function

' Encode UTF-8 text into charset cs (for networks configured to send a legacy
' charset). Unrepresentable characters become '?'.
Function utf8_to_charset(ByRef s As String, cs As Long) As String
    Dim r  As String
    Dim p  As Long = 0
    Dim cp As ULong
    Dim i  As Long
    While p < Len(s)
        cp = utf8_decode(s, p)
        If cp < &h80 Then
            r &= Chr(cp)
        Else
            Dim found As Long = -1
            If cs = CHARSET_LATIN1 Then
                If cp <= &hFF Then found = cp - 128
            Else
                For i = 0 To 127
                    Dim u As ULong
                    Select Case cs
                    Case CHARSET_CP1252 : u = cs_1252(i)
                    Case CHARSET_CP1255 : u = cs_1255(i)
                    Case CHARSET_CP1251 : u = cs_1251(i)
                    Case CHARSET_CP1253 : u = cs_1253(i)
                    Case CHARSET_CP1256 : u = cs_1256(i)
                    End Select
                    If u = cp Then found = i : Exit For
                Next i
            End If
            r &= IIf(found >= 0, Chr(128 + found), "?")
        End If
    Wend
    Return r
End Function

' Incoming text: keep valid UTF-8, otherwise decode with the fallback charset.
Function utf8_from_wire(ByRef s As String, fallback_cs As Long) As String
    If utf8_valid(s) Then Return s
    Return charset_to_utf8(s, fallback_cs)
End Function

' Truncate or pad with spaces to exactly w display columns.
Function utf8_pad(ByRef s As String, w As Long) As String
    Dim t As String = utf8_truncate_width(s, w)
    Dim tw As Long = utf8_width(t)
    If tw < w Then t &= Space(w - tw)
    Return t
End Function
