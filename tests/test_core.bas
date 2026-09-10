' =============================================================================
' tests/test_core.bas -- headless unit tests (no SDL window, no network)
'   build/build.sh test
' Exit code = number of failed checks.
' =============================================================================
#Define VT_USE_TLS
#Include Once "../vt/vt.bi"
#Include Once "../src/core/core.bas"
#Include Once "hooks_stub.bas"
#Include Once "tframe.bas"

' private configuration directory, emptied on every run
core_init(t_config_dir("vtirc_ng_tests"))

#Include Once "test_util.bas"
#Include Once "test_irc.bas"

Print "tests: " & t_pass & " passed, " & t_fail & " failed"
End t_fail
