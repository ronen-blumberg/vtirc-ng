' =============================================================================
' src/ui/theme.bas -- colour themes and mIRC colour mapping
' =============================================================================

Type ui_theme
    bg          As UByte   ' chat background
    fg          As UByte   ' ordinary text
    stamp       As UByte   ' timestamps
    own         As UByte   ' own messages
    action      As UByte
    notice      As UByte
    joinc       As UByte   ' joins
    partc       As UByte   ' parts / quits / kicks
    event       As UByte   ' nick / mode / topic / invite
    server      As UByte   ' numerics, MOTD
    info        As UByte   ' client information
    errc        As UByte
    whois       As UByte
    ctcp        As UByte
    history     As UByte   ' replayed / playback lines
    hl_fg       As UByte   ' highlighted line
    hl_bg       As UByte
    link        As UByte
    marker      As UByte   ' "last read" marker line
    sel_fg      As UByte
    sel_bg      As UByte
    sep         As UByte   ' pane separators
    bar_fg      As UByte   ' menu / status / topic bars
    bar_bg      As UByte
    bar_hi      As UByte   ' highlighted status items
    input_fg    As UByte
    input_bg    As UByte
    tree_bg     As UByte
    tree_fg     As UByte
    tree_net    As UByte   ' server windows
    tree_act_fg As UByte   ' active window
    tree_act_bg As UByte
    act_event   As UByte   ' activity colours
    act_msg     As UByte
    act_hl      As UByte
    off         As UByte   ' disconnected windows
    nl_bg       As UByte
    nl_fg       As UByte
    nl_op       As UByte
    nl_voice    As UByte
    nl_away     As UByte
    nick_pal(7) As UByte   ' nick colours
    nick_n      As Long
    name        As String
End Type

Dim Shared th As ui_theme

Sub theme_apply(which As Long)
    With th
        Select Case which
        Case 1  ' classic: blue bars, like VTIRC 1.x
            .name = "classic"
            .bg = VT_BLACK : .fg = VT_LIGHT_GREY : .stamp = VT_DARK_GREY : .own = VT_WHITE
            .action = VT_BRIGHT_MAGENTA : .notice = VT_BRIGHT_GREEN : .joinc = VT_GREEN : .partc = VT_RED
            .event = VT_CYAN : .server = VT_DARK_GREY : .info = VT_BRIGHT_CYAN : .errc = VT_BRIGHT_RED
            .whois = VT_BRIGHT_CYAN : .ctcp = VT_BRIGHT_RED : .history = VT_DARK_GREY
            .hl_fg = VT_YELLOW : .hl_bg = VT_BLACK : .link = VT_BRIGHT_CYAN : .marker = VT_RED
            .sel_fg = VT_BLACK : .sel_bg = VT_LIGHT_GREY : .sep = VT_BLUE
            .bar_fg = VT_WHITE : .bar_bg = VT_BLUE : .bar_hi = VT_YELLOW
            .input_fg = VT_WHITE : .input_bg = VT_BLACK
            .tree_bg = VT_BLACK : .tree_fg = VT_LIGHT_GREY : .tree_net = VT_WHITE
            .tree_act_fg = VT_WHITE : .tree_act_bg = VT_BLUE
            .act_event = VT_CYAN : .act_msg = VT_WHITE : .act_hl = VT_YELLOW : .off = VT_DARK_GREY
            .nl_bg = VT_BLACK : .nl_fg = VT_LIGHT_GREY : .nl_op = VT_BRIGHT_GREEN : .nl_voice = VT_YELLOW : .nl_away = VT_DARK_GREY
        Case 2  ' light
            .name = "light"
            .bg = VT_WHITE : .fg = VT_BLACK : .stamp = VT_DARK_GREY : .own = VT_BLUE
            .action = VT_MAGENTA : .notice = VT_BROWN : .joinc = VT_GREEN : .partc = VT_RED
            .event = VT_CYAN : .server = VT_DARK_GREY : .info = VT_BLUE : .errc = VT_RED
            .whois = VT_BLUE : .ctcp = VT_RED : .history = VT_DARK_GREY
            .hl_fg = VT_WHITE : .hl_bg = VT_RED : .link = VT_BLUE : .marker = VT_RED
            .sel_fg = VT_WHITE : .sel_bg = VT_BLUE : .sep = VT_LIGHT_GREY
            .bar_fg = VT_BLACK : .bar_bg = VT_LIGHT_GREY : .bar_hi = VT_BLUE
            .input_fg = VT_BLACK : .input_bg = VT_WHITE
            .tree_bg = VT_WHITE : .tree_fg = VT_BLACK : .tree_net = VT_BLUE
            .tree_act_fg = VT_WHITE : .tree_act_bg = VT_BLUE
            .act_event = VT_CYAN : .act_msg = VT_BLUE : .act_hl = VT_RED : .off = VT_LIGHT_GREY
            .nl_bg = VT_WHITE : .nl_fg = VT_BLACK : .nl_op = VT_GREEN : .nl_voice = VT_BROWN : .nl_away = VT_LIGHT_GREY
        Case Else  ' dark (default)
            .name = "dark"
            .bg = VT_BLACK : .fg = VT_LIGHT_GREY : .stamp = VT_DARK_GREY : .own = VT_WHITE
            .action = VT_BRIGHT_MAGENTA : .notice = VT_BROWN : .joinc = VT_GREEN : .partc = VT_RED
            .event = VT_CYAN : .server = VT_DARK_GREY : .info = VT_BRIGHT_BLUE : .errc = VT_BRIGHT_RED
            .whois = VT_BRIGHT_CYAN : .ctcp = VT_BRIGHT_RED : .history = VT_DARK_GREY
            .hl_fg = VT_BLACK : .hl_bg = VT_YELLOW : .link = VT_BRIGHT_CYAN : .marker = VT_BRIGHT_RED
            .sel_fg = VT_BLACK : .sel_bg = VT_LIGHT_GREY : .sep = VT_DARK_GREY
            .bar_fg = VT_WHITE : .bar_bg = VT_DARK_GREY : .bar_hi = VT_YELLOW
            .input_fg = VT_WHITE : .input_bg = VT_BLACK
            .tree_bg = VT_BLACK : .tree_fg = VT_LIGHT_GREY : .tree_net = VT_WHITE
            .tree_act_fg = VT_BLACK : .tree_act_bg = VT_LIGHT_GREY
            .act_event = VT_CYAN : .act_msg = VT_WHITE : .act_hl = VT_BRIGHT_MAGENTA : .off = VT_DARK_GREY
            .nl_bg = VT_BLACK : .nl_fg = VT_LIGHT_GREY : .nl_op = VT_BRIGHT_GREEN : .nl_voice = VT_YELLOW : .nl_away = VT_DARK_GREY
        End Select
        If .bg = VT_WHITE Then
            .nick_pal(0) = VT_BLUE : .nick_pal(1) = VT_GREEN : .nick_pal(2) = VT_RED : .nick_pal(3) = VT_MAGENTA
            .nick_pal(4) = VT_BROWN : .nick_pal(5) = VT_CYAN : .nick_pal(6) = VT_DARK_GREY : .nick_pal(7) = VT_BRIGHT_BLUE
        Else
            .nick_pal(0) = VT_BRIGHT_CYAN : .nick_pal(1) = VT_BRIGHT_GREEN : .nick_pal(2) = VT_BRIGHT_MAGENTA : .nick_pal(3) = VT_YELLOW
            .nick_pal(4) = VT_BRIGHT_BLUE : .nick_pal(5) = VT_BRIGHT_RED : .nick_pal(6) = VT_CYAN : .nick_pal(7) = VT_GREEN
        End If
        .nick_n = 8
    End With
    ' libvt TUI widgets (menus, dialogs) follow the bar colours
    vt_tui_theme(th.fg, th.bg, VT_WHITE, VT_BLUE, th.bar_fg, th.bar_bg, _
                 VT_BLACK, VT_LIGHT_GREY, VT_BLACK, VT_LIGHT_GREY, th.input_fg, th.input_bg)
End Sub

' Stable colour for a nick (djb2 hash, case-insensitive).
Function nick_color(ByRef nick As String) As UByte
    Dim h As ULong = 5381
    Dim l As String = LCase(nick)
    Dim i As Long
    For i = 0 To Len(l) - 1
        h = ((h Shl 5) + h) Xor l[i]
    Next i
    Return th.nick_pal(h Mod th.nick_n)
End Function

' ---------------------------------------------------------------- mIRC colours
' 0..15 map onto the VGA palette directly.
Dim Shared mirc16(15) As UByte = { 15, 0, 1, 2, 12, 4, 5, 6, 14, 10, 3, 11, 9, 13, 8, 7 }

' RGB of the extended colours 16..98 (modern.ircdocs.horse)
Dim Shared mirc_ext_rgb(16 To 98) As ULong = { _
    &h470000,&h472100,&h474700,&h324700,&h004700,&h00472C,&h004747,&h002747,&h000047,&h2E0047,&h470047,&h47002A, _
    &h740000,&h743A00,&h747400,&h517400,&h007400,&h007449,&h007474,&h004074,&h000074,&h4B0074,&h740074,&h740045, _
    &hB50000,&hB56300,&hB5B500,&h7DB500,&h00B500,&h00B571,&h00B5B5,&h0063B5,&h0000B5,&h7500B5,&hB500B5,&hB5006B, _
    &hFF0000,&hFF8C00,&hFFFF00,&hB2FF00,&h00FF00,&h00FFA0,&h00FFFF,&h008CFF,&h0000FF,&hA500FF,&hFF00FF,&hFF0098, _
    &hFF5959,&hFFB459,&hFFFF71,&hCFFF60,&h6FFF6F,&h65FFC9,&h6DFFFF,&h59B4FF,&h5959FF,&hC459FF,&hFF66FF,&hFF59BC, _
    &hFF9C9C,&hFFD39C,&hFFFF9C,&hE2FF9C,&h9CFF9C,&h9CFFDB,&h9CFFFF,&h9CD3FF,&h9C9CFF,&hDC9CFF,&hFF9CFF,&hFF94D3, _
    &h000000,&h131313,&h282828,&h363636,&h4D4D4D,&h656565,&h818181,&h9F9F9F,&hBCBCBC,&hE2E2E2,&hFFFFFF }

' Nearest of the 16 VGA colours to an RGB value.
Function rgb_to_vga(rgbv As ULong) As UByte
    Dim r As Long = (rgbv Shr 16) And 255
    Dim g As Long = (rgbv Shr 8) And 255
    Dim b As Long = rgbv And 255
    Dim best As Long = 0
    Dim bestd As Long = &h7FFFFFFF
    Dim i As Long
    For i = 0 To 15
        Dim dr As Long = r - vt_internal.palette(i * 3)
        Dim dg As Long = g - vt_internal.palette(i * 3 + 1)
        Dim db As Long = b - vt_internal.palette(i * 3 + 2)
        Dim d As Long = dr * dr * 3 + dg * dg * 4 + db * db * 2
        If d < bestd Then bestd = d : best = i
    Next i
    Return best
End Function

Function mirc_to_vga(idx As Long, fallback As UByte) As UByte
    If idx >= 0 AndAlso idx <= 15 Then Return mirc16(idx)
    If idx >= 16 AndAlso idx <= 98 Then Return rgb_to_vga(mirc_ext_rgb(idx))
    Return fallback
End Function
