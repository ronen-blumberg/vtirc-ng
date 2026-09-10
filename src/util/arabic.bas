' =============================================================================
' src/util/arabic.bas -- contextual shaping of Arabic letters
'
' A cell grid shows one glyph per character, so Arabic has to be converted to
' its presentation forms (Unicode block FE70-FEFF): each letter takes an
' isolated, final, initial or medial shape depending on its neighbours, and
' LAM + ALEF become one ligature. Works on logical order, before bidi.
' =============================================================================

' For U+0621..U+064A: isolated form (0 = none) and joining type.
'   jt: 0 = non-joining, 1 = right-joining (iso, fin), 2 = dual (iso, fin, ini, med)
Dim Shared ar_iso(&h621 To &h64A) As UShort
Dim Shared ar_jt(&h621 To &h64A) As UByte
Dim Shared ar_ready As Byte

Private Sub ar_init()
    If ar_ready Then Exit Sub
    ar_ready = 1
    ' right-joining letters with 2 forms, dual-joining letters with 4 forms
    ' (the presentation forms of one letter are consecutive)
    Dim cp As Long
    Dim f As Long = &hFE80
    For cp = &h621 To &h64A
        Select Case cp
        Case &h621                                        ' hamza: isolated only
            ar_iso(cp) = &hFE80 : ar_jt(cp) = 0 : f = &hFE81
        Case &h622, &h623, &h624, &h625, &h627, &h629, &h62F, &h630, &h631, &h632, &h648, &h649
            ar_iso(cp) = f : ar_jt(cp) = 1 : f += 2
        Case &h626, &h628, &h62A To &h62E, &h633 To &h63A, &h641 To &h647, &h64A
            ar_iso(cp) = f : ar_jt(cp) = 2 : f += 4
        Case &h640                                        ' tatweel: joins both sides, no forms
            ar_iso(cp) = 0 : ar_jt(cp) = 2
        Case Else
            ar_iso(cp) = 0 : ar_jt(cp) = 0
        End Select
    Next cp
End Sub

Private Function ar_type(cp As ULong) As Long
    If cp < &h621 OrElse cp > &h64A Then Return 0
    Return ar_jt(cp)
End Function

Function arabic_present(cps() As ULong, n As Long) As Byte
    Dim i As Long
    For i = 0 To n - 1
        If cps(i) >= &h621 AndAlso cps(i) <= &h64A Then Return 1
    Next i
    Return 0
End Function

' Shape cps(0..n-1) in place. keep(i) = 0 marks characters absorbed into a
' ligature (the caller drops them).
Sub arabic_shape(cps() As ULong, n As Long, keep() As Byte)
    ar_init()
    ReDim keep(0 To IIf(n > 0, n - 1, 0))
    Dim i As Long
    For i = 0 To n - 1
        keep(i) = 1
    Next i
    Dim src() As ULong
    ReDim src(0 To IIf(n > 0, n - 1, 0))
    For i = 0 To n - 1
        src(i) = cps(i)
    Next i
    For i = 0 To n - 1
        Dim cp As ULong = src(i)
        Dim t As Long = ar_type(cp)
        If t = 0 AndAlso cp <> &h621 Then Continue For
        If keep(i) = 0 Then Continue For
        Dim prev_j As Byte = IIf(i > 0 AndAlso keep(i - 1) AndAlso ar_type(src(i - 1)) = 2, 1, 0)
        ' LAM + ALEF ligature
        If cp = &h644 AndAlso i + 1 < n Then
            Dim lig As Long = 0
            Select Case src(i + 1)
            Case &h622 : lig = &hFEF5
            Case &h623 : lig = &hFEF7
            Case &h625 : lig = &hFEF9
            Case &h627 : lig = &hFEFB
            End Select
            If lig <> 0 Then
                cps(i) = lig + IIf(prev_j, 1, 0)
                keep(i + 1) = 0
                Continue For
            End If
        End If
        If cp = &h621 Then cps(i) = &hFE80 : Continue For
        If ar_iso(cp) = 0 Then Continue For               ' tatweel keeps its glyph
        Dim next_j As Byte = IIf(i + 1 < n AndAlso ar_type(src(i + 1)) >= 1, 1, 0)
        If t = 1 Then
            cps(i) = ar_iso(cp) + IIf(prev_j, 1, 0)
        Else
            If prev_j AndAlso next_j Then
                cps(i) = ar_iso(cp) + 3
            ElseIf prev_j Then
                cps(i) = ar_iso(cp) + 1
            ElseIf next_j Then
                cps(i) = ar_iso(cp) + 2
            Else
                cps(i) = ar_iso(cp)
            End If
        End If
    Next i
End Sub
