' =============================================================================
' src/core/core.bas -- the IRC core (no drawing). Include after vt/vt.bi with
' VT_USE_TLS defined, and provide the ui_* hooks declared in hooks.bi.
' =============================================================================
#Include Once "../version.bi"
#Include Once "../util/util.bas"
#Include Once "hooks.bi"
#Include Once "ircmsg.bas"
#Include Once "net.bas"
#Include Once "model.bas"
#Include Once "config.bas"
#Include Once "conn_types.bas"
#Include Once "logger.bas"
#Include Once "events.bas"
#Include Once "conn.bas"
#Include Once "handlers.bas"
#Include Once "dcc.bas"
#Include Once "commands.bas"

' Load configuration and client-wide lists, register commands.
Sub core_init(ByRef cfg_override As String = "")
    Randomize
    paths_init("vtirc-ng", cfg_override)
    net_init()
    config_load()
    ignore_load()
    highlight_load()
    alias_load()
    cmd_init()
End Sub

' One tick of network work (call every frame).
Sub core_poll()
    conn_poll_all()
    dcc_poll()
    net_reap_zombies()
End Sub
