' =============================================================================
' src/core/hooks.bi -- notifications from the IRC core to the front end
'
' The core never draws. It calls these subs, which the UI implements
' (src/ui/hooks_ui.bas) and the headless tests stub out (tests/hooks_stub.bas).
' =============================================================================

Enum NOTIFY_KIND
    NK_HIGHLIGHT = 1     ' nick / highlight word mentioned
    NK_QUERY             ' private message
    NK_NOTICE            ' private notice
    NK_INVITE
    NK_DCC               ' incoming DCC offer
    NK_CONNECT           ' connection state change worth telling the user
End Enum

Declare Sub      ui_on_buffer_new(id As Long, focus As Byte)
Declare Sub      ui_on_buffer_closed(id As Long)
Declare Sub      ui_on_buffer_line(id As Long)
Declare Sub      ui_on_nicklist(id As Long)
Declare Sub      ui_on_topic(id As Long)
Declare Sub      ui_on_conn_state(conn_id As Long)
Declare Sub      ui_on_notify(id As Long, kind As Long, ByRef title As String, ByRef text As String)
Declare Sub      ui_on_chanlist(conn_id As Long)
Declare Sub      ui_on_dcc()
Declare Sub      ui_request_focus(id As Long)
Declare Function ui_active_buffer() As Long
' UI-level commands (/clear, /window, /lastlog, /networks, ...). Returns 1 if handled.
Declare Function ui_command(buf As Long, ByRef cmd As String, ByRef args As String) As Byte
Declare Sub      ui_request_exit()
Declare Sub      ui_settings_changed()
