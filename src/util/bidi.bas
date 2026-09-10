' =============================================================================
' src/util/bidi.bas -- bidirectional text ordering for display
'
' A compact subset of the Unicode Bidirectional Algorithm (UAX #9) for one
' left-to-right paragraph line, which is what an IRC line is (it starts with a
' timestamp / nick):
'   * strong classes L / R (Hebrew, Arabic, ... incl. presentation forms)
'   * European numbers (EN) take level 2 after R (rule W7), else behave as L
'   * Arabic-Indic numbers (AN) take level 2
'   * neutral runs between two R-ish sides become R (N1), otherwise L (N2)
'   * non-spacing marks take the class of the preceding character (W1)
'   * runs are reversed from the highest level down (L2); callers mirror
'     brackets for odd levels (L4) with bidi_mirror
' Text is stored in logical order everywhere; only the renderer reorders.
' =============================================================================

Enum BIDI_CLS_T
    BC_L = 0
    BC_R
    BC_EN
    BC_AN
    BC_N
    BC_NSM
End Enum

Function bidi_class(cp As ULong) As Long
    If cp < &h80 Then
        If (cp >= 65 AndAlso cp <= 90) OrElse (cp >= 97 AndAlso cp <= 122) Then Return BC_L
        If cp >= 48 AndAlso cp <= 57 Then Return BC_EN
        Return BC_N
    End If
    Select Case cp
    Case &h0300 To &h036F, &h0483 To &h0489, &h0591 To &h05BD, &h05BF, &h05C1 To &h05C2, _
         &h05C4 To &h05C5, &h05C7, &h0610 To &h061A, &h064B To &h065F, &h0670, _
         &h06D6 To &h06DC, &h06DF To &h06E4, &h06E7 To &h06E8, &h06EA To &h06ED, _
         &h0E31, &h0E34 To &h0E3A, &h0E47 To &h0E4E, &h200B To &h200D, &hFE00 To &hFE0F, _
         &hFB1E, &h1AB0 To &h1AFF, &h1DC0 To &h1DFF, &h20D0 To &h20FF, &hFE20 To &hFE2F
        Return BC_NSM
    Case &h200E : Return BC_L          ' LRM
    Case &h200F : Return BC_R          ' RLM
    Case &h0660 To &h0669, &h066B To &h066C, &h06DD : Return BC_AN
    Case &h06F0 To &h06F9, &h00B2 To &h00B3, &h00B9, &h2070 To &h2079, &h2080 To &h2089, &hFF10 To &hFF19
        Return BC_EN
    Case &h0590 To &h05FF, &h07C0 To &h085F, &hFB1D To &hFB4F, &h10800 To &h10FFF, &h1E800 To &h1EFFF
        Return BC_R
    Case &h0600 To &h06FF, &h0700 To &h074F, &h0750 To &h077F, &h0780 To &h07BF, _
         &h08A0 To &h08FF, &hFB50 To &hFDFF, &hFE70 To &hFEFF
        Return BC_R                    ' AL, treated as R
    Case &h00A0 To &h00BF, &h00D7, &h00F7, &h02B9 To &h02FF, &h2000 To &h2BFF, _
         &h3000 To &h303F, &hFE10 To &hFE19, &hFE30 To &hFE6F, &hFF00 To &hFF0F, _
         &hFF1A To &hFF20, &hFF3B To &hFF40, &hFF5B To &hFF65, &hFFF0 To &hFFFF, _
         &h1F000 To &h1FAFF
        If cp = &h00AA OrElse cp = &h00B5 OrElse cp = &h00BA Then Return BC_L
        Return BC_N
    End Select
    Return BC_L
End Function

Function bidi_is_rtl(cp As ULong) As Byte
    Return IIf(bidi_class(cp) = BC_R OrElse bidi_class(cp) = BC_AN, 1, 0)
End Function

' Mirrored glyph for characters drawn at an odd (RTL) level.
Function bidi_mirror(cp As ULong) As ULong
    Select Case cp
    Case &h28 : Return &h29
    Case &h29 : Return &h28
    Case &h3C : Return &h3E
    Case &h3E : Return &h3C
    Case &h5B : Return &h5D
    Case &h5D : Return &h5B
    Case &h7B : Return &h7D
    Case &h7D : Return &h7B
    Case &hAB : Return &hBB
    Case &hBB : Return &hAB
    Case &h2039 : Return &h203A
    Case &h203A : Return &h2039
    Case &h2264 : Return &h2265
    Case &h2265 : Return &h2264
    Case &h2308 : Return &h2309
    Case &h2309 : Return &h2308
    Case &h3008 : Return &h3009
    Case &h3009 : Return &h3008
    Case &h300A : Return &h300B
    Case &h300B : Return &h300A
    Case &hFF08 : Return &hFF09
    Case &hFF09 : Return &hFF08
    End Select
    Return cp
End Function

' True if any codepoint is strong RTL / Arabic number (fast path skip).
Function bidi_needed(cps() As ULong, n As Long) As Byte
    Dim i As Long
    For i = 0 To n - 1
        If cps(i) >= &h590 Then
            Dim c As Long = bidi_class(cps(i))
            If c = BC_R OrElse c = BC_AN Then Return 1
        End If
    Next i
    Return 0
End Function

' -----------------------------------------------------------------------------
' Visual order of n logical codepoints. On return order(v) is the logical index
' drawn at visual position v, and levels(i) the embedding level of logical i
' (odd = right-to-left, draw bidi_mirror(cp)).
' -----------------------------------------------------------------------------
Sub bidi_reorder(cps() As ULong, n As Long, order() As Long, levels() As UByte)
    If n <= 0 Then Exit Sub
    ReDim order(0 To n - 1)
    ReDim levels(0 To n - 1)
    Dim bc() As Long
    ReDim bc(0 To n - 1)
    Dim i As Long
    Dim j As Long

    ' W1: classes, NSM inherit the previous class
    For i = 0 To n - 1
        bc(i) = bidi_class(cps(i))
        If bc(i) = BC_NSM Then bc(i) = IIf(i > 0, bc(i - 1), BC_N)
    Next i

    ' W7: EN after L (or at paragraph start) -> L
    Dim last_strong As Long = BC_L
    For i = 0 To n - 1
        Select Case bc(i)
        Case BC_L, BC_R : last_strong = bc(i)
        Case BC_EN      : If last_strong = BC_L Then bc(i) = BC_L
        End Select
    Next i

    ' N0: paired brackets. A pair enclosing R text (and no L text) becomes R
    ' when the text before the opening bracket is R; a pair enclosing L text
    ' becomes L. Brackets thus stay together on the same side of a run.
    Dim stk_pos(63) As Long
    Dim stk_cp(63)  As ULong
    Dim sp As Long = 0
    For i = 0 To n - 1
        Select Case cps(i)
        Case &h28, &h5B, &h7B
            If sp <= 63 Then stk_pos(sp) = i : stk_cp(sp) = cps(i) : sp += 1
        Case &h29, &h5D, &h7D
            Dim want As ULong = IIf(cps(i) = &h29, &h28, IIf(cps(i) = &h5D, &h5B, &h7B))
            Dim d As Long = sp - 1
            While d >= 0 AndAlso stk_cp(d) <> want
                d -= 1
            Wend
            If d >= 0 Then
                Dim o As Long = stk_pos(d)
                sp = d
                Dim has_l As Byte = 0
                Dim has_r As Byte = 0
                For j = o + 1 To i - 1
                    If bc(j) = BC_L Then has_l = 1
                    If bc(j) = BC_R OrElse bc(j) = BC_EN OrElse bc(j) = BC_AN Then has_r = 1
                Next j
                Dim pair_dir As Long = -1
                If has_l Then
                    pair_dir = BC_L
                ElseIf has_r Then
                    Dim ctx As Long = BC_L
                    For j = o - 1 To 0 Step -1
                        If bc(j) = BC_L Then ctx = BC_L : Exit For
                        If bc(j) = BC_R OrElse bc(j) = BC_EN OrElse bc(j) = BC_AN Then ctx = BC_R : Exit For
                    Next j
                    pair_dir = ctx
                End If
                If pair_dir >= 0 Then bc(o) = pair_dir : bc(i) = pair_dir
            End If
        End Select
    Next i

    ' N1/N2: neutral runs take the direction of both sides when they agree
    ' (numbers count as R), otherwise the paragraph direction (L)
    i = 0
    While i < n
        If bc(i) = BC_N Then
            j = i
            While j < n AndAlso bc(j) = BC_N
                j += 1
            Wend
            Dim before As Long = BC_L
            Dim after  As Long = BC_L
            If i > 0 Then before = IIf(bc(i - 1) = BC_L, BC_L, BC_R)
            If j < n Then after = IIf(bc(j) = BC_L, BC_L, BC_R)
            Dim resolved As Long = IIf(before = BC_R AndAlso after = BC_R, BC_R, BC_L)
            Dim k As Long
            For k = i To j - 1
                bc(k) = resolved
            Next k
            i = j
        Else
            i += 1
        End If
    Wend

    ' levels (I1): L 0, R 1, numbers 2
    Dim maxlvl As Long = 0
    For i = 0 To n - 1
        Select Case bc(i)
        Case BC_R          : levels(i) = 1
        Case BC_EN, BC_AN  : levels(i) = 2
        Case Else          : levels(i) = 0
        End Select
        If levels(i) > maxlvl Then maxlvl = levels(i)
        order(i) = i
    Next i

    ' L2: reverse runs at level >= lv, from the highest level down to 1
    Dim lv As Long
    For lv = maxlvl To 1 Step -1
        i = 0
        While i < n
            If levels(order(i)) >= lv Then
                j = i
                While j < n AndAlso levels(order(j)) >= lv
                    j += 1
                Wend
                Dim a As Long = i
                Dim b As Long = j - 1
                While a < b
                    Swap order(a), order(b)
                    a += 1 : b -= 1
                Wend
                i = j
            Else
                i += 1
            End If
        Wend
    Next lv
End Sub
