' tests/tframe.bas -- minimal check framework shared by the test programs
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

' Fresh private configuration directory for a test program.
Function t_config_dir(ByRef nm As String) As String
    Dim d As String = Environ("TMPDIR")
    If Len(d) = 0 Then d = "/tmp"
    d &= "/" & nm
    mkdir_p(d)
    If file_exists(d & "/vtirc-ng.ini") Then Kill d & "/vtirc-ng.ini"
    If file_exists(d & "/certs.ini") Then Kill d & "/certs.ini"
    Return d
End Function
