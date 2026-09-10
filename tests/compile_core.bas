' tests/compile_core.bas -- compile check of the core on every target (no tests)
#Define VT_USE_TLS
#Include Once "../vt/vt.bi"
#Include Once "../src/core/core.bas"
#Include Once "hooks_stub.bas"
core_init(ExePath() & "/cc_cfg")
Print "core ok: " & cmd_count & " commands, " & net_count & " networks"
