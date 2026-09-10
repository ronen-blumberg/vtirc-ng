' vtirc - include file
#ifdef __FB_WIN32__
    #include once "windows.bi"
    #include once "win/shellapi.bi"
    #include once "win/mmsystem.bi"
    Const NOTIFY_SND = "MailBeep"
#else
    #ifdef IRC_LINUX_NOTIFY
        #inclib "X11"
        #include once "X11/Xlib.bi"
        Dim Shared g_snd_cmd As String ' empty = fall back to BEEP
    #endif
#endif

Const IRC_VERSION     = "1.23"
Const IDLE_MS         = 16
Const HISTORY_MAX     = 500
Const USER_MAX        = 200
Const MIN_SCREEN_COLS = 85           ' minimum allowed columns (narrower breaks the layout)
Const MIN_SCREEN_ROWS = 35           ' minimum allowed rows (shorter clips the channel browser)
Const CHAT_TOP_ROW    = 2            ' always fixed: menu bar is row 1
Const LOG_TAIL_N      = 200          ' lines to replay from log on connect
Const WIN_MAX         = 16           ' Window array
Const FOCUS_INPUT     = 0            ' chat input line has keyboard focus
Const FOCUS_HISTORY   = 1            ' chat history area has keyboard focus
Const FOCUS_PANE      = 2            ' user list pane has keyboard focus

' left user-list pane
Const PANE_W          = 18           ' pane width in columns -- never changes
Const PANE_SEP        = PANE_W + 1   ' = 19, vertical separator column
Const CHAT_COL        = PANE_W + 2   ' = 20, first chat column

' Menu bar group indices (1-based, matching VT_TUI_MENU_GROUP return values)
Enum VTIRC_MENU_GROUP
    MENU_IRC      = 1
    MENU_SETTINGS
    MENU_CHANNEL
    MENU_WINDOW
    MENU_HELP
End Enum

Enum VTIRC_MENU_IRC_ITEM
    MENU_IRC_DISCONNECT = 1
    MENU_IRC_QUIT
End Enum

Enum VTIRC_MENU_SETTINGS_ITEM
    MENU_SETTINGS_SERVER = 1
    MENU_SETTINGS_GENERAL
End Enum

Enum VTIRC_MENU_CHANNEL_ITEM
    MENU_CHANNEL_BROWSER = 1
End Enum

Enum VTIRC_MENU_WINDOW_ITEM
    MENU_WINDOW_CLOSE = 1
    MENU_WINDOW_FIRST   ' item 2 = first dynamic window entry
End Enum

Enum VTIRC_MENU_HELP_ITEM
    MENU_HELP_MANUAL = 1
    MENU_HELP_GITHUB
    MENU_HELP_ABOUT
End Enum

' Shared menubar state -- rebuilt every frame by menu_rebuild()
Dim Shared menu_groups(4)  As String
Dim Shared menu_counts(4)  As Long
ReDim Shared menu_items(0) As String

Type irc_config
    server          As String
    port            As Long
    channel         As String
    nick            As String
    password        As String
    scheme          As Byte     ' 0=Dark  1=Classic  2=Light
    log_enabled     As Byte
    log_pm          As Byte     ' 0=off  1=log PM windows to file
    auto_reconnect  As byte     ' 0=off  1=reconnect on unexpected drop
    show_timestamps As Byte     ' 0=off  1=show [HH:MM] prefix in chat history (default=on)
    beep_notify     As byte     ' 0=off  1=beep on mention or new PM
    nick_alt        As String   ' tried automatically on 433 nick-in-use
    screen_cols     As Long     ' last saved terminal width  (0 = use default)
    screen_rows     As Long     ' last saved terminal height (0 = use default)
    font_size       As Byte     ' 0=8x16 (default), 1=16x24 
    renderer        As Byte     ' 0=SW, 1=HW
end type

type irc_line
    txt     As String
    col_fg  As UByte
    is_cont As Byte    ' 1 = wrapped continuation of the previous logical message
    raw_txt As String  ' original pre-wrap text; only set on the first line of each group
End Type

Type irc_window
    target                   As String    ' "#channel" or "nick" (PRIVMSG routing)
    is_pm                    As Byte      ' 0 = channel, 1 = PM
    unread                   As Byte      ' 1 = new messages arrived while not active
    history(HISTORY_MAX - 1) As irc_line
    hist_count               As Long
    hist_head                As Long      ' ring buffer head (oldest entry index)
    top_line                 As Long      ' scroll offset (0 = live bottom)
    new_msgs                 As Byte      ' 1 when history grows while scrolled up
    user_list(USER_MAX - 1)  As String    ' per-channel user list
    user_count               As Long      ' number of tracked users
    names_receiving          As Byte      ' 1 while collecting 353 replies
End Type

Dim Shared cfg           As irc_config
Dim Shared cfg_file      As String
Dim Shared input_form(0) As vt_tui_form_item
Dim Shared input_focused As Long
Dim Shared focus_zone    As Long   = FOCUS_INPUT
Dim Shared connected     As Byte   ' 1 after 001 welcome received
Dim Shared sock_valid    As Byte   ' 1 after socket opened and connected
Dim Shared quit_flag     As Byte
Dim Shared sock          As SOCKET
Dim Shared recv_buf      As String
Dim Shared is_afk        As Byte
Dim Shared afk_msg       As String

' auto-reconnect state
Const      RECONNECT_DELAY             = 5.0
Dim Shared reconnect_pending As Byte   = 0
Dim Shared reconnect_at      As Double = 0
Dim Shared is_reconnect      As Byte   = 0
Dim Shared nick_alt_tried    As Byte   = 0

' active colour scheme
Dim Shared As Ubyte col_bg_main, col_fg_body, col_fg_own, col_fg_other, _
                    col_fg_sys, col_fg_notice, col_bar_fg, col_bar_bg, col_fg_link

' URL hit-map: rebuilt every draw_history call, one slot per visible chat row.
Type url_hit_t
    col_start As Long   ' screen col where URL starts (1-based)
    col_end   As Long   ' screen col where URL ends (inclusive)
    url_str   As String ' plain URL text; empty = no URL on this row
End Type
ReDim Shared url_hit_map(0) As url_hit_t   ' resized by screen_relayout()
Dim Shared g_log_col_end As Long = 0       ' end col of [LOG] label on status bar (0 = not shown)

' Dynamic layout -- all derived from g_screen_cols / g_screen_rows.
' Initialised to 100x40 defaults; updated on startup and on resize.
Dim Shared g_screen_cols  As Long = 100
Dim Shared g_screen_rows  As Long = 40
Dim Shared g_chat_bot_row As Long = 37   ' g_screen_rows - 3
Dim Shared g_chat_rows    As Long = 36   ' g_screen_rows - 4
Dim Shared g_row_input    As Long = 39   ' g_screen_rows - 1
Dim Shared g_row_status   As Long = 40   ' g_screen_rows
Dim Shared g_chat_wide    As Long = 81   ' g_screen_cols - PANE_W - 1

' pane user-list state
Dim Shared   pane_lb_st    As vt_tui_listbox_state
ReDim Shared pane_items(0) As String   ' rebuilt on pane_dirty; sorted alphabetically
ReDim Shared pane_display_items(0) As String  ' display copy with unread-PM markers; parallel to pane_items
Dim Shared   pane_dirty    As Byte = 1

' Draw-dirty flags: set to 1 whenever a screen region needs redrawing.
' draw_ui() skips unchanged regions 
Dim Shared df_hist  As Byte = 1   ' chat history area
Dim Shared df_pane  As Byte = 1   ' left user-list pane
Dim Shared df_input As Byte = 1   ' input line, status bar, title bar

' channel/pm windows
Dim Shared wins(WIN_MAX - 1) As irc_window
Dim Shared win_count         As Long = 1
Dim Shared active_win        As Long = 0

' command-line history
Const      CMD_HIST_MAX   = 16
Dim Shared cmd_hist_buf(CMD_HIST_MAX - 1) As String
Dim Shared cmd_hist_count As Long = 0
Dim Shared cmd_hist_head  As Long = 0   ' ring head (oldest entry index)
Dim Shared cmd_hist_pos   As Long = -1  ' -1 = not browsing

' channel browser: LIST collection state
Const CHLIST_MAX         = 7000
Dim Shared   chlist_active As Byte = 0   ' 1 while LIST is in progress
Dim Shared   chlist_done   As Byte = 0   ' 1 when 323 (end of list) arrives
Dim Shared   chlist_count  As Long = 0
ReDim Shared chlist_names(CHLIST_MAX - 1)  As String
ReDim Shared chlist_users(CHLIST_MAX - 1)  As Long
ReDim Shared chlist_topics(CHLIST_MAX - 1) As String

Declare Sub      irc_poll()
Declare Sub      screen_relayout()
Declare Sub      irc_send(irc_msg As String)
Declare Sub      irc_on_drop()
Declare Function win_find(tgt As String) As Long
Declare Function win_open(tgt As String, pm As Byte) As Long
Declare Sub      win_hist_append(win_idx As Long, txt As String, col_fg As UByte)
Declare Sub      win_hist_raw(win_idx As Long, txt As String, col_fg As UByte)
Declare Sub      hist_reflow(win_idx As Long)
Declare Sub      win_close(win_idx As Long)
Declare Function user_in_win(win_idx As Long, nick As String) As Byte
Declare Sub      log_load_tail(win_idx As Long, n As Long)
Declare Sub      pane_refresh()
Declare Sub      user_list_clear(win_idx As Long)
Declare Sub      user_list_add(win_idx As Long, nick As String)
Declare Sub      user_list_remove(win_idx As Long, nick As String)
Declare Sub      user_list_rename(win_idx As Long, old_nick As String, new_nick As String)
Declare Function irc_strip_colors(s As String) As String
Declare Function mirc_wordwrap(txt As String, wid As Long) As String
Declare Sub      channel_browser()
Declare Function url_find_in_plain(plain_txt As String, ByRef u_start As Long, ByRef u_end As Long) As Byte
Declare Sub      open_url(url_txt As String)

' helpers
Declare Sub      mirc_skip_color(txt As String, ByRef ii As Long, slen As Long, ByRef nfg As Long, ByRef nbg As Long)
Declare Sub      win_ring_push(win_idx As Long, txt As String, col_fg As UByte, is_cont As Byte = 0, raw_txt As String = "")
Declare Function prms_last_token(prms As String) As String
Declare Sub      win_reset(win_idx As Long)
Declare Sub      do_channel_join(ch_name As String)
Declare Sub      notify_user()
Declare Sub      log_write_path(log_path As String, txt As String)
Declare Sub      irc_disconnect()
Declare Function irc_connect() As Byte
Declare Sub      help_window()
Declare Function settings_server_form() As Long
Declare Function settings_common_form() As Long
Declare Sub      menu_rebuild()
Declare Sub      menu_draw()
Declare Function menu_handle(k As ULong) As Long
