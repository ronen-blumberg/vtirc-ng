' =============================================================================
' src/core/dcc.bas -- DCC CHAT / SEND (see Phase 5; offers are shown for now)
' =============================================================================

Sub dcc_on_ctcp(c As Long, ByRef m As irc_msg, ByRef arg As String)
    ev_front(c, "DCC " & arg & " offered by " & m.nick & " (DCC support is not enabled in this build)", LK_CTCP, ">>")
End Sub

Sub dcc_chat_send(buf_id As Long, ByRef text As String)
    ev_line(buf_id, LK_ERROR, 0, "!!", "", "DCC chat is not connected")
End Sub

Sub dcc_poll()
End Sub
