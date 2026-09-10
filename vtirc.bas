' =============================================================================
' vtirc.bas -- vtirc-ng, a full-featured IRC client for the libvt text screen
' FreeBASIC 1.10.1 | Windows (win32) + Linux (x86-64) | build: build/build.sh
' =============================================================================
#cmdline "-s gui -w all -gen gcc -O 2"

#Define VT_USE_TUI
#Define VT_USE_TLS
#Include Once "vt/vt.bi"
#Include Once "src/core/core.bas"
#Include Once "src/fonts/unifont_embed.bi"
#Include Once "src/ui/ui.bas"

app_main()
