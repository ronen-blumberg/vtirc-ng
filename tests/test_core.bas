' =============================================================================
' tests/test_core.bas -- headless unit tests (no SDL window)
'   build/build.sh test        (or: fbc tests/test_core.bas -exx -x ...)
' Exit code = number of failed checks.
' =============================================================================
#Include Once "../src/util/util.bas"

Dim Shared t_pass As Long
Dim Shared t_fail As Long
Dim Shared t_group As String

Sub t_begin(ByRef nm As String)
    t_group = nm
End Sub

Sub check(cond As Long, ByRef what As String)
    If cond Then
        t_pass += 1
    Else
        t_fail += 1
        Print "FAIL [" & t_group & "] " & what
    End If
End Sub

Sub check_str(ByRef got As String, ByRef want As String, ByRef what As String)
    If got = want Then
        t_pass += 1
    Else
        t_fail += 1
        Print "FAIL [" & t_group & "] " & what & !"\n     got : [" & got & !"]\n     want: [" & want & "]"
    End If
End Sub

Sub check_int(got As LongInt, want As LongInt, ByRef what As String)
    If got = want Then
        t_pass += 1
    Else
        t_fail += 1
        Print "FAIL [" & t_group & "] " & what & " got " & got & " want " & want
    End If
End Sub

' UTF-8 literal helper: FreeBASIC source is UTF-8, !"..." keeps bytes as-is.
#Define U8(s) (s)

#Include Once "test_util.bas"

Print "tests: " & t_pass & " passed, " & t_fail & " failed"
End t_fail
