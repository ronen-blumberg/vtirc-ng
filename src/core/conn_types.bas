' =============================================================================
' src/core/conn_types.bas -- the connection object and simple accessors
' =============================================================================

Const CONN_MAX = 32

Enum CONN_STATE_T
    CS_OFFLINE = 0
    CS_CONNECTING          ' worker thread: resolve / connect / proxy / TLS
    CS_REGISTERING         ' CAP / SASL / NICK / USER sent, waiting for 001
    CS_ONLINE
    CS_WAIT_RECONNECT
End Enum

Type irc_conn
    alive          As Byte
    net_idx        As Long        ' network config index, -1 = ad-hoc /server
    name           As String      ' display name (network name or host)
    srv            As srv_entry   ' server in use
    srv_idx        As Long        ' rotation index into the network's servers
    use_adhoc      As Byte        ' srv was given by /server: don't rotate the list
    st             As Long
    job            As net_job Ptr
    sock           As Long
    tls            As Any Ptr
    peer           As String      ' numeric address connected to
    tls_fp         As String      ' certificate fingerprint of this connection
    cert_new_fp    As String      ' fingerprint waiting for /cert accept
    rbuf           As String      ' received bytes not yet split into lines
    ' output
    sq(Any)        As String      ' flood-controlled queue (ring)
    sq_head        As Long
    sq_count       As Long
    tokens         As Double
    tok_time       As Double
    pend           As String      ' bytes accepted for sending, not yet written
    closing_at     As Double      ' > 0: close once pend drained or this time passed
    ' identity
    nick           As String      ' nick in effect on the server
    nick_tries     As Long
    user           As String      ' our user / host as seen by the server
    host           As String
    umodes         As String
    ' registration
    cap_ls         As String      ' " cap cap=value ... " offered
    cap_on         As String      ' " cap cap " enabled
    cap_ls_done    As Byte
    cap_req_pending As Long
    cap_ended      As Byte
    sasl_state     As Long        ' 0 none, 1 mech sent, 2 creds sent, 3 finished
    registered     As Byte
    motd_done      As Byte
    ' ISUPPORT
    cm             As Long
    netname        As String
    prefix_modes   As String
    prefix_chars   As String
    chantypes      As String
    chm_a          As String      ' list modes (always a parameter)
    chm_b          As String      ' always a parameter
    chm_c          As String      ' parameter only when set
    chm_d          As String      ' never a parameter
    modes_max      As Long
    nicklen        As Long
    statusmsg      As String
    has_whox       As Byte
    monitor_max    As Long
    ' timers
    last_rx        As Double
    ping_out       As Double      ' when our PING was sent (0 = none outstanding)
    last_ping      As Double
    lag            As Double
    connected_at   As Double
    reconnect_at   As Double
    reconnect_n    As Long
    user_quit      As Byte        ' user asked to disconnect: no auto reconnect
    ' state
    away           As Byte
    away_msg       As String
    status_buf     As Long
    join_pending   As Byte        ' autojoin waits for NickServ identification
    join_at        As Double
    rejoin_list    As String      ' channels to join after (re)connect, "#a key,#b"
    focus_joins    As String      ' " #chan " the user asked to join (focus when joined)
    close_on_part  As String      ' " #chan " to close when our PART comes back
    ' WHOIS accumulation
    whois_nick     As String
    whois_buf      As Long
    ' channel list (LIST)
    ls_active      As Byte
    ls_done        As Byte
    ls_count       As Long
    ls_name(Any)   As String
    ls_users(Any)  As Long
    ls_topic(Any)  As String
    ' misc
    ctcp_times(4)  As Double      ' recent CTCP reply times (flood limit)
    ctcp_i         As Long
    charset        As Long        ' fallback / legacy charset (CHARSET_*)
    send_legacy    As Byte        ' encode outgoing text in `charset`
    hist_batches   As String      ' " id id " playback batches in progress
    kick_rejoin    As String      ' "#chan|time;" pending rejoin after kick
End Type

Dim Shared conns(0 To CONN_MAX - 1) As irc_conn

Function conn_valid(c As Long) As Byte
    Return IIf(c >= 0 AndAlso c < CONN_MAX AndAlso conns(c).alive <> 0, 1, 0)
End Function

Function conn_casemap(conn_id As Long) As Long
    If conn_valid(conn_id) Then Return conns(conn_id).cm
    Return CM_RFC1459
End Function

Function conn_nick(c As Long) As String
    If conn_valid(c) Then Return conns(c).nick
    Return ""
End Function

Function conn_is_me(c As Long, ByRef nick As String) As Byte
    If conn_valid(c) = 0 OrElse Len(nick) = 0 Then Return 0
    Return irc_eq(nick, conns(c).nick, conns(c).cm)
End Function

Function conn_has_cap(c As Long, ByRef capname As String) As Byte
    If conn_valid(c) = 0 Then Return 0
    Return IIf(InStr(conns(c).cap_on, " " & capname & " ") > 0, 1, 0)
End Function

Function conn_is_channel(c As Long, ByRef target As String) As Byte
    If Len(target) = 0 Then Return 0
    Dim ct As String = "#&"
    If conn_valid(c) AndAlso Len(conns(c).chantypes) > 0 Then ct = conns(c).chantypes
    Return IIf(InStr(ct, Left(target, 1)) > 0, 1, 0)
End Function

Function conn_online(c As Long) As Byte
    Return IIf(conn_valid(c) AndAlso conns(c).st = CS_ONLINE, 1, 0)
End Function

Function conn_state_text(c As Long) As String
    If conn_valid(c) = 0 Then Return ""
    Select Case conns(c).st
    Case CS_OFFLINE        : Return "offline"
    Case CS_CONNECTING     : Return "connecting"
    Case CS_REGISTERING    : Return "registering"
    Case CS_ONLINE         : Return "online"
    Case CS_WAIT_RECONNECT : Return "reconnecting"
    End Select
    Return ""
End Function

' First connection whose display name matches (case-insensitive).
Function conn_find(ByRef nm As String) As Long
    Dim i As Long
    For i = 0 To CONN_MAX - 1
        If conns(i).alive AndAlso LCase(conns(i).name) = LCase(nm) Then Return i
    Next i
    Return -1
End Function
