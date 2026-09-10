' tests/hooks_stub.bas -- ui_* hooks for headless tests: record what happened.
Dim Shared stub_active As Long = -1
Dim Shared stub_log As String         ' "event:id;" entries
Dim Shared stub_notifies As Long
Dim Shared stub_exit As Byte

Sub ui_on_buffer_new(id As Long, focus As Byte)
    stub_log &= "new:" & id & IIf(focus, "f", "") & ";"
    If focus OrElse stub_active < 0 Then stub_active = id
End Sub
Sub ui_on_buffer_closed(id As Long)
    stub_log &= "closed:" & id & ";"
    If stub_active = id Then stub_active = -1
End Sub
Sub ui_on_buffer_line(id As Long)
End Sub
Sub ui_on_nicklist(id As Long)
End Sub
Sub ui_on_topic(id As Long)
    stub_log &= "topic:" & id & ";"
End Sub
Sub ui_on_conn_state(conn_id As Long)
End Sub
Sub ui_on_notify(id As Long, kind As Long, ByRef title As String, ByRef text As String)
    stub_notifies += 1
    stub_log &= "notify:" & id & ":" & kind & ";"
End Sub
Sub ui_on_chanlist(conn_id As Long)
End Sub
Sub ui_on_dcc()
End Sub
Sub ui_request_focus(id As Long)
    stub_active = id
    stub_log &= "focus:" & id & ";"
End Sub
Function ui_active_buffer() As Long
    Return stub_active
End Function
Function ui_command(buf As Long, ByRef cmd As String, ByRef args As String) As Byte
    Return 0
End Function
Sub ui_request_exit()
    stub_exit = 1
End Sub
Sub ui_settings_changed()
End Sub
